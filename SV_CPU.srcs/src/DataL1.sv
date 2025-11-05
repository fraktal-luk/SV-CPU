
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

    DataTlb tlb(clk);

    DataFillEngine#(N_MEM_PORTS, 14) dataFillEngine(clk, dataFillEnA, theExecBlock.dcacheTranslations_E1);
    DataFillEngine#(N_MEM_PORTS, 11) tlbFillEngine(clk, tlbFillEnA, theExecBlock.dcacheTranslations_E1);

    DataWay blocksWay0;
    DataWay blocksWay1;



    task automatic doCachedWrite(input MemWriteInfo wrInfo);
        if (!wrInfo.req || wrInfo.uncached) return;

        void'(tryWriteWay(blocksWay0, wrInfo));
        void'(tryWriteWay(blocksWay1, wrInfo));
    endtask

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
            // Read all ways of cache with tags
            ReadResult result0 = readWay(blocksWay0, aDesc, tr);
            ReadResult result1 = readWay(blocksWay1, aDesc, tr);
            ReadResult selectedResult = selectWayResult(result0, result1);

            cacheReadOut[p] <= doReadAccess(tr, aDesc, selectedResult);
        end
    endtask


    // FUTURE: support for block crossing and page crossing accesses
    task automatic handleReads();
        foreach (theExecBlock.accessDescs_E0[p]) begin
            handleSingleRead(p);
        end
    endtask

    function automatic void allocInDynamicRange(input Dword adr);
        tryFillWay(blocksWay1, adr);
    endfunction



/////////////////
// Init and DB

    task automatic reset();
        cacheReadOut <= '{default: EMPTY_DATA_CACHE_OUTPUT};

        blocksWay0 = '{default: null};
        blocksWay1 = '{default: null};

        dataFillEngine.resetBlockFills();

        uncachedSubsystem.UNC_reset();

        tlb.resetTlb();
    endtask

    function automatic void initBlocksWay(ref DataWay way, input Mword baseVadr);
        foreach (way[i]) begin
            Mword vadr = baseVadr + i*BLOCK_SIZE;
            Dword padr = vadr;

            way[i] = new();
            way[i].valid = 1;
            way[i].vbase = vadr;
            way[i].pbase = padr;
            way[i].array = CLEAN_BLOCK;
        end
    endfunction

    // CAREFUL: this sets all data to default values
    function automatic void copyToWay(Dword pageAdr);
        Dword pageBase = getPageBaseD(pageAdr);

        case (pageBase)
            0:              initBlocksWay(blocksWay0, 0);
            PAGE_SIZE:      initBlocksWay(blocksWay1, PAGE_SIZE);
            default: $error("Incorrect page to init cache: %x", pageBase);
        endcase
    endfunction


    function automatic void preloadForTest();
        tlb.preloadTlbForTest();
 
        foreach (AbstractCore.globalParams.preloadedDataWays[i])
            copyToWay(AbstractCore.globalParams.preloadedDataWays[i]);
    endfunction

////////////////////////
    always_comb dataFillEnA = dataFillEnables();
    always_comb tlbFillEnA = tlbFillEnables();

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


    always @(posedge clk) begin
        handleReadsUnc();
    end

    always @(posedge clk) begin
        handleReads();

        if (dataFillEngine.notifyFill) begin
            allocInDynamicRange(dataFillEngine.notifiedTr.padr);
        end

        doCachedWrite(writeReqs[0]);
    end

    assign translationsOut = tlb.translationsH;

endmodule
