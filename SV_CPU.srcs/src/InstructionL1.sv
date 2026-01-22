

import Base::*;
import InsDefs::*;
import Asm::*;
import EmulationDefs::*;
import EmulationMemories::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;


module InstructionL1(
                input logic clk,
                
                input logic readEn,
                input Mword readAddress,
                output InstructionCacheOutput readOut
              );

    localparam int N_WAYS_INS = 4;


    Translation translationSig = DEFAULT_TRANSLATION;

    Translation tr_Reg[1];

    InstructionCacheOutput readOutCached, readOutUncached;


    typedef logic LogicA[1];

    AccessDesc aDesc_T;

    LogicA blockFillEnA, tlbFillEnA;


    DataTlb#(.WIDTH(1)) tlb(clk, '{0: aDesc_T}, tlbFillEngine.notifyFill, tlbFillEngine.notifiedTr);
    InstructionCacheArray#(.N_WAYS(N_WAYS_INS)) insArray(clk, blockFillEngine.notifyFill, blockFillEngine.notifiedTr);

    DataFillEngine#(1, 14) blockFillEngine(clk, blockFillEnA, tr_Reg);
    DataFillEngine#(1, 11) tlbFillEngine(clk, tlbFillEnA, tr_Reg);


    always_comb aDesc_T = getAccessDesc_I(readEn, readAddress);
    assign tr_Reg[0] = translationSig;
    assign readOut = readOutCached;


    always @(posedge clk) begin
        doCacheAccess();
    end


    task automatic doCacheAccess();
        AccessDesc aDesc = getAccessDesc_I(readEn, readAddress);
        
        readOutCached <= EMPTY_INS_CACHE_OUTPUT;
        
        if (!aDesc.active) return;
        
        begin
            Translation tr = tlb.translationsH[0];
            ReadResult_I reads[N_WAYS_INS], matched[N_WAYS_INS];

            foreach (reads[i]) reads[i] = insArray.rdInterface[0].aResults[i];
            foreach (reads[i]) matched[i] = matchWay_I(reads[i], tr);

            translationSig <= tr;
            readOutCached <= readCache(readEn, tr, /*result0m, result1m, result2m, result3m,*/ matched);
        end
    endtask

    function automatic InstructionCacheOutput readCache(input logic readEnable, input Translation tr, input ReadResult_I results[]);
        InstructionCacheOutput res = EMPTY_INS_CACHE_OUTPUT;
        ReadResult_I selected = selectWayArray_I(results);

        if (!readEnable) return res;

        if (!tr.present)          res.status = CR_TLB_MISS; // TLB miss
        else if (!tr.desc.cached) res.status = CR_UNCACHED; // Not cached
        else if (!selected.valid) res.status = CR_TAG_MISS; // Miss
        else begin         // Hit
            res.status = CR_HIT;
            res.words = selected.value;
        end
        
        res.active = 1;
        res.desc = tr.desc;
        
        return res;
    endfunction

    function automatic ReadResult_I matchWay_I(input ReadResult_I rr, input Translation tr);
        ReadResult_I res = rr;
        Dword accessPbase = getBlockBaseD(tr.padr);       
        logic hit0 = (accessPbase === rr.tag);
        
        res.valid &= hit0;
        return res;
    endfunction

    function automatic ReadResult_I selectWayArray_I(input ReadResult_I results[]);
        foreach (results[i]) begin
            if (results[i].valid === 1) return results[i];
        end
        return results[results.size()-1];
    endfunction


        function automatic AccessDesc getAccessDesc_I(input logic en, input Mword adr);
            AccessDesc res;
            AccessInfo aInfo = analyzeAccess(adr, SIZE_INS_LINE);

            res.active = en;

            res.size = SIZE_INS_LINE;

            res.store = 1;
            res.sys = 0;
            res.uncachedReq = 0;
            res.uncachedCollect = 0;
            res.uncachedStore = 0;
            
            res.vadr = adr;
            
            res.blockIndex = aInfo.block;
            res.blockOffset = aInfo.blockOffset;
    
            res.unaligned = aInfo.unaligned;
            res.blockCross = aInfo.blockCross;
            res.pageCross = aInfo.pageCross;
        
            return res;
        endfunction



    function automatic void preloadForTest();
        tlb.preloadTlbForTest(AbstractCore.globalParams.preloadedInsTlbL1, AbstractCore.globalParams.preloadedInsTlbL2);
        insArray.preloadForTest();
    endfunction


    task automatic reset();
        readOutUncached <= EMPTY_INS_CACHE_OUTPUT;
        readOutCached <= EMPTY_INS_CACHE_OUTPUT;
        
        tlb.resetTlb();
        insArray.resetArray();
        
        blockFillEngine.resetBlockFills();
        tlbFillEngine.resetBlockFills();
    endtask


    always_comb blockFillEnA = dataMakeEnables();
    always_comb tlbFillEnA = tlbMakeEnables();
/////////////////////////////////////////////////


    function automatic LogicA dataMakeEnables();
        LogicA res = '{default: 0};
        res[0] = (readOutCached.status == CR_TAG_MISS);
        return res;
    endfunction

    function automatic LogicA tlbMakeEnables();
        LogicA res = '{default: 0};
        res[0] = (readOutCached.status == CR_TLB_MISS);
        return res;
    endfunction

endmodule




module InstructionCacheArray
#(
    parameter int N_WAYS
)
(
    input logic clk,
    input logic notify,
    input Translation fillTr
);
    InsWay ways[N_WAYS];

    // Read interfaces
    generate
        genvar j;
        for (j = 0; j < 1; j++) begin: rdInterface
            ReadResult_I aResults[N_WAYS] = '{default: '{0, 'x, '{default: 'x}}};

            task automatic readArray();
                AccessDesc aDesc = instructionCache.aDesc_T;
                foreach (aResults[i])
                    aResults[i] <= readWay_I(ways[i], aDesc);
            endtask

            always @(negedge clk) begin
                readArray();
            end
        end
    endgenerate


    // Init/DB
    task automatic resetArray();
        foreach (ways[i]) ways[i] = '{default: null};
    endtask

    function automatic void preloadForTest();
        foreach (AbstractCore.globalParams.preloadedInsWays[i]) copyToWay_I(AbstractCore.globalParams.preloadedInsWays[i]);
    endfunction

    // Filling
    function automatic void allocInDynamicRange(input Dword adr);
        // TODO: way 3 for all fills - temporary
        tryFillWay_I(ways[3], adr, AbstractCore.programMem.getPage(getPageBaseD(adr)));
    endfunction

    function automatic void copyToWay_I(Dword pageAdr);
        Dword pageBase = getPageBaseD(pageAdr);
        int pageNum = pageBase/PAGE_SIZE;
        assert (pageNum >= 0 && pageNum < N_WAYS) else $fatal(2, "Wrong page number %d", pageNum);
        initBlocksWay_I(ways[pageNum], pageBase, AbstractCore.programMem.getPage(pageBase));
    endfunction


    always @(posedge clk) begin
        if (notify) begin
            allocInDynamicRange(fillTr.padr);
        end
    end

endmodule
