
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
module DataFillEngine#(type Key = Dword, parameter int DELAY = 14)
(
    input logic clk,
    
    input Translation translations[N_MEM_PORTS],
        input logic enable[N_MEM_PORTS],
        input Key dataIn[N_MEM_PORTS]
);
    // Fill logic
    logic notifyFill = 0;
    Key notifiedAdr = 'x;

    int     blockFillCounters[Key]; // Container for request in progress
    Key     readyBlocksToFill[$]; // Queue of request ready for immediate completion 


    task automatic resetBlockFills();
        blockFillCounters.delete();
        readyBlocksToFill.delete();
        notifyFill <= 0;
        notifiedAdr <= 'x;
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
    Mword uncachedOutput = 'x;

    localparam Mword UNCACHED_BASE = 'h80000000;
    Mbyte uncachedArea[PAGE_SIZE];


    task automatic UNC_reset();
        uncachedCounter = -1;
        uncachedBusy = 0;
        uncachedOutput = 'x;
        
        uncachedArea = '{default: 0};
    endtask


    function automatic void UNC_scheduleUncachedRead(input AccessInfo aInfo);
        uncachedReads[0].ongoing = 1;
        uncachedReads[0].counter = 8;
        uncachedReads[0].adr = aInfo.adr;
        uncachedReads[0].size = aInfo.size;
    endfunction
    
    function automatic void UNC_clearUncachedRead();
        uncachedReads[0].ready = 0;
        uncachedReads[0].adr = 'x;
        uncachedOutput <= 'x;
    endfunction


    function automatic Mword readFromUncachedRange(input Mword adr, input AccessSize size);
        if (size == SIZE_1) return readByteUncached(adr);
        else if (size == SIZE_4) return readWordUncached(adr);
        else $error("Wrong access size");

        return 'x;
    endfunction
    
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
    
        task automatic UNC_write(input MemWriteInfo wrInfo);
            Mword adr = wrInfo.adr;
            Dword padr = wrInfo.padr;
            Mword val = wrInfo.value;
            
            uncachedCounter = 15;
            uncachedBusy = 1;
            if (wrInfo.size == SIZE_1) writeToUncachedRangeB(adr, val);
            if (wrInfo.size == SIZE_4) writeToUncachedRangeW(adr, val);
        endtask
    

        // uncached read pipe
        task automatic UNC_handleUncachedData();
            if (uncachedCounter == 0) uncachedBusy = 0;
            if (uncachedCounter >= 0) uncachedCounter--;
            
            if (uncachedReads[0].ongoing) begin
                if (--uncachedReads[0].counter == 0) begin
                    uncachedReads[0].ongoing = 0;
                    uncachedReads[0].ready = 1;
                    uncachedOutput <= readFromUncachedRange(uncachedReads[0].adr, uncachedReads[0].size);
                end
            end

            foreach (theExecBlock.accessDescs[p]) begin
                AccessDesc aDesc = theExecBlock.accessDescs[p];
                Mword vadr = aDesc.vadr;
                if (!aDesc.active || $isunknown(vadr)) continue;
                else begin
                    AccessInfo acc = analyzeAccess(vadr, aDesc.size);
                    if (theExecBlock.accessDescs[p].uncachedReq) UNC_scheduleUncachedRead(acc); // request for uncached read
                    else if (theExecBlock.accessDescs[p].uncachedCollect) UNC_clearUncachedRead();
                end
            end
        endtask


    always @(posedge clk) begin
        UNC_handleUncachedData();        

        if (TMP_writeReqs[0].req && TMP_writeReqs[0].uncached) begin
            UNC_write(TMP_writeReqs[0]);
        end
    end

endmodule
