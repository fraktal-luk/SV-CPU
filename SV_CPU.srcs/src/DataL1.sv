
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
    
    
    
    
        function automatic logic isRangeUncached(input Mword adr);
            return adr[31];
        endfunction 
    
        function automatic logic isRangeDataMiss(input Mword adr);
            return adr[30];
        endfunction 


    logic notifyFill = 0;
    Mword notifiedAdr = 'x;
  
    
    // Data and tag arrays
    PhysicalAddressHigh tagsForWay[BLOCKS_PER_WAY] = '{default: 0}; // tags for each block of way 0
    Mbyte content[4096]; // So far this corresponds to way 0

        // CAREFUL: below only for addresses in the range for data miss tests 
        DataBlock filledBlocks[Mword]; // Set of blocks in "force data miss" region which are "filled" and will not miss again 
        int       fillingCounters[Mword];
        Mword     readyToFill[$];



    AccessInfo accesses[N_MEM_PORTS];
    Translation translations[N_MEM_PORTS];        







        task automatic handleFills();
            Mword adr;
            
            notifyFill <= 0;
            notifiedAdr <= 'x;
        
            foreach (fillingCounters[a]) begin
            
                if (fillingCounters[a] == 0) begin
                    readyToFill.push_back(a);
                    fillingCounters[a] = -1;
                end
                else
                    fillingCounters[a]--;
            end
            
            if (readyToFill.size() == 0) return;
            
            adr = readyToFill.pop_front();
            allocInMissRange(adr);
            fillingCounters.delete(adr);

            notifyFill <= 1;
            notifiedAdr <= adr;           
        endtask 

        task automatic scheduleBlockFill(input Mword adr);
            Mword physBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;

            if (!fillingCounters.exists(physBase));
                fillingCounters[physBase] = 15;            
        endtask

    function automatic void reset();
        content = '{default: 0};
            filledBlocks.delete();
            fillingCounters.delete();
            readyToFill.delete();
    endfunction


    task automatic handleWrites();
        doWrite(TMP_writeReqs[0]);
    endtask


    task automatic doWrite(input MemWriteInfo wrInfo);
        Mbyte wval[4] = {>>{wrInfo.value}};
        if (wrInfo.req) content[wrInfo.adr +: 4] <= wval;
    endtask

        
        
        function automatic logic isPhysPresent(input Mword adr);
            Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
            return filledBlocks.exists(physBlockBase);
        endfunction

        function automatic logic isPhysPending(input Mword adr);
            Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
            return fillingCounters.exists(physBlockBase);
        endfunction
        
        

        function automatic Mword readFromMissRange(input Mword adr);
            // TODO: for now only word-sized
            Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
            DataBlock block = filledBlocks[physBlockBase];
            PhysicalAddressLow physLow = adrLow(adr);

            Mbyte chosenWord[4] = block[physLow +: 4];
            Mword wval = {>>{chosenWord}};
            Word val = Mword'(wval);
            
            return val;
        endfunction


        function automatic void allocInMissRange(input Mword adr);
            // TODO: for now only word-sized
            Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
            DataBlock block = '{default: 0};
            
            filledBlocks[physBlockBase] = block;            
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
                
                // if tr.present then:
                // now compare tr.pHigh to wayTag
                // if match, re.desc is applied and thisResult.data is applied 
                    
                // TMP: testing data miss handling
                if (isRangeDataMiss(tr.phys)) begin
                    if (isPhysPresent(tr.phys)) begin
                        thisResult.data = readFromMissRange(tr.phys);
                    end
                    else if (isPhysPending(tr.phys)) begin
                        thisResult.status = CR_TAG_MISS; // Already sent for allocation
                    end
                    else begin
                        thisResult.status = CR_TAG_MISS;                            
                        scheduleBlockFill(tr.phys);
                    end
                end
                    
                readOut[p] <= thisResult;
                accesses[p] <= acc;
                translations[p] <= tr;
            end

        end
    endtask


    function automatic DataCacheOutput doReadAccess(input AccessInfo aInfo, input Translation tr);
        DataCacheOutput res;

        Mbyte chosenWord[4] = content[aInfo.adr +: 4];
        Mword wval = {>>{chosenWord}};
        Word val = Mword'(wval);

        res = '{1, CR_HIT, tr.desc, val};

        return res;
    endfunction 




    function automatic Translation translateAddress(input EffectiveAddress adr);
        Translation res;

        if ($isunknown(adr)) return res;

        // Not translated - so far address is mappend to the same  

        res.vHigh = adrHigh(adr);

        // TMP:
        res.pHigh = res.vHigh; // Direct mapping of memory
        res.present = 1; // Obviously
        res.desc = '{
            allowed: 1,
            canRead: 1,
            canWrite: 1,
            canExec: 1,
            cached: 1
        };

            res.phys = {res.pHigh, adrLow(adr)};
            
        // TMP: uncached rnge
        if (adr[31])
            res.desc.cached = 0;

        return res;
    endfunction


    always @(posedge clk) begin
        handleFills();
    
        handleReads();
        handleWrites();    
    end


endmodule
