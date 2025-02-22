
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;

// FUTURE: access sizes: byte, hword, ... SIMD
module DataL1(
            input logic clk,
            input DataReadReq readReqs[N_MEM_PORTS],
            input MemWriteInfo TMP_writeReqs[2],
            output DataCacheOutput readOut[N_MEM_PORTS]
);

    // TLB
    localparam int DATA_TLB_SIZE = 32;
    
        localparam logic DONT_TRANSLATE = 1; // TMP
        
    typedef Mbyte DataBlock[BLOCK_SIZE];



    logic notifyFill = 0;
    Mword notifiedAdr = 'x;

    logic notifyTlbFill = 0;
    Mword notifiedTlbAdr = 'x;


    // CAREFUL: below only for addresses in the range for data miss tests 
    DataBlock filledBlocks[Mword]; // Set of blocks in "force data miss" region which are "filled" and will not miss again 
    int       blockFillCounters[Mword];
    Mword     readyBlocksToFill[$];

    // CAREFUL: below only for addresses in the range for TLB miss tests 
    Translation   filledMappings[Mword]; // Set of blocks in "force data miss" region which are "filled" and will not miss again 
    int       mappingFillCounters[Mword];
    Mword     readyMappingsToFill[$];

        
        typedef struct {
            logic ongoing = 0;
            logic ready = 0;
            Mword adr = 'x;
            Mword data = 'x;
            AccessSize size = SIZE_NONE;
            int counter = -1;
        } UncachedRead;

        UncachedRead uncachedReads[N_MEM_PORTS]; // Should be one (ignore other than [0])


    // Data and tag arrays
    PhysicalAddressHigh tagsForWay[BLOCKS_PER_WAY] = '{default: 0}; // tags for each block of way 0

    // Simple array for simple test cases, without blocks, transaltions etc
    Mbyte content[4096]; // So far this corresponds to way 0
    
    localparam Mword UNCACHED_BASE = 'h80000000;
    Mbyte uncachedArea[4096];


    AccessInfo accesses[N_MEM_PORTS];
    Translation translations[N_MEM_PORTS];        



    function automatic logic isUncachedRange(input Mword adr);
        return adr[31];
    endfunction

    function automatic logic isStaticDataRange(input Mword adr);
        return adr < $size(content);
    endfunction

    function automatic logic isStaticTlbRange(input Mword adr);        
        return isUncachedRange(adr) // TEMP: uncached region is mapped by default
                || adr < 'h80000; // TEMP: Let's give 1M for static mappings
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
                uncachedReads[0].data = readFromUncachedRange(uncachedReads[0].adr, uncachedReads[0].size);
            end
        end
    endtask

  

    task automatic handleFills();
        handleBlockFills();
        handleTlbFills();
            
        handleUncachedData();

    endtask




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


    function automatic void reset();
        content = '{default: 0};
        uncachedArea = '{default: 0};
        tagsForWay = '{default: 0};
        
        filledBlocks.delete();
        blockFillCounters.delete();
        readyBlocksToFill.delete();
        
        filledMappings.delete();
        mappingFillCounters.delete();
        readyMappingsToFill.delete();
    endfunction


    task automatic handleWrites();
        doWrite(TMP_writeReqs[0]);
    endtask


    function automatic void writeToStaticRangeW(input Mword adr, input Mword val);
        localparam int ACCESS_SIZE = 4;

        Mbyte wval[ACCESS_SIZE] = {>>{val}};
        content[adr +: ACCESS_SIZE] = wval;
    endfunction

    function automatic void writeToStaticRangeB(input Mword adr, input Mbyte val);
        localparam int ACCESS_SIZE = 1;

        Mbyte wval[ACCESS_SIZE] = {>>{val}};
        content[adr +: ACCESS_SIZE] = wval;
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


    function automatic void writeToUncachedRangeW(input Mword adr, input Mword val);
        localparam int ACCESS_SIZE = 4;

        Mbyte wval[ACCESS_SIZE] = {>>{val}};
        uncachedArea[(adr - UNCACHED_BASE) +: ACCESS_SIZE] = wval;
    endfunction

    function automatic void writeToUncachedRangeB(input Mword adr, input Mbyte val);
        localparam int ACCESS_SIZE = 1;

        Mbyte wval[ACCESS_SIZE] = {>>{val}};
        uncachedArea[(adr - UNCACHED_BASE) +: ACCESS_SIZE] = wval;
    endfunction



    task automatic doWrite(input MemWriteInfo wrInfo);
        Mword adr = wrInfo.adr;
        Mword val = wrInfo.value;

        if (!wrInfo.req) return;

        if (wrInfo.uncached) begin
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


    function automatic Mword readWordStatic(input Mword adr);
        localparam int ACCESS_SIZE = 4;
        
        Mbyte chosenWord[ACCESS_SIZE];
        Mword wval;
        Word val;

        chosenWord = content[adr +: ACCESS_SIZE];

        wval = {>>{chosenWord}};
        val = Mword'(wval);

        return val;
    endfunction

    function automatic Mword readByteStatic(input Mword adr);
        localparam int ACCESS_SIZE = 1;
        
        Mbyte chosenWord[ACCESS_SIZE];
        Mbyte wval;
        Word val;

        chosenWord = content[adr +: ACCESS_SIZE];

        wval = {>>{chosenWord}};
        val = Mword'(wval);

        return val;
    endfunction



    function automatic Mword readWordUncached(input Mword adr);
        localparam int ACCESS_SIZE = 4;
        
        Mbyte chosenWord[ACCESS_SIZE];
        Mword wval;
        Word val;

        chosenWord = uncachedArea[(adr - UNCACHED_BASE) +: ACCESS_SIZE];

        wval = {>>{chosenWord}};
        val = Mword'(wval);

        return val;
    endfunction

    function automatic Mword readByteUncached(input Mword adr);
        localparam int ACCESS_SIZE = 1;
        
        Mbyte chosenWord[ACCESS_SIZE];
        Mbyte wval;
        Word val;

        chosenWord = content[(adr - UNCACHED_BASE) +: ACCESS_SIZE];

        wval = {>>{chosenWord}};
        val = Mword'(wval);

        return val;
    endfunction



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


    function automatic Mword readWordDynamic(input DataBlock block, input int offset);
        localparam int ACCESS_SIZE = 4;

        Mbyte chosenWord[ACCESS_SIZE] = block[offset +: ACCESS_SIZE];
        Mword wval = {>>{chosenWord}};
        Word val = Mword'(wval);

        return val;
    endfunction

    function automatic Mword readByteDynamic(input DataBlock block, input int offset);
        localparam int ACCESS_SIZE = 1;

        Mbyte chosenWord[ACCESS_SIZE] = block[offset +: ACCESS_SIZE];
        Mbyte wval = {>>{chosenWord}};
        Word val = Mword'(wval);

        return val;
    endfunction


    function automatic void allocInDynamicRange(input Mword adr);
        Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
        DataBlock block = '{default: 0};
        
        filledBlocks[physBlockBase] = block;            
    endfunction

    function automatic void allocInTlb(input Mword adr);
        Translation DUMMY; 
        Mword pageBase = (adr/PAGE_SIZE)*PAGE_SIZE;
        
        filledMappings[pageBase] = DUMMY;            
    endfunction
       

    task automatic handleReads();
        foreach (readReqs[p]) begin
            Mword vadr = readReqs[p].adr;

            if ($isunknown(vadr) || !readReqs[p].active) begin
                readOut[p] <= EMPTY_DATA_CACHE_OUTPUT;
                accesses[p] <= DEFAULT_ACCESS_INFO;
                translations[p] <= DEFAULT_TRANSLATION;
            end
            else begin
                AccessInfo acc = analyzeAccess(vadr, readReqs[p].size);
                Translation tr = translateAddress(vadr);
                PhysicalAddressHigh wayTag = tagsForWay[acc.block];
               
                DataCacheOutput thisResult = doReadAccess(acc, tr);

                readOut[p] <= thisResult;
                accesses[p] <= acc;
                translations[p] <= tr;
                
                
                // Initiate uncached read
                if (readReqs[p].active && !readReqs[p].store && readReqs[p].uncachedReq) begin
                    uncachedReads[0].ongoing = 1;
                    uncachedReads[0].counter = 8;
                    uncachedReads[0].adr = readReqs[p].adr;
                    uncachedReads[0].size = readReqs[p].size;
                end
                
            end

        end
    endtask


    function automatic DataCacheOutput doReadAccess(input AccessInfo aInfo, input Translation tr);
        DataCacheOutput res;
        
        if (!tr.present) begin
            res.status = CR_TLB_MISS;
            return res;
        end
        
        // if tr.present then:
        // now compare tr.pHigh to wayTag
        // if match, re.desc is applied and res.data is applied 
        res = '{1, CR_HIT, tr.desc, 'x};

        if (!isPhysPresent(tr.phys)) begin
           res.status = CR_TAG_MISS;
           if (!isPhysPending(tr.phys)) scheduleBlockFill(tr.phys);
        end
        else begin           
            if (isUncachedRange(tr.phys)) begin
                res.data = uncachedReads[0].data;
                // Clear used transfer
                uncachedReads[0].ready = 0;
                uncachedReads[0].data = 'x;
                uncachedReads[0].adr = 'x;
            end
            else if (tr.phys <= $size(content)) // Read from small array
                res.data = readFromStaticRange(tr.phys, aInfo.size);
            else
                res.data = readFromDynamicRange(tr.phys, aInfo.size);
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


   //     Mword dummy0, dummy1, dummy2;
  //      Mbyte kkk[8] = '{0,1,2,3,4,5,6,7};


    always @(posedge clk) begin
        handleFills();

        handleReads();
        handleWrites();
        
//             dummy0 <=   {>>{kkk[4 +: 4]}};
//             dummy1 <=   {>>{kkk[5 +: 4]}};
//             dummy2 <=   {>>{kkk[6 +: 4]}};
    end


endmodule
