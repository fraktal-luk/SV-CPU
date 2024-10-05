
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;

import Queues::*;


module StoreQueue
#(
    parameter logic IS_LOAD_QUEUE = 0,
    parameter logic IS_BRANCH_QUEUE = 0,
    
    parameter int SIZE = 32,
    
    type HELPER = QueueHelper
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


    typedef HELPER::Entry QEntry;
    localparam QEntry EMPTY_QENTRY = HELPER::EMPTY_QENTRY;


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
    
    assign size = (endPointer - drainPointer + 2*SIZE) % (2*SIZE);
    assign allow = (size < SIZE - 3*RENAME_WIDTH);

    QueueEntry content[SIZE] = '{default: EMPTY_ENTRY};
    QEntry content_N[SIZE] = '{default: EMPTY_QENTRY};


//    typedef enum {
//        NO_LOAD, NO_MATCH, SINGLE_EXACT, SINGLE_INEXACT, MULTIPLE
//    } MatchStatus;
    

    always @(posedge AbstractCore.clk) begin    
        advance();

          //  HELPER::TMP_scan(content_N);

        if (IS_STORE_QUEUE) handleForwardsS();
        if (IS_LOAD_QUEUE)  handleHazardsL();
    
        update();
    
        if (lateEventInfo.redirect)
            flushAll();
        else if (branchEventInfo.redirect)
            flushPartial(); 
        else
            writeInput(inGroup);
    end

    
    task automatic flushAll();
        foreach (content_N[i]) begin
            InsId thisId = content_N[i].id;        
            //if (content[i].committed) continue; 
            if (HELPER::isCommitted(content_N[i])) continue; 
            if (thisId != -1) putMilestone(thisId, QUEUE_FLUSH);            
            content[i] = EMPTY_ENTRY;
                content_N[i] = EMPTY_QENTRY;
        end
        endPointer = startPointer;
    endtask

    
    task automatic flushPartial();
        InsId causingId = branchEventInfo.op.id;
        int p = startPointer;
        
        endPointer = startPointer;
        for (int i = 0; i < SIZE; i++) begin
            InsId thisId = content_N[p % SIZE].id;        
            if (thisId > causingId) begin
                putMilestone(thisId, QUEUE_FLUSH);
                content[p % SIZE] = EMPTY_ENTRY;
                    content_N[p % SIZE] = EMPTY_QENTRY;
            end
            else if (thisId == -1) break;
            else endPointer = (p+1) % (2*SIZE);   
            p++;
        end
    endtask
    
    
    localparam logic SQ_RETAIN = 1;
    
    
    
    function automatic logic isCommittable(input InsId id);
        return id != -1 && id <= AbstractCore.theRob.lastOut;
    endfunction
    
    
    task automatic advance();
        int nOut = 0;
        outGroup <= '{default: EMPTY_SLOT};

        while (isCommittable(content_N[startPointer % SIZE].id))
        begin
            InsId thisId = content_N[startPointer % SIZE].id;
            outGroup[nOut].id <= thisId;
            outGroup[nOut].active <= 1;
            nOut++;
                
            putMilestone(thisId, QUEUE_EXIT);

            if (SQ_RETAIN && IS_STORE_QUEUE) begin
                content[startPointer % SIZE].committed = 1;
                HELPER::setCommitted(content_N[startPointer % SIZE]);
                startPointer = (startPointer+1) % (2*SIZE);
            end
            else begin
                content[startPointer % SIZE] = EMPTY_ENTRY;
                    content_N[startPointer % SIZE] = EMPTY_QENTRY;
                startPointer = (startPointer+1) % (2*SIZE);
            end
        end
        
        if (SQ_RETAIN && IS_STORE_QUEUE) begin
            if (AbstractCore.drainHead.op.active) begin
                //    assert (AbstractCore.drainHead.op.id == content[drainPointer % SIZE].id) else $error("Not matching id drain %d/%d", AbstractCore.drainHead.op.id, content[drainPointer % SIZE].id);
                assert (AbstractCore.drainHead.op.id == content_N[drainPointer % SIZE].id) else $error("Not matching n id drain %d/%d", AbstractCore.drainHead.op.id, content_N[drainPointer % SIZE].id);
            
                content[drainPointer % SIZE] = EMPTY_ENTRY;
                    content_N[drainPointer % SIZE] = EMPTY_QENTRY;
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

            applies = HELPER::applies(decId(wrInputs[p].id));
        
            if (!applies) continue;
            
            begin
               int found[$] = content.find_index with (item.id == wrInputs[p].id);
               if (found.size() == 1) updateEntry(found[0], wrInputs[p]);
               else $error("Sth wrong with Q update [%d], found(%d) %p // %p", wrInputs[p].id, found.size(), wrInputs[p], wrInputs[p], decId(wrInputs[p].id));
            end
        end 
    endtask


    task automatic writeInput(input OpSlotA inGroup);
        if (!anyActive(inGroup)) return;
    
        foreach (inGroup[i]) begin
            logic applies = HELPER::applies(decAbs(inGroup[i]));

            if (applies) begin
                content[endPointer % SIZE] = '{inGroup[i].id, 0, 0, 0, 'x, 'x};
                    content_N[endPointer % SIZE] = HELPER::newEntry(inGroup[i]);

                
                putMilestone(inGroup[i].id, QUEUE_ENTER);
                endPointer = (endPointer+1) % (2*SIZE);
            end
        end
    endtask

    
    task automatic updateEntry(input int index, input OpPacket p);
    
        if (IS_BRANCH_QUEUE) begin
            updateEntryB(index, p, branchEventInfo);
        end
        
        if (IS_STORE_QUEUE) begin
            updateEntryS(index, p, branchEventInfo);
        end
        
        if (IS_LOAD_QUEUE) begin
            updateEntryL(index, p, branchEventInfo);
        end
        
        HELPER::updateEntry(content_N[index], p, branchEventInfo);  
    endtask
    
        task automatic updateEntryB(input int index, input OpPacket p, input EventInfo brInfo);
            content[index].adr = brInfo.target;
            content[index].adrReady = 1;
        endtask

        task automatic updateEntryS(input int index, input OpPacket p, input EventInfo brInfo);
            content[index].adrReady = 1;
            content[index].adr = p.result;
        endtask
        
        task automatic updateEntryL(input int index, input OpPacket p, input EventInfo brInfo);
            content[index].adrReady = 1;
            content[index].adr = p.result;
        endtask
   

    task automatic handleForwardsS();
        foreach (theExecBlock.toLq[p]) begin
            logic active = theExecBlock.toLq[p].active;
            Word adr = theExecBlock.toLq[p].result;
            OpPacket resa, resb;

            //MatchStatus st;

            theExecBlock.fromSq[p] <= EMPTY_OP_PACKET;
            
            if (active !== 1) continue;
            if (!isLoadMemIns(decId(theExecBlock.toLq[p].id))) continue;
            
            resa = scanQueue_P(theExecBlock.toLq[p].id, adr);
            theExecBlock.fromSq[p] <= resa;
            
            resb = HELPER::scanQueue(content_N, theExecBlock.toLq[p].id, adr);
            
             assert (resa === resb) else $error("sq no match");
        end
    endtask
    

    task automatic handleHazardsL();
        foreach (theExecBlock.toSq[p]) begin
            logic active = theExecBlock.toSq[p].active;
            Word adr = theExecBlock.toSq[p].result;
            OpPacket resa, resb;
            
            //MatchStatus st;

            theExecBlock.fromLq[p] <= EMPTY_OP_PACKET;
            
            if (active !== 1) continue;
            if (!isStoreMemIns(decId(theExecBlock.toSq[p].id))) continue;
            
            resa = scanForHazards(theExecBlock.toLq[p].id, adr);
            resb = HELPER::scanQueue(content_N, theExecBlock.toLq[p].id, adr);
            
                assert (resa === resb) else $error("lq no match");
            
            theExecBlock.fromLq[p] <= resa;
            
        end
    endtask


    function automatic OpPacket scanQueue_P(input InsId id, input Word adr);
        typedef StoreQueueHelper::Entry SqEntry;
        // TODO: don't include sys stores in adr matching 
        QueueEntry found[$] = content.find with ( item.id != -1 && item.id < id && item.adrReady && wordOverlap(item.adr, adr));
        
            IntQueue found_N = //content_N.find with ( item.id != -1 && item.id < id && item.adrReady && wordOverlap(item.adr, adr));
                                 HELPER::TMP_scan(content_N, id, adr);
       
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


    function automatic OpPacket scanForHazards(input InsId id, input Word adr);
        // TODO: don't include sys stores in adr matching 
        int found[$] = content.find_index with ( item.id != -1 && item.id > id && item.adrReady && wordOverlap(item.adr, adr));
       
        if (found.size() == 0) return EMPTY_OP_PACKET;

        // else: we have a match and the matching loads are incorrect
        foreach (found[i]) begin
            content[found[i]].valReady = 'x;
               HELPER::setError(content_N[found[i]]);
        end
        
        begin // 'active' indicates that some match has happened without furthr details
            OpPacket res = EMPTY_OP_PACKET;
            res.active = 1;            
            return res;
        end

    endfunction
   
   

    
endmodule
