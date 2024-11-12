
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
    input OpSlotAB inGroup,
    output OpSlotAB outGroup
);

    localparam int DEPTH = ROB_SIZE/WIDTH;

    int startPointer = 0, endPointer = 0;
    int size;
    logic allow;

    localparam int N_UOP_MAX = 2; // TODO: Number of uops a Mop can be split into
    typedef logic CompletedVec[N_UOP_MAX];

    typedef struct {
        InsId mid;
        CompletedVec completed;
    } OpRecord;
    
    const OpRecord EMPTY_RECORD = '{mid: -1, completed: '{default: 'x}};
    typedef OpRecord OpRecordA[WIDTH];

    typedef struct {
        OpRecord records[WIDTH];
    } Row;


    OpSlotAB outGroupPrev = '{default: EMPTY_SLOT_B};

    OpRecord commitQ[$:3*WIDTH];
    OpRecord commitQM[3*WIDTH] = '{default: EMPTY_RECORD}; 

    typedef OpRecord QM[3*WIDTH];


    const Row EMPTY_ROW = '{records: '{default: EMPTY_RECORD}};

    function automatic OpSlotAB makeOutGroup(input Row row);
        OpSlotAB res = '{default: EMPTY_SLOT_B};
        foreach (row.records[i]) begin
            if (row.records[i].mid == -1) continue;
            res[i].active = 1;
            res[i].mid = row.records[i].mid;
        end
        
        return res;
    endfunction
    

    Row arrayHeadRow = EMPTY_ROW, outRow = EMPTY_ROW;
    Row array[DEPTH] = '{default: EMPTY_ROW};
    
    InsId lastOut = -1;
    logic lastIsBreaking = 0;
    logic commitStalled = 0;
    

    assign size = (endPointer - startPointer + 2*DEPTH) % (2*DEPTH);
    assign allow = (size < DEPTH - 3);
        
    assign outGroup = makeOutGroup(outRow);

    
    always @(posedge AbstractCore.clk) begin
        automatic Row outRowVar;

            outGroupPrev <= outGroup;

        if (AbstractCore.interrupt || AbstractCore.reset || lateEventInfo.redirect
            || AbstractCore.lateEventInfoWaiting.active
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
        lastIsBreaking <= isLastBreaking(outRowVar.records);

        insertToQueue(commitQ, tickRow(arrayHeadRow)); // must be after reading from queue!

        markCompleted();

        if (lateEventInfo.redirect)
            flushArrayAll();
        else if (branchEventInfo.redirect)
            flushArrayPartial();
        else if (anyActiveB(inGroup))
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
            || AbstractCore.lateEventInfoWaiting.active
            || lastIsBreaking
            )
        begin
            if (rec.mid != -1)
                putMilestoneM(rec.mid, InstructionMap::FlushCommit);
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
            if (row.records[i].mid != -1) begin
                assert (row.records[i].completed.and() !== 0) else $fatal(2, "not compl"); // Will be 0 if any 0 is there
                q.push_back(row.records[i]);
            end 
    endfunction

    function automatic Row takeFromQueue(ref OpRecord q[$:3*WIDTH], input logic stall);
        Row res = EMPTY_ROW;
        
        if (AbstractCore.interrupt || AbstractCore.reset || lateEventInfo.redirect
            || AbstractCore.lateEventInfoWaiting.active
            || lastIsBreaking
            ) begin
            foreach (q[i])
                if (q[i].mid != -1) putMilestoneM(q[i].mid, InstructionMap::FlushCommit);
            q = '{};
        end
        
        if (stall) return res; // Not removing from queue
        
        foreach (res.records[i]) begin
            if (q.size() == 0) break;
            res.records[i] = q.pop_front();
            if (breaksCommitId(res.records[i].mid)) break;
        end
        
        return res;
    endfunction


    task automatic flushArrayAll();        
        foreach (array[r]) begin
            OpRecord row[WIDTH] = array[r].records;
            foreach (row[c])
                putMilestoneM(row[c].mid, InstructionMap::RobFlush);
        end

        endPointer = startPointer;
        array = '{default: EMPTY_ROW};
    endtask
    
    
    task automatic flushArrayPartial();
        logic clear = 0;
        InsId causingMid = branchEventInfo.eventMid;
        int p = startPointer;
                    
        for (int i = 0; i < DEPTH; i++) begin
            OpRecord row[WIDTH] = array[p % DEPTH].records;
            for (int c = 0; c < WIDTH; c++) begin
                if (row[c].mid == causingMid) endPointer = (p+1) % (2*DEPTH);
                if (row[c].mid > causingMid) begin
                    putMilestoneM(row[c].mid, InstructionMap::RobFlush);
                    array[p % DEPTH].records[c] = EMPTY_RECORD;
                end
            end
            p++;
        end
    endtask
    
    
    task automatic markPacketCompleted(input UopPacket p);         
        if (!p.active) return;
        
            // TODO: take into account that number of uops may differ
        
        for (int r = 0; r < DEPTH; r++)
            for (int c = 0; c < WIDTH; c++)
                if (array[r].records[c].mid == U2M(p.TMP_oid)) begin
                    array[r].records[c].completed[SUBOP(p.TMP_oid)] = 1;
                    if (array[r].records[c].completed.and() !== 0) putMilestoneM(U2M(p.TMP_oid), InstructionMap::RobComplete);
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
            if (row.records[i].mid != -1) putMilestoneM(row.records[i].mid, InstructionMap::RobExit);

        array[startPointer % DEPTH] = EMPTY_ROW;
        startPointer = (startPointer+1) % (2*DEPTH);
        
        return row;
    endfunction
    

    function automatic CompletedVec initCompletedVec(input int n);
        CompletedVec res = '{default: 'x};
        for (int i = 0; i < n; i++)
            res[i] = 0;
        return res;
    endfunction


    function automatic OpRecordA makeRecord(input OpSlotAB ops);
        OpRecordA res = '{default: EMPTY_RECORD};
        foreach (ops[i]) begin
            if (ops[i].active) begin
            
                int nUops = insMap.get(ops[i].mid).nUops;
                
                CompletedVec initialCompleted = //'{default: 0};
                                                initCompletedVec(nUops);
                
                res[i] = '{ops[i].mid, initialCompleted};
            end
            else
                res[i] = '{-1, '{default: 'x}};
        
//            // TODO: 'completed' must have number of 0's equal to nUops
//            int nUops = insMap.get(ops[i].mid).nUops;
            
//            CompletedVec initialCompleted = //'{default: 0};
//                                            initCompletedVec(nUops);
            
//            res[i] = ops[i].active ? '{ops[i].mid, initialCompleted} : '{-1, '{default: 'x}};
        end
        return res;
    endfunction


    task automatic add(input OpSlotAB in);
        OpRecordA rec = makeRecord(in);
            
        array[endPointer % DEPTH].records = makeRecord(in);
        endPointer = (endPointer+1) % (2*DEPTH);
        
        foreach (rec[i]) begin
            putMilestoneM(rec[i].mid, InstructionMap::RobEnter);
            
                // TODO: also RobComplete if 0 uops
            if (rec[i].completed.and() !== 0) putMilestoneM(rec[i].mid, InstructionMap::RobComplete);
        end
    endtask
    
    function automatic logic frontCompleted();
        OpRecordA records = array[startPointer % DEPTH].records;
        if (endPointer == startPointer) return 0;

        foreach (records[i])
            if (records[i].mid != -1 && records[i].completed.and() === 0) // Will be 0 if has any 0 (also with XZ)
                return 0;
        
        return 1;
    endfunction
    
    
    function automatic InsId getLastOut(input InsId prev, input OpRecordA recs);
        InsId tmp = prev;
        
        foreach (recs[i])
            if  (recs[i].mid != -1)
                tmp = recs[i].mid;
                
        return tmp;
    endfunction

    function automatic logic isLastBreaking(input OpRecordA recs);
        logic brk = 0;
        
        foreach (recs[i])
            if  (recs[i].mid != -1)
                brk = breaksCommitId(recs[i].mid);
                
        return brk;
    endfunction

endmodule
