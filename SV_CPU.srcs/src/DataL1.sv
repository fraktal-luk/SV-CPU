
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

    PhysicalAddressHigh tagsForWay[BLOCKS_PER_WAY] = '{default: 0}; // tags for each block of way 0
    //InstructionLineDesc descsForWay[BLOCKS_PER_WAY] = '{default: 0};

    Mbyte content[4096]; // So far this corresponds to way 0


    typedef struct {
        EffectiveAddress adr;
        int accessSize;
        VirtualAddressHigh aHigh;
        VirtualAddressLow aLow;
        int block;
        int blockOffset;
        logic unaligned;
        logic blockCross;
        logic pageCross;
    } AccessInfo;

    localparam AccessInfo DEFAULT_ACCESS_INFO = '{
        adr: 'x,
        accessSize: -1,
        aHigh: 'x,
        aLow: 'x,
        block: -1,
        blockOffset: -1,
        unaligned: 'x,
        blockCross: 'x,
        pageCross: 'x 
    };


    typedef struct {
        logic present; // TLB hit
        VirtualAddressHigh vHigh;
        PhysicalAddressHigh pHigh;
        DataLineDesc desc;
    } Translation;

    localparam Translation DEFAULT_TRANSLATION = '{
        present: 0,
        vHigh: 'x,
        pHigh: 'x,
        desc: '{0}
    };


    AccessInfo accesses[N_MEM_PORTS];
    Translation translations[N_MEM_PORTS];        



    always @(posedge clk) begin
        handleReads();
        handleWrites();
        
    end


    function automatic void reset();
        content = '{default: 0};
    endfunction


    task automatic handleWrites();
//        MemWriteInfo wrInfo = TMP_writeReqs[0];        
//        Mbyte wval[4];
        
//        wval = {>>{wrInfo.value}};

//        if (wrInfo.req) content[wrInfo.adr +: 4] <= wval;
        
        doWrite(TMP_writeReqs[0]);
    endtask


    task automatic doWrite(input MemWriteInfo wrInfo);
        Mbyte wval[4] = {>>{wrInfo.value}};
        if (wrInfo.req) content[wrInfo.adr +: 4] <= wval;
    endtask


    // TODO: change to larger size
    task automatic handleReads();
        foreach (accesses[p]) begin
            accesses[p] <= analyzeAccess(readReqs[p].adr, 4);
            translations[p] <= translateAddress(readReqs[p].adr);
        end

        foreach (readReqs[p]) begin
            Mword vadr = readReqs[p].adr;

            if ($isunknown(vadr)) begin
                readOut[p] <= EMPTY_DATA_CACHE_OUTPUT;
            end
            else begin
                AccessInfo acc = analyzeAccess(vadr, 4);
                Translation tr = translateAddress(vadr);
                
                DataCacheOutput thisResult = doReadAccess(acc);
                
                PhysicalAddressHigh wayTag = tagsForWay[acc.block];
                // if tr.present then:
                // now compare tr.pHigh to wayTag
                // if match, re.desc is applied and thisResult.data is applied 
                
                readOut[p] <= thisResult;
            end

        end
    endtask


    function automatic DataCacheOutput doReadAccess(input AccessInfo aInfo);
        DataCacheOutput res;

        Mbyte chosenWord[4] = content[aInfo.adr +: 4];
        Mword wval = {>>{chosenWord}};
        Word val = Mword'(wval);

        res = '{1, CR_HIT, '{0}, val};

        return res;
    endfunction 



    function automatic VirtualAddressLow adrLow(input EffectiveAddress adr);
        return adr[V_INDEX_BITS-1:0];
    endfunction

    function automatic VirtualAddressHigh adrHigh(input EffectiveAddress adr);
        return adr[$size(EffectiveAddress)-1:V_INDEX_BITS];
    endfunction


    function automatic AccessInfo analyzeAccess(input EffectiveAddress adr, input int accessSize);
        AccessInfo res;
        
        VirtualAddressLow aLow = adrLow(adr);
        VirtualAddressHigh aHigh = adrHigh(adr);
        
        int block = aLow / BLOCK_SIZE;
        int blockOffset = aLow % BLOCK_SIZE;
        
        if ($isunknown(adr)) return DEFAULT_ACCESS_INFO;
        
        res.adr = adr;
        res.accessSize = accessSize;
        
        res.aHigh = aHigh;
        res.aLow = aLow;
        
        res.block = block;
        res.blockOffset = blockOffset;
        
        res.unaligned = (aLow % accessSize) > 0;
        res.blockCross = (blockOffset + accessSize) > BLOCK_SIZE;
        res.pageCross = (aLow + accessSize) > PAGE_SIZE;

        return res;
    endfunction


    function automatic Translation translateAddress(input EffectiveAddress adr);
        Translation res;

        if ($isunknown(adr)) return res;

        res.vHigh = adrHigh(adr);

        // TMP:
        res.pHigh = res.vHigh; // Direct mapping of memory
        res.present = 1; // Obviously
        res.desc = '{0};
        //res.canRead = 1;
        //res.canWrite = 1;

        return res;
    endfunction

endmodule
