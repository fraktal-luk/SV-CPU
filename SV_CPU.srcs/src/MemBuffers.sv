
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;



module StoreQueue
#(
    parameter logic IS_LOAD_QUEUE = 0,
    parameter logic IS_BRANCH_QUEUE = 0,
    
    parameter int SIZE = 32
)
(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpSlotA inGroup,
    output OpSlotA outGroup
);

    localparam logic IS_STORE_QUEUE = !IS_LOAD_QUEUE && !IS_BRANCH_QUEUE;

    localparam InstructionMap::Milestone QUEUE_ENTER = IS_BRANCH_QUEUE ? InstructionMap::BqEnter : IS_LOAD_QUEUE ? InstructionMap::LqEnter : InstructionMap::SqEnter;
    localparam InstructionMap::Milestone QUEUE_FLUSH = IS_BRANCH_QUEUE ? InstructionMap::BqFlush : IS_LOAD_QUEUE ? InstructionMap::LqFlush : InstructionMap::SqFlush;
    localparam InstructionMap::Milestone QUEUE_EXIT = IS_BRANCH_QUEUE ? InstructionMap::BqExit : IS_LOAD_QUEUE ? InstructionMap::LqExit : InstructionMap::SqExit;


    typedef struct {
        InsId id;
    } QueueEntry;

    const QueueEntry EMPTY_ENTRY = '{-1};

    int startPointer = 0, endPointer = 0, drainPointer = 0;
    int size;
    logic allow;
    
    assign size = (endPointer - startPointer + 2*SIZE) % (2*SIZE);
    assign allow = (size < SIZE - 3*RENAME_WIDTH);

    QueueEntry content[SIZE] = '{default: EMPTY_ENTRY};
    
    
    task automatic flushAll();
        for (int i = 0; i < SIZE; i++)
            if (content[i].id != -1) putMilestone(content[i % SIZE].id, QUEUE_FLUSH);

        content = '{default: EMPTY_ENTRY};
        endPointer = startPointer;
    endtask

    
    task automatic flushPartial();
        InsId causingId = branchEventInfo.op.id;
        
        int p = startPointer;
        
        endPointer = startPointer;
        
        for (int i = 0; i < SIZE; i++) begin
            if (content[p % SIZE].id > causingId) begin
                    putMilestone(content[p % SIZE].id, QUEUE_FLUSH);
                content[p % SIZE] = EMPTY_ENTRY;
            end
            else if (content[p % SIZE].id == -1)
                break;
            else
                endPointer = (p+1) % (2*SIZE);   
            p++;
        end
    endtask
    
    
    task automatic advance();
            int nOut = 0;
            outGroup <= '{default: EMPTY_SLOT};
        while (content[startPointer % SIZE].id != -1 && content[startPointer % SIZE].id <= AbstractCore.theRob.lastOut) begin
                outGroup[nOut].id <= content[startPointer % SIZE].id;
                outGroup[nOut].active <= 1;
                nOut++;
                
            putMilestone(content[startPointer % SIZE].id, QUEUE_EXIT);
            content[startPointer % SIZE] = EMPTY_ENTRY;
            startPointer = (startPointer+1) % (2*SIZE);
        end
    endtask

    task automatic writeInput(input OpSlotA inGroup);
        if (!anyActive(inGroup)) return;
    
        foreach (inGroup[i]) begin
            automatic logic applies = 
                              IS_LOAD_QUEUE && isLoadIns(decAbs(inGroup[i]))
                          ||  IS_BRANCH_QUEUE && isBranchIns(decAbs(inGroup[i]))
                          ||  IS_STORE_QUEUE && isStoreIns(decAbs(inGroup[i]));
        
            if (applies) begin
                content[endPointer % SIZE].id = inGroup[i].id;
                    putMilestone(inGroup[i].id, QUEUE_ENTER);
                endPointer = (endPointer+1) % (2*SIZE);
            end
        end
    endtask

    
    always @(posedge AbstractCore.clk) begin
        advance();
    
        if (lateEventInfo.redirect)
            flushAll();
        else if (branchEventInfo.redirect)
           flushPartial(); 
        else
            writeInput(inGroup);
    end


endmodule


