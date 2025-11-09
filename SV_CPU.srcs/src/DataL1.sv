
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

    // TLB
    localparam int BLOCKS_PER_WAY = WAY_SIZE/BLOCK_SIZE;

    typedef logic LogicA[N_MEM_PORTS];

    LogicA dataFillEnA, tlbFillEnA;

    UncachedSubsystem uncachedSubsystem(clk, writeReqs);

    DataTlb tlb(clk, theExecBlock.accessDescs_E0, tlbFillEngine.notifyFill, tlbFillEngine.notifiedTr);
    DataCacheArray dataArray(clk, writeReqs);

    DataFillEngine#(N_MEM_PORTS, 14) dataFillEngine(clk, dataFillEnA, theExecBlock.dcacheTranslations_E1);
    DataFillEngine#(N_MEM_PORTS, 11) tlbFillEngine(clk, tlbFillEnA, theExecBlock.dcacheTranslations_E1);



    function automatic DataCacheOutput doReadAccess(input Translation tr, input AccessDesc aDesc, input ReadResult_N readRes);
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
            res = '{1, CR_INVALID, 'x}; // Invalid virtual adr
        else if (!tr.present)
            res = '{1, CR_TLB_MISS, 'x}; // TLB miss
        else if (!tr.desc.canRead)
            res = '{1, CR_NOT_ALLOWED, 'x};
        else if (aDesc.store && !tr.desc.canWrite)
            res = '{1, CR_INVALID, 'x};
        else if (!tr.desc.cached)
            res = '{1, CR_UNCACHED, 'x}; // Just detected uncached access, tr.desc indicates uncached

        // If translation correct and content is cacheable, look at cache results
        else if (!readRes.valid)
            res = '{1, CR_TAG_MISS, 'x};
        else
            res = '{1, CR_HIT, readRes.value};

        return res;
    endfunction



    task automatic handleSingleRead(input int p);
        AccessDesc aDesc = theExecBlock.accessDescs_E0[p];

        cacheReadOut[p] <= EMPTY_DATA_CACHE_OUTPUT;

        if (!aDesc.active || $isunknown(aDesc.vadr)) return;
        else begin
            Translation tr = tlb.translationsH[p];
            ReadResult_N selectedResult;

            if (p == 0)      selectedResult = selectWayResult(dataArray.rdInterface[0].ar0, dataArray.rdInterface[0].ar1, tr);
            else if (p == 2) selectedResult = selectWayResult(dataArray.rdInterface[2].ar0, dataArray.rdInterface[2].ar1, tr);

            cacheReadOut[p] <= doReadAccess(tr, aDesc, selectedResult);
        end
    endtask


    // FUTURE: support for block crossing and page crossing accesses
    task automatic handleReads();
        foreach (theExecBlock.accessDescs_E0[p]) begin
            handleSingleRead(p);
        end
    endtask


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
                res = '{1, CR_HIT, uncachedSubsystem.readResult.data};
            else if (uncachedSubsystem.readResult.status == CR_INVALID)
                res = '{1, CR_INVALID, 0};
            else $error("Wrong status returned by uncached");
        end
        else if (aDesc.uncachedStore) begin
            res = '{1, CR_HIT, 'x};
        end

        return res;
    endfunction

////////////////////////

    ////////////////////////////////////
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



    always_comb dataFillEnA = dataFillEnables();
    always_comb tlbFillEnA = tlbFillEnables();


    always @(posedge clk) begin
        handleReadsUnc();
    end

    always @(posedge clk) begin
        handleReads();
    end

    assign translationsOut = tlb.translationsH;

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
