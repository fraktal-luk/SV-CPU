
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;


module DataL1(
            input logic clk,
            input DataReadReq readReqs[N_MEM_PORTS],
            input MemWriteInfo TMP_writeReqs[2],
            output DataCacheOutput readOut[N_MEM_PORTS]
);

    // TLB
    localparam int DATA_TLB_SIZE = 32;
    
        localparam logic DONT_TRANSLATE = 1; // TMP

    logic notifyFill = 0;
    Mword notifiedAdr = 'x;

    logic notifyTlbFill = 0;
    Mword notifiedTlbAdr = 'x;

    int uncachedCounter = -1;
    logic uncachedBusy = 0;
    Mword uncachedOutput = 'x;

    typedef Mbyte DataBlock[BLOCK_SIZE];


    // Simple array for simple test cases, without blocks, transaltions etc
    Mbyte staticContent[PAGE_SIZE]; // So far this corresponds to way 0
    
    localparam Mword UNCACHED_BASE = 'h80000000;
    Mbyte uncachedArea[PAGE_SIZE];
    
    // Data and tag arrays
    PhysicalAddressHigh tagsForWay[BLOCKS_PER_WAY] = '{default: 0}; // tags for each block of way 0


    // CAREFUL: below only for addresses in the range for data miss tests 
    DataBlock filledBlocks[Mword]; // Set of blocks in "force data miss" region which are "filled" and will not miss again 
    int       blockFillCounters[Mword];
    Mword     readyBlocksToFill[$];

    // CAREFUL: below only for addresses in the range for TLB miss tests 
    Translation   filledMappings[Mword]; // Set of blocks in "force data miss" region which are "filled" and will not miss again 
    int       mappingFillCounters[Mword];
    Mword     readyMappingsToFill[$];



    function automatic logic isUncachedRange(input Mword adr);
        return adr >= UNCACHED_BASE && adr < UNCACHED_BASE + $size(uncachedArea);
    endfunction

    function automatic logic isStaticDataRange(input Mword adr);
        return adr < $size(staticContent);
    endfunction

    function automatic logic isStaticTlbRange(input Mword adr);        
        return isUncachedRange(adr) // TEMP: uncached region is mapped by default
                || adr < 'h80000; // TEMP: Let's give 1M for static mappings
    endfunction



    //    typedef struct {
    //        logic active;
    //            logic store;            
    //            logic uncachedReq;
    //        Mword adr;
    //        AccessSize size;
    //    } DataReadReq;
    
    //    localparam DataReadReq EMPTY_READ_REQ = '{0, 0, 0, 'x, SIZE_NONE};
   
        typedef struct {
            logic ready = 0;
        
                logic ongoing = 0;
                Mword adr = 'x;
                AccessSize size = SIZE_NONE;

            int counter = -1;
        } UncachedRead;

        UncachedRead uncachedReads[N_MEM_PORTS]; // Should be one (ignore other than [0])




    function automatic void reset();
        staticContent = '{default: 0};
        uncachedArea = '{default: 0};
        tagsForWay = '{default: 0};
        
        filledBlocks.delete();
        blockFillCounters.delete();
        readyBlocksToFill.delete();
        
        filledMappings.delete();
        mappingFillCounters.delete();
        readyMappingsToFill.delete();
        
            uncachedCounter = -1;
            uncachedBusy = 0;
    endfunction


    task automatic handleWrites();
        doWrite(TMP_writeReqs[0]);
    endtask

        
    class PageWriter#(type Elem = Mbyte, int ESIZE = 1, int BASE = 0);
        static
        function automatic void writeTyped(ref Mbyte arr[PAGE_SIZE], input Mword adr, input Elem val);
            Mbyte wval[ESIZE] = {>>{val}};
            arr[(adr - BASE) +: ESIZE] = wval;
        endfunction
        
        static
        function automatic Elem readTyped(ref Mbyte arr[PAGE_SIZE], input Mword adr);                
            Mbyte chosen[ESIZE] = arr[(adr - BASE) +: ESIZE];
            Elem wval = {>>{chosen}};
            return wval;
        endfunction
    endclass



    ////////////////////////////////////
    // Specific write & read functions

    function automatic void writeToStaticRangeW(input Mword adr, input Mword val);
        PageWriter#(Word, 4)::writeTyped(staticContent, adr, val);
    endfunction

    function automatic void writeToStaticRangeB(input Mword adr, input Mbyte val);
        PageWriter#(Mbyte, 1)::writeTyped(staticContent, adr, val);
    endfunction


    function automatic void writeToUncachedRangeW(input Mword adr, input Mword val);
        PageWriter#(Word, 4, UNCACHED_BASE)::writeTyped(uncachedArea, adr, val);
    endfunction

    function automatic void writeToUncachedRangeB(input Mword adr, input Mbyte val);
        PageWriter#(Mbyte, 1, UNCACHED_BASE)::writeTyped(uncachedArea, adr, val);
    endfunction


    function automatic Mword readWordStatic(input Mword adr);
        return PageWriter#(Word, 4)::readTyped(staticContent, adr);
    endfunction

    function automatic Mword readByteStatic(input Mword adr);
        return Mword'(PageWriter#(Mbyte, 1)::readTyped(staticContent, adr));
    endfunction


    function automatic Mword readWordUncached(input Mword adr);
        return PageWriter#(Word, 4, UNCACHED_BASE)::readTyped(uncachedArea, adr);
    endfunction

    function automatic Mword readByteUncached(input Mword adr);
        return Mword'(PageWriter#(Mbyte, 1, UNCACHED_BASE)::readTyped(uncachedArea, adr));
    endfunction



    function automatic void writeToDynamicRangeW(input Mword adr, input Mword val);
        localparam int ACCESS_SIZE = 4;
        
        Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
        PhysicalAddressLow physLow = adr % BLOCK_SIZE;

        Mbyte wval[ACCESS_SIZE] = {>>{val}};
        filledBlocks[physBlockBase][physLow +: ACCESS_SIZE] = wval;
    endfunction

    function automatic void writeToDynamicRangeB(input Mword adr, input Mbyte val);
        localparam int ACCESS_SIZE = 1;
        
        Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
        PhysicalAddressLow physLow = adr % BLOCK_SIZE;

        Mbyte wval[ACCESS_SIZE] = {>>{val}};
        filledBlocks[physBlockBase][physLow +: ACCESS_SIZE] = wval;
    endfunction


    function automatic Mword readWordDynamic(input DataBlock block, input int offset);
        localparam int ACCESS_SIZE = 4;

        Mbyte chosenWord[ACCESS_SIZE] = block[offset +: ACCESS_SIZE];
        Mword wval = {>>{chosenWord}};

        return (wval);
    endfunction

    function automatic Mword readByteDynamic(input DataBlock block, input int offset);
        localparam int ACCESS_SIZE = 1;

        Mbyte chosenWord[ACCESS_SIZE] = block[offset +: ACCESS_SIZE];
        Mbyte wval = {>>{chosenWord}};

        return (wval);
    endfunction

    /////////////////////////////////////



    ////////////////////////////////////
    // Presence & allocation function 
    //
    function automatic void allocInDynamicRange(input Mword adr);
        Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;        
        filledBlocks[physBlockBase] = '{default: 0};            
    endfunction

    function automatic void allocInTlb(input Mword adr);
        Translation DUMMY; 
        Mword pageBase = (adr/PAGE_SIZE)*PAGE_SIZE;
        
        filledMappings[pageBase] = DUMMY;            
    endfunction


    function automatic logic isPhysPresent(input Mword adr);
        Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
        return isUncachedRange(adr) || isStaticDataRange(adr) || filledBlocks.exists(physBlockBase);
    endfunction

    function automatic logic isPhysPending(input Mword adr);
        Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
        return blockFillCounters.exists(physBlockBase);
    endfunction
    

    function automatic logic isTlbPresent(input Mword adr);
        Mword pageBase = (adr/PAGE_SIZE)*PAGE_SIZE;
        return isStaticTlbRange(adr) || filledMappings.exists(pageBase);
    endfunction

    function automatic logic isTlbPending(input Mword adr);
        Mword pageBase = (adr/PAGE_SIZE)*PAGE_SIZE;
        return mappingFillCounters.exists(pageBase);
    endfunction
    
    

    function automatic void scheduleBlockFill(input Mword adr);
        Mword physBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;

        if (!blockFillCounters.exists(physBase))
            blockFillCounters[physBase] = 15;            
    endfunction

    function automatic void scheduleTlbFill(input Mword adr);
        Mword pageBase = (adr/PAGE_SIZE)*PAGE_SIZE;

        if (!mappingFillCounters.exists(pageBase))
            mappingFillCounters[pageBase] = 12;  
    endfunction




    task automatic handleBlockFills();
        Mword adr;
        
        notifyFill <= 0;
        notifiedAdr <= 'x;
    
        foreach (blockFillCounters[a]) begin
            if (blockFillCounters[a] == 0) begin
                readyBlocksToFill.push_back(a);
                blockFillCounters[a] = -1;
            end
            else
                blockFillCounters[a]--;
        end
        
        if (readyBlocksToFill.size() == 0) return;
        
        adr = readyBlocksToFill.pop_front();
        allocInDynamicRange(adr);
        blockFillCounters.delete(adr);

        notifyFill <= 1;
        notifiedAdr <= adr;           
    endtask 


    task automatic handleTlbFills();
        Mword adr;
        
        notifyTlbFill <= 0;
        notifiedTlbAdr <= 'x;
    
        foreach (mappingFillCounters[a]) begin            
            if (mappingFillCounters[a] == 0) begin
                readyMappingsToFill.push_back(a);
                mappingFillCounters[a] = -1;
            end
            else
                mappingFillCounters[a]--;
        end
        
        if (readyMappingsToFill.size() == 0) return;
        
        adr = readyMappingsToFill.pop_front();
        allocInTlb(adr);
        mappingFillCounters.delete(adr);

        notifyTlbFill <= 1;
        notifiedTlbAdr <= adr;           
    endtask 


    task automatic handleUncachedData();
        if (uncachedReads[0].ongoing) begin
            if (--uncachedReads[0].counter == 0) begin
                uncachedReads[0].ongoing = 0;
                uncachedReads[0].ready = 1;
                uncachedOutput = readFromUncachedRange(uncachedReads[0].adr, uncachedReads[0].size);
            end
        end
    endtask

    ////////////////////////////////////




    /////////////////////////////////////////////////////////////////////////////
    // General read functions
    function automatic Mword readFromUncachedRange(input Mword adr, input AccessSize size);
        if (size == SIZE_1) return readByteUncached(adr);
        else if (size == SIZE_4) return readWordUncached(adr);
        else $error("Wrong access size");

        return 'x;
    endfunction

    function automatic Mword readFromStaticRange(input Mword adr, input AccessSize size);
        if (size == SIZE_1) return readByteStatic(adr);
        else if (size == SIZE_4) return readWordStatic(adr);
        else $error("Wrong access size");

        return 'x;
    endfunction


    function automatic Mword readFromDynamicRange(input Mword adr, input AccessSize size);        
        Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
        DataBlock block = filledBlocks[physBlockBase];
        PhysicalAddressLow physLow = adr % BLOCK_SIZE;

        if (size == SIZE_1) return readByteDynamic(block, physLow);
        else if (size == SIZE_4) return readWordDynamic(block, physLow);
        else $error("Wrong access size");

        return 'x;
    endfunction
    
    
    task automatic doWrite(input MemWriteInfo wrInfo);
        Mword adr = wrInfo.adr;
        Mword val = wrInfo.value;

        if (!wrInfo.req) return;

        if (wrInfo.uncached) begin
            uncachedCounter = 15;
            uncachedBusy = 1;
            if (wrInfo.size == SIZE_1) writeToUncachedRangeB(adr, val);
            if (wrInfo.size == SIZE_4) writeToUncachedRangeW(adr, val);
        end
        else if (isStaticDataRange(adr)) begin
            if (wrInfo.size == SIZE_1) writeToStaticRangeB(adr, val);
            if (wrInfo.size == SIZE_4) writeToStaticRangeW(adr, val);
        end
        else begin 
            if (wrInfo.size == SIZE_1) writeToDynamicRangeB(adr, val);
            if (wrInfo.size == SIZE_4) writeToDynamicRangeW(adr, val);
        end
    
    endtask

    ///////////////////////////////



    task automatic handleFills();
        handleBlockFills();
        handleTlbFills();
            
        handleUncachedData();
    endtask

    task automatic handleReads();
        readOut <= '{default: EMPTY_DATA_CACHE_OUTPUT};

        foreach (readReqs[p]) begin
            Mword vadr = readReqs[p].adr;

            if (!readReqs[p].active) continue;
            else if ($isunknown(vadr)) continue;
            else begin
                AccessInfo acc = analyzeAccess(vadr, readReqs[p].size);
                Translation tr = translateAddress(vadr);
                PhysicalAddressHigh wayTag = tagsForWay[acc.block];

                readOut[p] <= doReadAccess(acc, tr, !readReqs[p].store && readReqs[p].uncachedReq);
            end
        end
    endtask


    function automatic DataCacheOutput doReadAccess(input AccessInfo aInfo, input Translation tr, input logic startUncached);
        DataCacheOutput res;
        
        if (!tr.present) begin
            res.status = CR_TLB_MISS;
        end
        else if (!isPhysPresent(tr.phys)) begin
           res = '{1, CR_TAG_MISS, tr.desc, 'x};
           if (!isPhysPending(tr.phys)) scheduleBlockFill(tr.phys);
        end
        else begin
            res = '{1, CR_HIT, tr.desc, 'x};
            
            if (isUncachedRange(tr.phys)) begin
                res.data = uncachedOutput;
                // Clear used transfer
                uncachedReads[0].ready = 0;
                uncachedReads[0].adr = 'x;
                    uncachedOutput = 'x;
            end
            else if (tr.phys <= $size(staticContent)) // Read from small array
                res.data = readFromStaticRange(tr.phys, aInfo.size);
            else
                res.data = readFromDynamicRange(tr.phys, aInfo.size);
        end
        
        // Initiate uncached read
        if (startUncached) begin
            uncachedReads[0].ongoing = 1;
            uncachedReads[0].counter = 8;
            uncachedReads[0].adr = aInfo.adr;
            uncachedReads[0].size = aInfo.size;
        end
        
        return res;
    endfunction



    function automatic Translation translateAddress(input EffectiveAddress adr);
        Translation res;

        if ($isunknown(adr)) return res;

        res.vHigh = adrHigh(adr);

        if (!isTlbPresent(adr)) begin
            res.present = 0;
            if (!isTlbPending(adr)) scheduleTlbFill(adr);
            return res;
        end

        // TMP: in "mapping always present" range:
        res.present = 1; // Obviously
        res.pHigh = res.vHigh; // Direct mapping of memory
        res.desc = '{
            allowed: 1,
            canRead: 1,
            canWrite: 1,
            canExec: 1,
            cached: 1
        };

        res.phys = {res.pHigh, adrLow(adr)};

        // TMP: uncached rnge
        if (isUncachedRange(adr))
            res.desc.cached = 0;

        return res;
    endfunction


    always @(posedge clk) begin
            if (uncachedCounter == 0) uncachedBusy = 0;
            if (uncachedCounter >= 0) uncachedCounter--;
            
        handleFills();

        handleReads();
        handleWrites();
    end


endmodule
