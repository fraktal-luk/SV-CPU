
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import EmulationDefs::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;


module DataCacheArray#(parameter WIDTH = N_MEM_PORTS)
(
    input logic clk,
    input MemWriteInfo writeReqs[2]
);

    DataWay blocksWay0;
    DataWay blocksWay1;

    // Read interfaces
    generate
        genvar j;
        for (j = 0; j < WIDTH; j++) begin: rdInterface
            ReadResult_N ar0 = '{0, -1, 'x, 'x, 'x}, ar1 = '{0, -1, 'x, 'x, 'x};
            logic aq = 0;
            AccessDesc prevDesc = DEFAULT_ACCESS_DESC;

            task automatic readArray();
                AccessDesc aDesc = theExecBlock.accessDescs_E0[j];
                ar0 <= readWay(blocksWay0, aDesc);
                ar1 <= readWay(blocksWay1, aDesc);

                prevDesc <= aDesc;
                aq <= aDesc.active && aDesc.acq;
            endtask

            task automatic TMP_afterRead();
                ReadResult_N readRes = DataL1.cacheResults[j];

                if (!(j inside {0, 2}) || readRes.way == -1) return;

                if (aq) begin
                    //$error("Aq for way %d", readRes.way);

                    if (readRes.way == 0) TMP_lockWay(blocksWay0, prevDesc);
                    if (readRes.way == 1) TMP_lockWay(blocksWay1, prevDesc);
                end
                else begin
                    if (readRes.way == 0) TMP_unlockWay(blocksWay0, prevDesc);
                    if (readRes.way == 1) TMP_unlockWay(blocksWay1, prevDesc);
                end

            endtask

            always @(negedge clk) begin
                readArray();

                TMP_afterRead();
            end
        end
    endgenerate


    // Filling
    function automatic void allocInDynamicRange(input Dword adr);
        tryFillWay(blocksWay1, adr);
    endfunction
    
    // Write
    task automatic doCachedWrite(input MemWriteInfo wrInfo);
        if (!wrInfo.req || wrInfo.uncached) return;

        void'(tryWriteWay(blocksWay0, wrInfo));
        void'(tryWriteWay(blocksWay1, wrInfo));
    endtask


    // Init/DB
    task automatic resetArray();
        blocksWay0 = '{default: null};
        blocksWay1 = '{default: null};

        clearLocks();
    endtask

    task automatic clearLocks();
        foreach (blocksWay0[i]) if (blocksWay0[i] != null) blocksWay0[i].clearLock();
        foreach (blocksWay1[i]) if (blocksWay1[i] != null) blocksWay1[i].clearLock();
    endtask


    function automatic void preloadArrayForTest(); 
        foreach (AbstractCore.globalParams.preloadedDataWays[i])
            copyToWay(AbstractCore.globalParams.preloadedDataWays[i]);
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




    always @(posedge clk) begin
        if (dataFillEngine.notifyFill) begin
            allocInDynamicRange(dataFillEngine.notifiedTr.padr);
        end

            // ?
            if (AbstractCore.lateEventInfo.redirect && AbstractCore.lateEventInfo.cOp == CO_sync) clearLocks();

        doCachedWrite(writeReqs[0]);
    end

endmodule


/******************************************************************/
module DataTlb#(parameter int L1_SIZE = 32, parameter int WIDTH = N_MEM_PORTS)
(
    input logic clk,
    input AccessDesc ad[WIDTH],
    
    input logic notify,
    input Translation fillTr
);
    
    typedef Translation TranslationsW[WIDTH];
    
    Translation translations_T[WIDTH];
    Translation translationsH[WIDTH] = '{default: DEFAULT_TRANSLATION};

    Translation TMP_tlbL1[$];
    Translation TMP_tlbL2[$];

    Translation translationTableL1[L1_SIZE];

    task automatic resetTlb();
        TMP_tlbL1.delete();
        TMP_tlbL2.delete();
        DB_fillTranslations();
    endtask

    function automatic void preloadTlbForTest(input Translation tlbL1[$], input Translation tlbL2[$]);
        TMP_tlbL1 = tlbL1;
        TMP_tlbL2 = tlbL2;
        DB_fillTranslations();
    endfunction

    function automatic void DB_fillTranslations();
        int i = 0;
        translationTableL1 = '{default: DEFAULT_TRANSLATION};
        foreach (TMP_tlbL1[a]) begin
            translationTableL1[i] = TMP_tlbL1[a];
            i++;
        end
    endfunction


    function automatic TranslationsW getTranslations();
        TranslationsW res;

        foreach (res[p]) begin
            AccessDesc aDesc = ad[p];
            res[p] = translateAddress(aDesc, TMP_tlbL1, AbstractCore.CurrentConfig.enableMmu);
        end
        return res;
    endfunction


    function automatic void allocInTlb(input Mword adr);
        Translation found[$] = TMP_tlbL2.find with (item.vadr === getPageBaseM(adr));  
            
        assert (found.size() > 0) else $error("Not present in TLB L2");
        
        translationTableL1[TMP_tlbL1.size()] = found[0];
        TMP_tlbL1.push_back(found[0]);
    endfunction


    always_comb translations_T = getTranslations();

    // Read on half-cycle
    always @(negedge clk) begin
        translationsH <= getTranslations();
    end

    always @(posedge clk) begin
        if (notify) begin
            allocInTlb(fillTr.vadr);
        end
    end

endmodule



/*****************************************************************/
module DataFillEngine#(parameter int WIDTH = N_MEM_PORTS, parameter int DELAY = 14)
(
    input logic clk,
    input logic enable[WIDTH],
    Translation translations[WIDTH]
);
    logic notifyFill = 0;
    Translation notifiedTr = DEFAULT_TRANSLATION;

    int     blockFillCounters[Translation]; // Container for request in progress
    Translation     readyBlocksToFill[$]; // Queue of request ready for immediate completion 


    task automatic resetBlockFills();
        blockFillCounters.delete();
        readyBlocksToFill.delete();
        notifyFill <= 0;
        notifiedTr <= DEFAULT_TRANSLATION;
    endtask

    task automatic handleBlockFills();
        Translation tr;

        notifyFill <= 0;
        notifiedTr <= DEFAULT_TRANSLATION;

        foreach (blockFillCounters[t]) begin
            if (blockFillCounters[t] == 0) begin
                readyBlocksToFill.push_back(t);
                blockFillCounters[t] = -1;
            end
            else blockFillCounters[t]--;
        end

        if (readyBlocksToFill.size() == 0) return;

        tr = readyBlocksToFill.pop_front();
        blockFillCounters.delete(tr); //

        notifyFill <= 1;
        notifiedTr <= tr;
    endtask

    task automatic scheduleBlockFills();
        foreach (enable[p]) begin
            if (enable[p]) begin
                Translation tr = translations[p];
                tr.vadr = getPageBaseM(tr.vadr);    // vadr is used for finding page mappings
                tr.padr = $isunknown(tr.padr) ? 'x : getBlockBaseD(tr.padr); // padr is used to find data blocks
                scheduleBlockFill(tr);
            end
        end
    endtask

    function automatic void scheduleBlockFill(input Translation tr);
        if (!blockFillCounters.exists(tr))
            blockFillCounters[tr] = DELAY;
    endfunction
    

    always @(posedge clk) begin
        handleBlockFills();
        scheduleBlockFills();
    end

endmodule



//**********************************************************************************************************************************//
module UncachedSubsystem(
    input logic clk,
    input MemWriteInfo TMP_writeReqs[2]
);

    typedef struct {
        logic ready = 0;
        logic ongoing = 0;
        Mword adr = 'x;
        AccessSize size = SIZE_NONE;
        int counter = -1;
    } UncachedRead;

    UncachedRead uncachedReads[N_MEM_PORTS]; // Should be one (ignore other than [0])

    int uncachedCounter = -1;
    logic uncachedBusy = 0;
    DataCacheOutput readResult = EMPTY_DATA_CACHE_OUTPUT;

    localparam Mword UNCACHED_BASE = 'h0000000040000000;
    Mbyte uncachedArea[PAGE_SIZE];


    task automatic UNC_reset();
        uncachedCounter = -1;
        uncachedBusy <= 0;
        readResult <= EMPTY_DATA_CACHE_OUTPUT;
        
        uncachedArea = '{default: 0};
    endtask


    function automatic void UNC_scheduleUncachedRead(input AccessDesc aDesc);
        uncachedReads[0].ongoing = 1;
        uncachedReads[0].counter = 8;
        uncachedReads[0].adr = aDesc.vadr;
        uncachedReads[0].size = aDesc.size;
    endfunction
    
    function automatic void UNC_clearUncachedRead();
        uncachedReads[0].ready = 0;
        uncachedReads[0].adr = 'x;
        readResult <= EMPTY_DATA_CACHE_OUTPUT;
    endfunction

    function automatic DataCacheOutput readFromUncachedRange(input Mword adr, input AccessSize size);
        Mword value = 'x;
        DataCacheOutput res = EMPTY_DATA_CACHE_OUTPUT;
        
        if (!physicalAddressValid(adr)) begin
            res.active = 1;
            res.status = CR_INVALID;
            res.data = 0;
            return res;
        end

        if (size == SIZE_1) value = readByteUncached(adr);
        else if (size == SIZE_4) value = readWordUncached(adr);
        else $error("Wrong access size");

        res.active = 1;
        res.status = CR_HIT;
        res.data = value;

        return res;
    endfunction
    
    /////////////////
    function automatic void writeToUncachedRangeW(input Mword adr, input Mword val);
        PageWriter#(Word, 4, UNCACHED_BASE)::writeTyped(uncachedArea, adr, val);
    endfunction

    function automatic void writeToUncachedRangeB(input Mword adr, input Mbyte val);
        PageWriter#(Mbyte, 1, UNCACHED_BASE)::writeTyped(uncachedArea, adr, val);
    endfunction

    function automatic Mword readWordUncached(input Mword adr);
        return PageWriter#(Word, 4, UNCACHED_BASE)::readTyped(uncachedArea, adr);
    endfunction

    function automatic Mword readByteUncached(input Mword adr);
        return Mword'(PageWriter#(Mbyte, 1, UNCACHED_BASE)::readTyped(uncachedArea, adr));
    endfunction
    //////////////////////

    task automatic UNC_write(input MemWriteInfo wrInfo);
        Dword padr = wrInfo.padr;
        Mword val = wrInfo.value;

        uncachedCounter = 15;
        uncachedBusy <= 1;

        if (wrInfo.size == SIZE_1) writeToUncachedRangeB(padr, val);
        if (wrInfo.size == SIZE_4) writeToUncachedRangeW(padr, val);
    endtask


    // uncached read pipe
    task automatic UNC_handleUncachedData();
        if (uncachedCounter == 0) uncachedBusy <= 0;
        if (uncachedCounter >= 0) uncachedCounter--;

        if (uncachedReads[0].ongoing) begin
            if (--uncachedReads[0].counter == 0) begin
                uncachedReads[0].ongoing = 0;
                uncachedReads[0].ready = 1;
                readResult <= readFromUncachedRange(uncachedReads[0].adr, uncachedReads[0].size);
            end
        end

        foreach (theExecBlock.accessDescs_E0[p]) begin
            AccessDesc aDesc = theExecBlock.accessDescs_E0[p];
            if (!aDesc.active || $isunknown(aDesc.vadr)) continue;
            else if (aDesc.uncachedReq) UNC_scheduleUncachedRead(aDesc); // request for uncached read
            else if (aDesc.uncachedCollect) UNC_clearUncachedRead();
        end
    endtask


    always @(posedge clk) begin
        UNC_handleUncachedData();        

        if (TMP_writeReqs[0].req && TMP_writeReqs[0].uncached) begin
            UNC_write(TMP_writeReqs[0]);
        end
    end

endmodule
