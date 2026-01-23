
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import EmulationDefs::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;



module UncachedDataUnit(
    input logic clk,
    input MemWriteInfo TMP_writeReqs[2]
);


    class PageWriter#(type Elem = Mbyte, int ESIZE = 1, int BASE = 0);
        static
        function automatic void writeTyped(ref Mbyte arr[PAGE_SIZE], input Mword adr, input Elem val);
            Mbyte wval[ESIZE] = {>>{val}};
            arr[(adr - BASE) +: ESIZE] = wval;
        endfunction

        static
        function automatic Elem readTyped(ref Mbyte arr[PAGE_SIZE], input Mword adr);                
            Mbyte chosen[ESIZE] = arr[(adr - BASE) +: ESIZE];
            Elem wval = {>>{chosen}};
            return wval;
        endfunction
    endclass


    typedef struct {
        logic ready = 0;
        logic ongoing = 0;
        Mword adr = 'x;
        AccessSize size = SIZE_NONE;
        int counter = -1;
    } UncachedRead;


    DataCacheOutput uncachedResults[N_MEM_PORTS] = '{default: EMPTY_DATA_CACHE_OUTPUT};


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
        
            uncachedReads = '{default: '{0, 0, 'x, SIZE_NONE, -1}};

            uncachedResults = '{default: EMPTY_DATA_CACHE_OUTPUT};

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

        handleReadsUnc();
    end



    task automatic handleReadsUnc();
        foreach (theExecBlock.accessDescs_E0[p]) begin
            handleSingleReadUnc(p);
        end
    endtask

    task automatic handleSingleReadUnc(input int p);
        AccessDesc aDesc = theExecBlock.accessDescs_E0[p];

        uncachedResults[p] <= EMPTY_DATA_CACHE_OUTPUT;

        if (!aDesc.active || $isunknown(aDesc.vadr)) return;
        else begin
            uncachedResults[p] <= doReadAccessUnc(aDesc);
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
            if (readResult.status == CR_HIT)
                res = '{1, CR_HIT, 'x, readResult.data};
            else if (readResult.status == CR_INVALID)
                res = '{1, CR_INVALID, 'x, 0};
            else $error("Wrong status returned by uncached");
        end
        else if (aDesc.uncachedStore) begin
            res = '{1, CR_HIT, 'x, 'x};
        end

        return res;
    endfunction






endmodule
