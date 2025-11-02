
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import EmulationDefs::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;




/*****************************************************************/
module DataFillEngine#(type Key = Dword, parameter int WIDTH = N_MEM_PORTS, parameter int DELAY = 14)
(
    input logic clk,
    
        input logic enable[WIDTH],
        input Key dataIn[WIDTH], //,
        Translation translations[WIDTH]
        //input DataCacheOutput reads[WIDTH]
);
    // Fill logic
    logic notifyFill = 0;

    Key notifiedAdr = 'x;
    Translation notifiedTr = DEFAULT_TRANSLATION;


    int     blockFillCounters[Key]; // Container for request in progress
    int     blockFillCounters_T[Translation]; // Container for request in progress

    Key     readyBlocksToFill[$]; // Queue of request ready for immediate completion 
    Translation     readyBlocksToFill_T[$]; // Queue of request ready for immediate completion 


    task automatic resetBlockFills();
        blockFillCounters.delete();
        blockFillCounters_T.delete();
        readyBlocksToFill.delete();
        readyBlocksToFill_T.delete();
        notifyFill <= 0;
        notifiedAdr <= 'x;
        notifiedTr <= DEFAULT_TRANSLATION;
    endtask


    task automatic handleBlockFills();
        Key adr;

        notifyFill <= 0;
        notifiedAdr <= 'x;

        foreach (blockFillCounters[a]) begin
            if (blockFillCounters[a] == 0) begin
                readyBlocksToFill.push_back(a);
                blockFillCounters[a] = -1;
            end
            else blockFillCounters[a]--;
        end

        if (readyBlocksToFill.size() == 0) return;

        adr = readyBlocksToFill.pop_front();
        blockFillCounters.delete(adr); //

        notifyFill <= 1;
        notifiedAdr <= adr;
    endtask

    task automatic handleBlockFills_T();
        Translation tr;

        //notifyFill <= 0;
        //notifiedAdr <= 'x;
        notifiedTr <= DEFAULT_TRANSLATION;

        foreach (blockFillCounters_T[t]) begin
            if (blockFillCounters_T[t] == 0) begin
                readyBlocksToFill_T.push_back(t);
                blockFillCounters_T[t] = -1;
            end
            else blockFillCounters_T[t]--;
    

        end

        if (readyBlocksToFill_T.size() == 0) return;

        tr = readyBlocksToFill_T.pop_front();
        blockFillCounters_T.delete(tr); //

        //notifyFill <= 1;
        //notifiedAdr <= adr;
        notifiedTr <= tr;
    endtask


    task automatic scheduleBlockFills();
        foreach (enable[p]) begin
            if (enable[p]) begin
                Key padr = dataIn[p];
                scheduleBlockFill(padr);
            end
        end
    endtask

    function automatic void scheduleBlockFill(input Key adr);
        if (!blockFillCounters.exists(adr))
            blockFillCounters[adr] = DELAY;            
    endfunction


        task automatic scheduleBlockFills_T();
            foreach (enable[p]) begin
                if (enable[p]) begin
                    Translation tr = translations[p];
                    scheduleBlockFill_T(tr);
                end
            end
        endtask
    
        function automatic void scheduleBlockFill_T(input Translation tr);
            if (!blockFillCounters_T.exists(tr))
                blockFillCounters_T[tr] = DELAY;
        endfunction
    

    always @(posedge clk) begin
        handleBlockFills();
           // handleBlockFills_T();
        scheduleBlockFills();
           // scheduleBlockFills_T();
    end



    
//    /////////////////////////////////////
//    LogicA dataFillEnA, tlbFillEnA;
//    DwordA dataFillPhysA;
//    MwordA tlbFillVirtA;

//    always_comb dataFillEnA = dataFillEnables();
//    always_comb dataFillPhysA = dataFillPhysical();
//    always_comb tlbFillEnA = tlbFillEnables();
//    always_comb tlbFillVirtA = tlbFillVirtual();


//    ////////////////////////////////////
//        function automatic LogicA dataFillEnables();
//            LogicA res = '{default: 0};
//            foreach (reads[p]) begin
//                if (reads[p].status == CR_TAG_MISS) begin
//                    res[p] = 1;
//                end
//            end
//            return res;
//        endfunction

//        function automatic DwordA dataFillPhysical();
//            DwordA res = '{default: 'x};
//            foreach (reads[p]) begin
//                res[p] = getBlockBaseD(translations[p].padr);
//            end
//            return res;
//        endfunction
    
    
//        function automatic LogicA tlbFillEnables();
//            LogicA res = '{default: 0};
//            foreach (reads[p]) begin
//                if (reads[p].status == CR_TLB_MISS) begin
//                    res[p] = 1;
//                end
//            end
//            return res;
//        endfunction
    
//        function automatic MwordA tlbFillVirtual();
//            MwordA res = '{default: 'x};
//            foreach (reads[p]) begin
//                res[p] = getPageBaseM(translations[p].vadr);
                
//            end
//            return res;
//        endfunction



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
