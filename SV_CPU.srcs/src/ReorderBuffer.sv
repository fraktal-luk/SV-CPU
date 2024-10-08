
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;


module ReorderBuffer
#(
    parameter int WIDTH = 4
)
(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpSlotA inGroup,
    output OpSlotA outGroup
);

    localparam int DEPTH = ROB_SIZE/WIDTH;

    int startPointer = 0, endPointer = 0;
    int size;
    logic allow;

    typedef struct {
        InsId id;
        logic completed;
    } OpRecord;
    
    const OpRecord EMPTY_RECORD = '{id: -1, completed: 'x};
    typedef OpRecord OpRecordA[WIDTH];

    typedef struct {
        OpRecord records[WIDTH];
    } Row;


    OpSlotA outGroupPrev = '{default: EMPTY_SLOT};

    OpRecord commitQ[$:3*WIDTH];
    OpRecord commitQM[3*WIDTH] = '{default: EMPTY_RECORD}; 

    typedef OpRecord QM[3*WIDTH];


    const Row EMPTY_ROW = '{records: '{default: EMPTY_RECORD}};

    function automatic OpSlotA makeOutGroup(input Row row);
        OpSlotA res = '{default: EMPTY_SLOT};
        foreach (row.records[i]) begin
            if (row.records[i].id == -1) continue;
            res[i].active = 1;
            res[i].id = row.records[i].id;
        end
        
        return res;
    endfunction
    

    Row arrayHeadRow = EMPTY_ROW, outRow = EMPTY_ROW;
    Row array[DEPTH] = '{default: EMPTY_ROW};
    
    InsId lastIn = -1, lastOut = -1;
    logic lastIsBreaking = 0;
    
    logic commitStalled = 0;
    

    assign size = (endPointer - startPointer + 2*DEPTH) % (2*DEPTH);
    assign allow = (size < DEPTH - 3);
        
    assign outGroup = makeOutGroup(outRow);

    
    always @(posedge AbstractCore.clk) begin
        automatic Row outRowVar;

            outGroupPrev <= outGroup;

        if (AbstractCore.interrupt || AbstractCore.reset || lateEventInfo.redirect
            || AbstractCore.lateEventInfoWaiting.interrupt || AbstractCore.lateEventInfoWaiting.reset || AbstractCore.lateEventInfoWaiting.redirect
            || lastIsBreaking
            )
            arrayHeadRow <= EMPTY_ROW;
        else if (frontCompleted() && commitQ.size() <= 3*WIDTH - 2*WIDTH)
            arrayHeadRow <= readOutRow();
        else
            arrayHeadRow <= EMPTY_ROW;

        outRowVar = takeFromQueue(commitQ, commitStalled);
        outRow <= outRowVar;

        lastOut <= getLastOut(lastOut, outRowVar.records);
        lastIsBreaking <= isLastBreaking(lastOut, outRowVar.records);

        insertToQueue(commitQ, tickRow(arrayHeadRow)); // must be after reading from queue!

        markCompleted();

        if (lateEventInfo.redirect)
            flushArrayAll();
        else if (branchEventInfo.redirect)
            flushArrayPartial();
        else if (anyActive(inGroup))
            add(inGroup);

        commitQM <= makeQM(commitQ);
    end


    function automatic QM makeQM(input OpRecord q[$:3*WIDTH]);
        QM res = '{default: EMPTY_RECORD};
        foreach (q[i]) res[i] = q[i];
        return res;
    endfunction

    function automatic OpRecord tickRecord(input OpRecord rec);
        if (AbstractCore.interrupt || AbstractCore.reset || lateEventInfo.redirect
            || AbstractCore.lateEventInfoWaiting.interrupt || AbstractCore.lateEventInfoWaiting.reset || AbstractCore.lateEventInfoWaiting.redirect
            || lastIsBreaking
            )
        begin
            if (rec.id != -1)
                putMilestone(rec.id, InstructionMap::FlushCommit);
            return EMPTY_RECORD;
        end
        else
            return rec;
    endfunction

    function automatic Row tickRow(input Row row);
        Row res;

        foreach (res.records[i])
            res.records[i] = tickRecord(row.records[i]);
            
        return res;
    endfunction

    function automatic void insertToQueue(ref OpRecord q[$:3*WIDTH], input Row row);
        foreach (row.records[i])
            if (row.records[i].id != -1) begin
                assert (row.records[i].completed === 1) else $fatal(2, "not compl");
                q.push_back(row.records[i]);
            end 
    endfunction

    function automatic Row takeFromQueue(ref OpRecord q[$:3*WIDTH], input logic stall);
        Row res = EMPTY_ROW;
        
        if (AbstractCore.interrupt || AbstractCore.reset || lateEventInfo.redirect
            || AbstractCore.lateEventInfoWaiting.interrupt || AbstractCore.lateEventInfoWaiting.reset || AbstractCore.lateEventInfoWaiting.redirect
            || lastIsBreaking
            ) begin
            foreach (q[i])
                if (q[i].id != -1) putMilestone(q[i].id, InstructionMap::FlushCommit);
            q = '{};
        end
        
        if (stall) return res; // Not removing from queue
        
        foreach (res.records[i]) begin
            if (q.size() == 0) break;
            res.records[i] = q.pop_front();
            if (breaksCommitId(res.records[i].id)) break;
        end
        
        return res;
    endfunction


    task automatic flushArrayAll();        
        foreach (array[r]) begin
            OpRecord row[WIDTH] = array[r].records;
            foreach (row[c])
                putMilestone(row[c].id, InstructionMap::RobFlush);
        end

        endPointer = startPointer;
        array = '{default: EMPTY_ROW};
    endtask
    
    
    task automatic flushArrayPartial();
        logic clear = 0;
        int causingGroup = insMap.get(branchEventInfo.op.id).inds.renameG;
        int causingSlot = insMap.get(branchEventInfo.op.id).slot;
        InsId causingId = branchEventInfo.op.id;
        int p = startPointer;
                    
        for (int i = 0; i < DEPTH; i++) begin
            OpRecord row[WIDTH] = array[p % DEPTH].records;
            for (int c = 0; c < WIDTH; c++) begin
                if (row[c].id == causingId) endPointer = (p+1) % (2*DEPTH);
                if (row[c].id > causingId) begin
                    putMilestone(row[c].id, InstructionMap::RobFlush);
                    array[p % DEPTH].records[c] = EMPTY_RECORD;
                end
            end
            p++;
        end
    endtask
    
    
    task automatic markPacketCompleted(input OpPacket p);         
        if (!p.active) return;
        
        for (int r = 0; r < DEPTH; r++)
            for (int c = 0; c < WIDTH; c++)
                if (array[r].records[c].id == p.id) begin
                    array[r].records[c].completed = 1;
                    putMilestone(p.id, InstructionMap::RobComplete);
                end
    endtask
    

    task automatic markCompleted();        
        markPacketCompleted(theExecBlock.doneRegular0_E);
        markPacketCompleted(theExecBlock.doneRegular1_E);
    
        markPacketCompleted(theExecBlock.doneFloat0_E);
        markPacketCompleted(theExecBlock.doneFloat1_E);
    
        markPacketCompleted(theExecBlock.doneBranch_E);
        markPacketCompleted(theExecBlock.doneMem0_E);
        markPacketCompleted(theExecBlock.doneMem2_E);
        markPacketCompleted(theExecBlock.doneSys_E);
    endtask


    function automatic Row readOutRow();
        Row row = array[startPointer % DEPTH];
        
        foreach (row.records[i])
            if (row.records[i].id != -1) putMilestone(row.records[i].id, InstructionMap::RobExit);

        array[startPointer % DEPTH] = EMPTY_ROW;
        startPointer = (startPointer+1) % (2*DEPTH);
        
        return row;
    endfunction
    

    function automatic OpRecordA makeRecord(input OpSlotA ops);
        OpRecordA res = '{default: EMPTY_RECORD};
        foreach (ops[i])
            res[i] = ops[i].active ? '{ops[i].id, 0} : '{-1, 'x};   
        return res;
    endfunction


    task automatic add(input OpSlotA in);
        OpRecordA rec = makeRecord(in);
            
        array[endPointer % DEPTH].records = makeRecord(in);
        endPointer = (endPointer+1) % (2*DEPTH);
        
        foreach (rec[i])
            putMilestone(rec[i].id, InstructionMap::RobEnter);
    endtask
    
    function automatic logic frontCompleted();
        OpRecordA records = array[startPointer % DEPTH].records;
        if (endPointer == startPointer) return 0;

        foreach (records[i])
            if (records[i].id != -1 && records[i].completed === 0)
                return 0;
        
        return 1;
    endfunction
    
    
    function automatic InsId getLastOut(input InsId prev, input OpRecordA recs);
        InsId tmp = prev;
        
        foreach (recs[i])
            if  (recs[i].id != -1)
                tmp = recs[i].id;
                
        return tmp;
    endfunction

    function automatic logic isLastBreaking(input InsId prev, input OpRecordA recs);
        logic brk = 0;
        
        foreach (recs[i])
            if  (recs[i].id != -1)
                brk = breaksCommitId(recs[i].id);
                
        return brk;
    endfunction

endmodule
