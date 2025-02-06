
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



    // Data and tag arrays
    PhysicalAddressHigh tagsForWay[BLOCKS_PER_WAY] = '{default: 0}; // tags for each block of way 0

    // Simple array for simple test cases, without blocks, transaltions etc
    Mbyte content[4096]; // So far this corresponds to way 0


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
    

    task automatic handleFills();
        handleBlockFills();
        handleTlbFills();
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

    // TODO: handle writing to blocs in dynamic allocated region!
    task automatic doWrite(input MemWriteInfo wrInfo);
        Mbyte wval[4] = {>>{wrInfo.value}};
        if (wrInfo.req) content[wrInfo.adr +: 4] <= wval;
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



    function automatic Mword readFromStaticRange(input Mword adr /*input AccessInfo aInfo */ /*, input Translation tr*/);
        Mbyte chosenWord[4] = content[adr +: 4];
        Mword wval = {>>{chosenWord}};
        Word val = Mword'(wval);

        //DataCacheOutput res;// = '{1, CR_HIT, tr.desc, val};
            
        //    res.data = val;
        return val; //res;
    endfunction 

    function automatic Mword readFromDynamicRange(input Mword adr);
        // TODO: for now only word-sized
        Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
        DataBlock block = filledBlocks[physBlockBase];
        PhysicalAddressLow physLow = adrLow(adr);

        Mbyte chosenWord[4] = block[physLow +: 4];
        Mword wval = {>>{chosenWord}};
        Word val = Mword'(wval);

        //    DataCacheOutput res = '{1, CR_HIT, tr.desc, val};

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

            if ($isunknown(vadr)) begin
                readOut[p] <= EMPTY_DATA_CACHE_OUTPUT;
                accesses[p] <= DEFAULT_ACCESS_INFO;
                translations[p] <= DEFAULT_TRANSLATION;
            end
            else begin
                AccessInfo acc = analyzeAccess(vadr, 4);
                Translation tr = translateAddress(vadr);
                PhysicalAddressHigh wayTag = tagsForWay[acc.block];
               
                DataCacheOutput thisResult = doReadAccess(acc, tr);

                readOut[p] <= thisResult;
                accesses[p] <= acc;
                translations[p] <= tr;
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
            if (isUncachedRange(tr.phys))
                res.data = 0; // Read uncached mem
            else if (tr.phys <= $size(content)) // Read from small array
                res.data = readFromStaticRange(tr.phys /*aInfo*/ /*, tr*/);//.data;
            else
                res.data = readFromDynamicRange(tr.phys);
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
        handleFills();

        handleReads();
        handleWrites();
    end


endmodule
