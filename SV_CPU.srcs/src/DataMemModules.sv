
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import EmulationDefs::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;


module DataCacheArray#(parameter int N_WAYS, parameter int WIDTH = N_MEM_PORTS)
(
    input logic clk,
    input MemWriteInfo writeReqs[2]
);

    DataWay ways[N_WAYS];

    DataWay blocksWay0;
    DataWay blocksWay1;

    // Read interfaces
    generate
        genvar j;
        for (j = 0; j < WIDTH; j++) begin: rdInterface
            ReadResult aResults[N_WAYS] = '{default: '{0, -1, 'x, 'x, 'x}};
            ReadResult ar0 = '{0, -1, 'x, 'x, 'x}, ar1 = '{0, -1, 'x, 'x, 'x};
            logic aq = 0;
            AccessDesc prevDesc = DEFAULT_ACCESS_DESC;

            task automatic readArray();
                AccessDesc aDesc = theExecBlock.accessDescs_E0[j];


                foreach (ways[i]) aResults[i] = readWay(ways[i], aDesc);

                ar0 <= readWay(blocksWay0, aDesc);
                ar1 <= readWay(blocksWay1, aDesc);

                prevDesc <= aDesc;
                aq <= aDesc.active && aDesc.acq;
            endtask


            always @(negedge clk) begin
                readArray();
            end

            always @(posedge clk) begin
                TMP_locking();
            end

            task automatic TMP_locking();
                Translation tr = tlb.translationsH[j];
                ReadResult selectedResult = selectWayResult(ar0, ar1, tr);
                AccessDesc aDesc = theExecBlock.accessDescs_E0[j];

                    if (aq) begin
                        if (selectedResult.way == 0) TMP_lockWay(blocksWay0, aDesc);
                        if (selectedResult.way == 1) TMP_lockWay(blocksWay1, aDesc);
                    end
                    else begin
                        if (selectedResult.way == 0) TMP_unlockWay(blocksWay0, aDesc);
                        if (selectedResult.way == 1) TMP_unlockWay(blocksWay1, aDesc);
                    end

                if (aq) TMP_lockWay(ways[selectedResult.way], aDesc);
                else    TMP_unlockWay(ways[selectedResult.way], aDesc);
            endtask

        end
    endgenerate


    // Filling
    function automatic void allocInDynamicRange(input Dword adr);
        tryFillWay(blocksWay1, adr);
            tryFillWay(ways[1], adr); // TODO - temporary filling always way 1
    endfunction
    
    // Write
    task automatic doCachedWrite(input MemWriteInfo wrInfo);
        if (!wrInfo.req || wrInfo.uncached) return;

        void'(tryWriteWay(blocksWay0, wrInfo));
        void'(tryWriteWay(blocksWay1, wrInfo));

        foreach (ways[i]) void'(tryWriteWay(ways[i], wrInfo));
    endtask


    // Init/DB
    task automatic resetArray();
        blocksWay0 = '{default: null};
        blocksWay1 = '{default: null};

            ways = '{default: '{default: null}};

        clearLocks();
    endtask

    task automatic clearLocks();
        foreach (blocksWay0[i]) if (blocksWay0[i] != null) blocksWay0[i].clearLock();
        foreach (blocksWay1[i]) if (blocksWay1[i] != null) blocksWay1[i].clearLock();

        foreach (ways[i]) begin
            DataWay way = ways[i];
            foreach (way[b]) if (way[b] != null) way[b].clearLock();
        end
    endtask


    function automatic void preloadArrayForTest(); 
        foreach (AbstractCore.globalParams.preloadedDataWays[i])
            copyToWay(AbstractCore.globalParams.preloadedDataWays[i]);
    endfunction

    // CAREFUL: this sets all data to default values
    function automatic void copyToWay(Dword pageAdr);
        Dword pageBase = getPageBaseD(pageAdr);
        int wayNum = pageBase/PAGE_SIZE;

        case (pageBase)
            0:              initBlocksWay(blocksWay0, 0);
            PAGE_SIZE:      initBlocksWay(blocksWay1, PAGE_SIZE);
            default: $error("Incorrect page to init cache: %x", pageBase);
        endcase

        assert (wayNum >= 0 && wayNum < N_WAYS) else $fatal(2, "Wrong way num");

            initBlocksWay(ways[wayNum], pageBase);

    endfunction




    always @(posedge clk) begin
        if (dataFillEngine.notifyFill) begin
              //  $error("Fill block\n%p", dataFillEngine.notifiedTr);

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
