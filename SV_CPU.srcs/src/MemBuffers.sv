
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;


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
    output OpSlotA outGroup,
    
    input OpPacket wrInputs[N_MEM_PORTS]
);

    localparam logic IS_STORE_QUEUE = !IS_LOAD_QUEUE && !IS_BRANCH_QUEUE;

    localparam InstructionMap::Milestone QUEUE_ENTER = IS_BRANCH_QUEUE ? InstructionMap::BqEnter : IS_LOAD_QUEUE ? InstructionMap::LqEnter : InstructionMap::SqEnter;
    localparam InstructionMap::Milestone QUEUE_FLUSH = IS_BRANCH_QUEUE ? InstructionMap::BqFlush : IS_LOAD_QUEUE ? InstructionMap::LqFlush : InstructionMap::SqFlush;
    localparam InstructionMap::Milestone QUEUE_EXIT = IS_BRANCH_QUEUE ? InstructionMap::BqExit : IS_LOAD_QUEUE ? InstructionMap::LqExit : InstructionMap::SqExit;


    typedef struct {
        InsId id;
        
        logic committed;
        
        logic adrReady;
        logic valReady;
        Mword adr;
        Mword val;
    } QueueEntry;

    const QueueEntry EMPTY_ENTRY = '{-1, 0, 0, 0, 'x, 'x};

    int startPointer = 0, endPointer = 0, drainPointer = 0;
    
    int size;
    logic allow;
    
    assign size = //(endPointer - startPointer + 2*SIZE) % (2*SIZE);
                  (endPointer - drainPointer + 2*SIZE) % (2*SIZE);
    assign allow = (size < SIZE - 3*RENAME_WIDTH);

    QueueEntry content[SIZE] = '{default: EMPTY_ENTRY};


    typedef enum {
        NO_LOAD, NO_MATCH, SINGLE_EXACT, SINGLE_INEXACT, MULTIPLE
    } MatchStatus;
    

    always @(posedge AbstractCore.clk) begin
        advance();

        if (IS_STORE_QUEUE) handleForwards();
    
        update();
    
        if (lateEventInfo.redirect)
           flushAll();
        else if (branchEventInfo.redirect)
           flushPartial(); 
        else
            writeInput(inGroup);
    end

    
    task automatic flushAll();
        foreach (content[i]) begin
            //if (content[i].committed) continue; 
            
            if (content[i].id != -1) putMilestone(content[i].id, QUEUE_FLUSH);
            
            //if (lateEventInfo.reset || lateEventInfo.interrupt || lateEventInfo.op.id < content[i].id)
            content[i] = EMPTY_ENTRY;
        end
//        for (int i = 0; i < SIZE; i++)
//            if (content[i].id != -1) putMilestone(content[i % SIZE].id, QUEUE_FLUSH);

//        content = '{default: EMPTY_ENTRY};
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
            else if (content[p % SIZE].id == -1) break;
            else endPointer = (p+1) % (2*SIZE);   
            p++;
        end
    endtask
    
    
    localparam logic SQ_RETAIN = 0;
    
    
    task automatic advance();
        int nOut = 0;
        outGroup <= '{default: EMPTY_SLOT};
        while (content[startPointer % SIZE].id != -1
            && content[startPointer % SIZE].id <= //AbstractCore.committedState.last
                                                  AbstractCore.theRob.lastOut_N
               )
        begin
            InsId thisId = content[startPointer % SIZE].id;
            outGroup[nOut].id <= content[startPointer % SIZE].id;
            outGroup[nOut].active <= 1;
            nOut++;
                
            putMilestone(content[startPointer % SIZE].id, QUEUE_EXIT);

            if (SQ_RETAIN && IS_STORE_QUEUE) begin
                //if (lateEventInfo.op.active && lateEventInfo.op.id) begin end
                content[startPointer % SIZE].committed = 1;
            end
            else content[startPointer % SIZE] = EMPTY_ENTRY;

            startPointer = (startPointer+1) % (2*SIZE);
        end
        
        if (SQ_RETAIN && IS_STORE_QUEUE) begin
            if (AbstractCore.drainHead.op.active) begin
                    assert (AbstractCore.drainHead.op.id == content[drainPointer % SIZE].id) else $error("Not matching id drain %d/%d", AbstractCore.drainHead.op.id, content[drainPointer % SIZE].id);
            
                content[drainPointer % SIZE] = EMPTY_ENTRY;
                drainPointer = (drainPointer+1) % (2*SIZE);
            end
        end
        else begin
            drainPointer = startPointer;
        end
    endtask


    task automatic update();
        foreach (wrInputs[p]) begin
            logic applies;
            if (wrInputs[p].active !== 1) continue;
            applies =
                  IS_LOAD_QUEUE && isLoadIns(decId(wrInputs[p].id))
              ||  IS_BRANCH_QUEUE && isBranchIns(decId(wrInputs[p].id))
              ||  IS_STORE_QUEUE && isStoreIns(decId(wrInputs[p].id));
        
            if (!applies) continue;
            
            begin
               int found[$] = content.find_index with (item.id == wrInputs[p].id);
               if (found.size() == 1) updateEntry(found[0], wrInputs[p]);
               else $error("Sth wrong with SQ update [%d], found(%d) %p // %p", wrInputs[p].id, found.size(), wrInputs[p], wrInputs[p], decId(wrInputs[p].id));
            end
        end 
    endtask


    task automatic writeInput(input OpSlotA inGroup);
        if (!anyActive(inGroup)) return;
    
        foreach (inGroup[i]) begin
            logic applies = 
                  IS_LOAD_QUEUE && isLoadIns(decAbs(inGroup[i]))
              ||  IS_BRANCH_QUEUE && isBranchIns(decAbs(inGroup[i]))
              ||  IS_STORE_QUEUE && isStoreIns(decAbs(inGroup[i]));

            if (applies) begin
                content[endPointer % SIZE] = '{inGroup[i].id, 0, 0, 0, 'x, 'x};
                putMilestone(inGroup[i].id, QUEUE_ENTER);
                endPointer = (endPointer+1) % (2*SIZE);
            end
        end
    endtask

    
    task automatic updateEntry(input int index, input OpPacket p);
        if (IS_BRANCH_QUEUE) begin
        
        end
        
        if (IS_STORE_QUEUE) begin
            content[index].adrReady = 1;
            content[index].adr = p.result;
        end
        
        if (IS_LOAD_QUEUE) begin
            content[index].adrReady = 1;
            content[index].adr = p.result;
        end       
    endtask
    
    
    task automatic handleForwards();
        foreach (theExecBlock.toLq[p]) begin
            logic active = theExecBlock.toLq[p].active;
            Word adr = theExecBlock.toLq[p].result;
            MatchStatus st;

            theExecBlock.fromSq[p] <= EMPTY_OP_PACKET;
            
            if (active !== 1) continue;
            if (!isLoadMemIns(decId(theExecBlock.toLq[p].id))) continue;
            
            theExecBlock.fromSq[p] <= scanQueue_P(theExecBlock.toLq[p].id, adr);
        end
    endtask
    
    
    function automatic OpPacket scanQueue_P(input InsId id, input Word adr);
        // TODO: don't include sys stores in adr matching 
        QueueEntry found[$] = content.find with ( item.id != -1 && item.id < id && item.adrReady && wordOverlap(item.adr, adr));
       
        if (found.size() == 0) return EMPTY_OP_PACKET;
        else if (found.size() == 1) begin        
            if (wordInside(adr, found[0].adr)) return '{1, found[0].id, ES_OK, EMPTY_POISON, 'x, found[0].val};
            else return '{1, found[0].id, ES_INVALID, EMPTY_POISON, 'x, 'x};
        end
        else begin
            QueueEntry sorted[$] = found[0:$];
            sorted.sort with (item.id);
            
            if (wordInside(adr, sorted[$].adr)) return '{1, sorted[$].id, ES_OK, EMPTY_POISON, 'x, sorted[$].val};
            return '{1, sorted[$].id, ES_INVALID, EMPTY_POISON, 'x, 'x};
        end

    endfunction
    
    
endmodule


