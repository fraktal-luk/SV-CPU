
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
    input OpSlotAB inGroup,
    output OpSlotAB outGroup,
    
    input UopPacket wrInputs[N_MEM_PORTS]
);

    localparam logic IS_STORE_QUEUE = !IS_LOAD_QUEUE && !IS_BRANCH_QUEUE;

    localparam InstructionMap::Milestone QUEUE_ENTER = IS_BRANCH_QUEUE ? InstructionMap::BqEnter : IS_LOAD_QUEUE ? InstructionMap::LqEnter : InstructionMap::SqEnter;
    localparam InstructionMap::Milestone QUEUE_FLUSH = IS_BRANCH_QUEUE ? InstructionMap::BqFlush : IS_LOAD_QUEUE ? InstructionMap::LqFlush : InstructionMap::SqFlush;
    localparam InstructionMap::Milestone QUEUE_EXIT = IS_BRANCH_QUEUE ? InstructionMap::BqExit : IS_LOAD_QUEUE ? InstructionMap::LqExit : InstructionMap::SqExit;


    typedef HELPER::Entry QEntry;
    localparam QEntry EMPTY_QENTRY = HELPER::EMPTY_QENTRY;

    int startPointer = 0, endPointer = 0, drainPointer = 0;
    
    int size;
    logic allow;
    
    assign size = (endPointer - drainPointer + 2*SIZE) % (2*SIZE);
    assign allow = (size < SIZE - 3*RENAME_WIDTH);

    QEntry content_N[SIZE] = '{default: EMPTY_QENTRY};


    always @(posedge AbstractCore.clk) begin    
        advance();

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
            InsId thisId = content_N[i].mid;        
            if (HELPER::isCommitted(content_N[i])) continue; 
            if (thisId != -1) putMilestoneM(thisId, QUEUE_FLUSH);            
            content_N[i] = EMPTY_QENTRY;
        end
        endPointer = startPointer;
    endtask

    
    task automatic flushPartial();
        InsId causingMid = branchEventInfo.eventMid;
        int p = startPointer;
        
        endPointer = startPointer;
        for (int i = 0; i < SIZE; i++) begin
            InsId thisId = content_N[p % SIZE].mid;        
            if (thisId > causingMid) begin
                putMilestoneM(thisId, QUEUE_FLUSH);
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
        outGroup <= '{default: EMPTY_SLOT_B};

        while (isCommittable(content_N[startPointer % SIZE].mid))
        begin
            InsId thisId = content_N[startPointer % SIZE].mid;
            outGroup[nOut].TMP_mid <= thisId;
            outGroup[nOut].active <= 1;
            nOut++;
                
            putMilestoneM(thisId, QUEUE_EXIT);

            if (SQ_RETAIN && IS_STORE_QUEUE) begin
                HELPER::setCommitted(content_N[startPointer % SIZE]);
                startPointer = (startPointer+1) % (2*SIZE);
            end
            else begin
                content_N[startPointer % SIZE] = EMPTY_QENTRY;
                startPointer = (startPointer+1) % (2*SIZE);
            end
        end
        
        if (SQ_RETAIN && IS_STORE_QUEUE) begin
            if (AbstractCore.drainHead.active) begin
                assert (AbstractCore.drainHead.mid == content_N[drainPointer % SIZE].mid) else $error("Not matching n id drain %d/%d", AbstractCore.drainHead.mid, content_N[drainPointer % SIZE].mid);            
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
            if (wrInputs[p].active !== 1) continue;
            if (!HELPER::applies(decId(wrInputs[p].TMP_oid))) continue;
            
            begin
               int found[$] = content_N.find_index with (item.mid == wrInputs[p].TMP_oid);
               if (found.size() == 1) HELPER::updateEntry(insMap, content_N[found[0]], wrInputs[p], branchEventInfo);
               else $error("Sth wrong with Q update [%d], found(%d) %p // %p", wrInputs[p].TMP_oid, found.size(), wrInputs[p], wrInputs[p], decId(wrInputs[p].TMP_oid));
            end
        end 
    endtask


    task automatic writeInput(input OpSlotAB inGroup);
        if (!anyActiveB(inGroup)) return;
    
        foreach (inGroup[i]) begin
            if (HELPER::applies(decId(inGroup[i].TMP_mid))) begin
                content_N[endPointer % SIZE] = HELPER::newEntry(insMap, inGroup[i].TMP_mid);                
                putMilestoneM(inGroup[i].TMP_mid, QUEUE_ENTER);
                endPointer = (endPointer+1) % (2*SIZE);
            end
        end
    endtask


    task automatic handleForwardsS();
        foreach (theExecBlock.toLq[p]) begin
            logic active = theExecBlock.toLq[p].active;
            Mword adr = theExecBlock.toLq[p].result;
            UopPacket resb;

            theExecBlock.fromSq[p] <= EMPTY_UOP_PACKET;
            
            if (active !== 1) continue;
            if (!isLoadMemIns(decId(theExecBlock.toLq[p].TMP_oid))) continue;
                        
            resb = HELPER::scanQueue(content_N, theExecBlock.toLq[p].TMP_oid, adr);
            theExecBlock.fromSq[p] <= resb;
        end
    endtask
    

    task automatic handleHazardsL();
        foreach (theExecBlock.toSq[p]) begin
            logic active = theExecBlock.toSq[p].active;
            Mword adr = theExecBlock.toSq[p].result;
            UopPacket resb;
            
            theExecBlock.fromLq[p] <= EMPTY_UOP_PACKET;
            
            if (active !== 1) continue;
            if (!isStoreMemIns(decId(theExecBlock.toSq[p].TMP_oid))) continue;
            
            resb = HELPER::scanQueue(content_N, theExecBlock.toLq[p].TMP_oid, adr);
            theExecBlock.fromLq[p] <= resb;      
        end
    endtask

    
endmodule
