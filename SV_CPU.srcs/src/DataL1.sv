
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import EmulationDefs::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;


module DataL1(
            input logic clk,
            input MemWriteInfo writeReqs[2],
            output Translation translationsOut[N_MEM_PORTS],
            output DataCacheOutput cacheReadOut[N_MEM_PORTS],
            output DataCacheOutput uncachedReadOut[N_MEM_PORTS]
);


    typedef logic LogicA[N_MEM_PORTS];

    LogicA dataFillEnA, tlbFillEnA;

    UncachedDataUnit uncachedSubsystem(clk, writeReqs);


    DataTlb tlb(clk, theExecBlock.accessDescs_E0, tlbFillEngine.notifyFill, tlbFillEngine.notifiedTr);
    DataCacheArray#(.N_WAYS(N_WAYS_DATA)) dataArray(clk, writeReqs);

    DataFillEngine#(N_MEM_PORTS, 14) dataFillEngine(clk, dataFillEnA, theExecBlock.dcacheTranslations_E1);
    DataFillEngine#(N_MEM_PORTS, 11) tlbFillEngine(clk, tlbFillEnA, theExecBlock.dcacheTranslations_E1);

    ReadResult cacheResults[N_MEM_PORTS] = '{default: '{0, -1, 'x, 'x, 'x}};


    always_comb dataFillEnA = dataFillEnables();
    always_comb tlbFillEnA = tlbFillEnables();

    always @(posedge clk) begin
        handleReads();
    end

    assign translationsOut = tlb.translationsH;


    function automatic DataCacheOutput doReadAccess(input Translation tr, input AccessDesc aDesc, input ReadResult readRes);
        DataCacheOutput res = EMPTY_DATA_CACHE_OUTPUT;        

        // Actions from replay or sys read (access checks don't apply, no need to lookup TLB) - they are not handled by cache
        if (0) begin end
        // sys regs
        else if (aDesc.sys) begin end

        // uncached access
        else if (aDesc.uncachedReq) begin end
        else if (aDesc.uncachedCollect) begin end
        else if (aDesc.uncachedStore) begin end

        // Otherwise check translation
        else if (!virtualAddressValid(aDesc.vadr))
            res = '{1, CR_INVALID, 'x, 'x}; // Invalid virtual adr
        else if (!tr.present)
            res = '{1, CR_TLB_MISS, 'x, 'x}; // TLB miss
        else if (!tr.desc.canRead)
            res = '{1, CR_NOT_ALLOWED, 'x, 'x};
        else if (aDesc.store && !tr.desc.canWrite)
            res = '{1, CR_NOT_ALLOWED, 'x, 'x};
        else if (!tr.desc.cached)
            res = '{1, CR_UNCACHED, 'x, 'x}; // Just detected uncached access, tr.desc indicates uncached

        // If translation correct and content is cacheable, look at cache results
        else if (!readRes.valid)
            res = '{1, CR_TAG_MISS, 'x, 'x};
        else
            res = '{1, CR_HIT, readRes.locked, readRes.value};

        return res;
    endfunction


    task automatic handleSingleRead(input int p);
        AccessDesc aDesc = theExecBlock.accessDescs_E0[p];

        cacheResults[p] <= '{0, -1, 'x, 'x, 'x};
        cacheReadOut[p] <= EMPTY_DATA_CACHE_OUTPUT;

        if (!aDesc.active || $isunknown(aDesc.vadr)) return;
        else begin
            Translation tr = tlb.translationsH[p];
            ReadResult selectedResult, selectedResult_N;

            if (p == 0) selectedResult_N = selectWayResultArray(tr, dataArray.rdInterface[0].aResults);
            else if (p == 2) selectedResult_N = selectWayResultArray(tr, dataArray.rdInterface[2].aResults);

            cacheResults[p] <= selectedResult_N;
            cacheReadOut[p] <= doReadAccess(tr, aDesc, selectedResult_N);
        end
    endtask


    task automatic handleReads();
        foreach (theExecBlock.accessDescs_E0[p]) begin
            handleSingleRead(p);
        end
    endtask

    function automatic LogicA dataFillEnables();
        LogicA res = '{default: 0};
        foreach (cacheReadOut[p])
            res[p] = (cacheReadOut[p].status == CR_TAG_MISS);
        return res;
    endfunction

    function automatic LogicA tlbFillEnables();
        LogicA res = '{default: 0};
        foreach (cacheReadOut[p])
            res[p] = (cacheReadOut[p].status == CR_TLB_MISS);
        return res;
    endfunction



    ////////////////////////
    // Unc
    
    task automatic handleReadsUnc();
        foreach (theExecBlock.accessDescs_E0[p]) begin
            handleSingleReadUnc(p);
        end
    endtask

    task automatic handleSingleReadUnc(input int p);
        AccessDesc aDesc = theExecBlock.accessDescs_E0[p];

        uncachedReadOut[p] <= EMPTY_DATA_CACHE_OUTPUT;

        if (!aDesc.active || $isunknown(aDesc.vadr)) return;
        else begin
            uncachedReadOut[p] <= doReadAccessUnc(aDesc);
        end
    endtask


    function automatic DataCacheOutput doReadAccessUnc(input AccessDesc aDesc);
        DataCacheOutput res = EMPTY_DATA_CACHE_OUTPUT;        

        // Actions from replay or sys read (access checks don't apply, no need to lookup TLB) - they are not handled by cache
        if (0) begin end
        // sys regs
        else if (aDesc.sys) begin end

        // uncached access
        else if (aDesc.uncachedReq) begin end
        else if (aDesc.uncachedCollect) begin // Completion of uncached read              
            if (uncachedSubsystem.readResult.status == CR_HIT)
                res = '{1, CR_HIT, 'x, uncachedSubsystem.readResult.data};
            else if (uncachedSubsystem.readResult.status == CR_INVALID)
                res = '{1, CR_INVALID, 'x, 0};
            else $error("Wrong status returned by uncached");
        end
        else if (aDesc.uncachedStore) begin
            res = '{1, CR_HIT, 'x, 'x};
        end

        return res;
    endfunction


    always @(posedge clk) begin
        handleReadsUnc();
    end

/////////////////
// Init and DB

    task automatic reset();
        cacheReadOut <= '{default: EMPTY_DATA_CACHE_OUTPUT};
        uncachedReadOut <= '{default: EMPTY_DATA_CACHE_OUTPUT};

        uncachedSubsystem.UNC_reset();

        dataFillEngine.resetBlockFills();
        tlbFillEngine.resetBlockFills();

        tlb.resetTlb();
        dataArray.resetArray();
    endtask

    function automatic void preloadForTest();
        tlb.preloadTlbForTest(AbstractCore.globalParams.preloadedDataTlbL1, AbstractCore.globalParams.preloadedDataTlbL2);
        dataArray.preloadArrayForTest();
    endfunction

endmodule
