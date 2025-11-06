
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import EmulationDefs::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;


module DataCacheArray#()
(
    input logic clk,
    input MemWriteInfo writeReqs[2]
);

    DataWay blocksWay0;
    DataWay blocksWay1;
    
    // N_MEM_PORTS read interfaces
    generate
        genvar j;
        for (j = 0; j < N_MEM_PORTS; j++) begin: QHU
            ReadResult_N ar0 = '{0, 'x, 'x}, ar1 = '{0, 'x, 'x}, se = '{0, 'x, 'x};
            ReadResult_N ur0 = '{0, 'x, 'x}, ur1 = '{0, 'x, 'x};
    
            task automatic readArray();
                int p = j;

                AccessDesc aDesc = theExecBlock.accessDescs_E0[p];
    
                ar0 <= readWay_N(blocksWay0, aDesc);
                ar1 <= readWay_N(blocksWay1, aDesc);
            endtask
    
            task automatic selectArray();
                int p = j;
    
                AccessDesc aDesc = theExecBlock.accessDescs_E0[p];
                Translation tr = tlb.translationsH[p];
    
                ur0 <= matchWay_N(ar0, aDesc, tr);
                ur1 <= matchWay_N(ar1, aDesc, tr);

                se <= '{0, 'x, 'x};
                se <= selectWayResult_N(ar0, ar1, tr);
            endtask


            always @(negedge clk) begin
                readArray();
            end
        
            always @(posedge clk) begin
                selectArray();
            end
        end
    endgenerate


    function automatic void allocInDynamicRange(input Dword adr);
        tryFillWay(blocksWay1, adr);
    endfunction

    task automatic doCachedWrite(input MemWriteInfo wrInfo);
        if (!wrInfo.req || wrInfo.uncached) return;

        void'(tryWriteWay(blocksWay0, wrInfo));
        void'(tryWriteWay(blocksWay1, wrInfo));
    endtask

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

        doCachedWrite(writeReqs[0]);
    end


    task automatic resetArray();

        blocksWay0 = '{default: null};
        blocksWay1 = '{default: null};

    endtask

    function automatic void preloadArrayForTest(); 
        foreach (AbstractCore.globalParams.preloadedDataWays[i])
            copyToWay(AbstractCore.globalParams.preloadedDataWays[i]);
    endfunction


endmodule


/******************************************************************/
module DataTlb#(parameter int L1_SIZE = 32, parameter int WIDTH = N_MEM_PORTS)
(
    input logic clk
    //input logic enable[WIDTH],
    //Translation translations[WIDTH]
);
    
    Translation translations_T[N_MEM_PORTS];
    Translation translationsH[N_MEM_PORTS] = '{default: DEFAULT_TRANSLATION};


        Translation TMP_tlbL1[$];
        Translation TMP_tlbL2[$];
    
        Translation translationTableL1[L1_SIZE]; // DB


        task automatic resetTlb();
            TMP_tlbL1.delete();
            TMP_tlbL2.delete();
            DB_fillTranslations();
            
            tlbFillEngine.resetBlockFills();
        endtask
    
        function automatic void preloadTlbForTest();
            TMP_tlbL1 = AbstractCore.globalParams.preloadedDataTlbL1;
            TMP_tlbL2 = AbstractCore.globalParams.preloadedDataTlbL2;
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

        ////////////////////
        // translation
        
        function automatic Translation translateAddress(input Mword adr);    
            Translation res = DEFAULT_TRANSLATION;
            Translation found[$] = TMP_tlbL1.find with (item.vadr == getPageBaseM(adr));
    
            if ($isunknown(adr)) return DEFAULT_TRANSLATION;
            if (!AbstractCore.CurrentConfig.enableMmu) return '{present: 1, vadr: adr, desc: '{1, 1, 1, 1, 0}, padr: adr};
    
            assert (found.size() <= 1) else $fatal(2, "multiple hit in itlb\n%p", TMP_tlbL1);
    
            if (found.size() == 0) begin
                res.vadr = adr; // It's needed because TLB fill is based on this adr
                return res;
            end
    
            res = found[0];
    
            res.vadr = adr;
            res.padr = res.padr + (adr - getPageBaseM(adr));
    
            return res;
        endfunction
    
    
        function automatic TranslationA getTranslations();
            TranslationA res = '{default: DEFAULT_TRANSLATION};
    
            foreach (res[p]) begin
                AccessDesc aDesc = theExecBlock.accessDescs_E0[p];
                if (!aDesc.active || $isunknown(aDesc.vadr)) continue;
                res[p] = translateAddress(aDesc.vadr);
            end
            return res;
        endfunction
    
    
        function automatic void allocInTlb(input Mword adr);
            Translation found[$] = TMP_tlbL2.find with (item.vadr === getPageBaseM(adr));  
                
            assert (found.size() > 0) else $error("Not present in TLB L2");
            
            translationTableL1[TMP_tlbL1.size()] = found[0];
            TMP_tlbL1.push_back(found[0]);
        endfunction


    ///////////////////////////////////////////////////

    always_comb translations_T = getTranslations();

    // Read on half-cycle
    always @(negedge clk) begin
        translationsH <= getTranslations();
    end


    always @(posedge clk) begin
        if (tlbFillEngine.notifyFill) begin
            allocInTlb(tlbFillEngine.notifiedTr.vadr);
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
