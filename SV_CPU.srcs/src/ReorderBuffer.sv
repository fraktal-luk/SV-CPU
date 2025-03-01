
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
    input OpSlotAB inGroup
);
    localparam int DEPTH = ROB_SIZE/WIDTH;

    localparam int N_UOP_MAX = 2; // TODO: Number of uops a Mop can be split into

    typedef logic CompletedVec[N_UOP_MAX];

    typedef struct {
        logic used;
        InsId mid;
        CompletedVec completed;
    } OpRecord;
    
    localparam OpRecord EMPTY_RECORD = '{used: 0, mid: -1, completed: '{default: 'x}};

    typedef OpRecord OpRecordA[WIDTH];

    typedef struct {
        OpRecord records[WIDTH];
    } Row;
    
    localparam Row EMPTY_ROW = '{records: '{default: EMPTY_RECORD}};

    typedef OpRecord QM[3*WIDTH];

    
        // Experimental
        typedef struct {
            int row;
            int slot;
            InsId mid;
        } TableIndex;
        
        localparam TableIndex EMPTY_TABLE_INDEX = '{-1, -1, -1};

        
        typedef struct {
            InsId id = -1;
            TableIndex tableIndex = EMPTY_TABLE_INDEX;
            logic control;
            logic refetch;
            logic exception;
        } RobResult;
        
        localparam RobResult EMPTY_ROB_RESULT = '{-1, EMPTY_TABLE_INDEX, 'x, 'x, 'x};
        
        typedef RobResult RRQ[$];


    RetirementInfoA retirementGroup, retirementGroupPrev = '{default: EMPTY_RETIREMENT_INFO};

    Row arrayHeadRow = EMPTY_ROW, outRow = EMPTY_ROW;
    Row array[DEPTH] = '{default: EMPTY_ROW};
        Row array_N[DEPTH] = '{default: EMPTY_ROW};


    int drainPointer = -1, endPointer = 0;
    int backupPointer;
    int size;
    
    logic allow;
    
    InsId lastScanned = -1, // last id whoch was transfered to output queue
          lastOut = -1;     // last accepted as committed
    logic lateEventOngoing, lastIsBreaking = 0;//,  pre_lastIsBreaking = 0;
    
    TableIndex indB = '{0, 0, -1}, ind_Start = '{0, 0, -1},
               indCommitted = '{-1, -1, -1}, indNextToCommit = '{-1, -1, -1}, indToCommitSig = '{-1, -1, -1};


    RRQ rrq;
    RobResult rrq_View[40];
    int rrqSize = -1;



    assign size = (endPointer - drainPointer + 2*DEPTH) % (2*DEPTH);
    assign allow = (size < DEPTH - 3);

    always_comb backupPointer = (indCommitted.row + 1) % (2*DEPTH);                   

    always_comb retirementGroup = makeRetirementGroup();
    
    always_comb lateEventOngoing = AbstractCore.interrupt || AbstractCore.reset || lateEventInfo.redirect
                                || AbstractCore.lateEventInfoWaiting.active
                                || lastIsBreaking;



    always @(posedge AbstractCore.clk) begin
        retirementGroupPrev <= retirementGroup;

        advanceDrain();

        doRetirement();

        readTable();

        indsAB();

        markCompleted();

        if (lateEventInfo.redirect) begin
            flushArrayAll();
        end
        else if (branchEventInfo.redirect) begin
            flushArrayPartial();
        end
        else if (anyActiveB(inGroup)) begin
            add(inGroup);
        end

    end





    function automatic OpRecord tickRecord(input OpRecord rec);
        if (lateEventOngoing) begin
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


    function automatic Row readRowPart();
        Row head = array[ind_Start.row % DEPTH];
        Row res = EMPTY_ROW;
    
        foreach (head.records[i]) begin
            if (i < ind_Start.slot) continue;
            
            if (!indexInRange(ind_Start, '{indCommitted, indB}, DEPTH)) break;
            
            ind_Start = incIndex(ind_Start);
            
            if (head.records[i].mid == -1) continue;
            
            res.records[i] = head.records[i];

            assert (head.records[i].completed.and() !== 0) else $fatal(2, "not compl"); // Will be 0 if any 0 is there
            
            if (breaksCommitId(head.records[i].mid)) break;
        end
        
        return res;
    endfunction
    
    
    task automatic TMP_setZ(input RobResult r);
        TableIndex ti = indCommitted;
    
        while (1) begin
            ti = incIndex(ti);
            array_N[ti.row].records[ti.slot].used = 'z;                
            if (ti.row == r.tableIndex.row && ti.slot == r.tableIndex.slot) break;
        end
    endtask



    task automatic advanceDrain();
        // FUTURE: this condition will prevent from draining completely (last committed slot will remain). Later enable draining the last slot
        while (drainPointer != indCommitted.row) begin
           int fd[$] = array_N[drainPointer % DEPTH].records.find_index with ( item.mid != -1 && //(item.mid >= coreDB.lastRetired.mid && item.mid >= coreDB.lastRefetched.mid) );
                                                                                                 (item.mid >= indCommitted.mid) );
           if (fd.size() != 0) break;
           array_N[drainPointer % DEPTH] = EMPTY_ROW;
           drainPointer = (drainPointer+1) % (2*DEPTH);
        end
    endtask

    task automatic doRetirement();
        foreach (outRow.records[i]) begin
            InsId thisMid = outRow.records[i].mid;
            RobResult r;
            
            if (thisMid == -1) continue;
            r = rrq.pop_front();

            TMP_setZ(r);
            indCommitted <= r.tableIndex;
            
                assert (r.tableIndex === indNextToCommit) else $error("Differ: %p, %p", r.tableIndex, indNextToCommit);
            
            // Find next slot to be committed
            indNextToCommit = r.tableIndex;
            indNextToCommit.mid = entryAt(indNextToCommit).mid;
            while (indexInRange(indNextToCommit, '{indCommitted, '{endPointer, 0, -1}}, DEPTH)) begin
                indNextToCommit = incIndex(indNextToCommit);
                indNextToCommit.mid = entryAt(indNextToCommit).mid;
                
                if (entryAt(indNextToCommit).mid != -1) break;
            end
            
            
            if (breaksCommitId(thisMid)) break;
        end

        indNextToCommit.mid = entryAt(indNextToCommit).mid;
        while (indNextToCommit.mid == -1 && indexInRange(indNextToCommit, '{indCommitted, '{endPointer, 0, -1}}, DEPTH)) begin
            indNextToCommit = incIndex(indNextToCommit);
            indNextToCommit.mid = entryAt(indNextToCommit).mid;
            
            if (entryAt(indNextToCommit).mid != -1) break;
        end 

        indToCommitSig <= indNextToCommit;

    endtask;


    task automatic readTable();
        Row arrayHeadRowVar, outRowVar, row;

        if (lateEventOngoing) begin            
            arrayHeadRow <= EMPTY_ROW;
        end
        else begin
            arrayHeadRowVar = readRowPart();

            foreach (arrayHeadRowVar.records[i])
                if (arrayHeadRowVar.records[i].mid != -1) putMilestoneM(arrayHeadRowVar.records[i].mid, InstructionMap::RobExit);

            arrayHeadRow <= arrayHeadRowVar;
            lastScanned <= getLastOut(lastScanned, arrayHeadRowVar.records);
        end


        row = tickRow(arrayHeadRow);

        if (lateEventOngoing) begin            
            outRow <= EMPTY_ROW;
            lastIsBreaking <= 0;
        end
        else begin
            outRowVar = row;
            outRow <= outRowVar;
            lastOut <= getLastOut(lastOut, outRowVar.records);
            lastIsBreaking <= isLastBreaking(outRowVar.records);                
        end

    endtask


    task automatic indsAB();
        if (lateEventInfo.redirect) begin
            indNextToCommit = '{backupPointer, 0, -1};
            indToCommitSig <= indNextToCommit;
            ind_Start = '{backupPointer, 0, -1};
            indB = '{backupPointer, 0, -1};
            rrq.delete();            
        end
        else begin
            while (ptrInRange(indB.row, '{indCommitted.row, endPointer}, DEPTH) && entryCompleted_T(entryAt(indB))) begin
                InsId thisMid = entryAt(indB).mid;

                if (thisMid != -1) begin
                    InstructionInfo info = insMap.get(thisMid);
                    rrq.push_back('{thisMid, '{indB.row, indB.slot, thisMid}, isControlUop(info.mainUop), info.refetch, info.exception});
                end
                indB = incIndex(indB);
            end                
        end        


        rrqSize <= rrq.size();
        
        rrq_View = '{default: EMPTY_ROB_RESULT};
        foreach (rrq[i])
            rrq_View[i] = rrq[i];
    endtask



    task automatic flushArrayAll();
        foreach (array[r]) begin
            OpRecord row[WIDTH] = array[r].records;
            foreach (row[c])
                if (row[c].mid > indCommitted.mid) putMilestoneM(row[c].mid, InstructionMap::RobFlush);
        end

      
        foreach (array[r]) begin
            Row row = array[r];
            foreach (row.records[c]) begin
                if (array[r].records[c].mid > indCommitted.mid)
                    array[r].records[c] = EMPTY_RECORD;
            end
        end
         
        foreach (array_N[r]) begin
            Row row = array_N[r];
            foreach (row.records[c]) begin
                if (array_N[r].records[c].mid > indCommitted.mid)
                    array_N[r].records[c] = EMPTY_RECORD;
            end
        end
        
        endPointer = backupPointer;
    endtask


    task automatic flushArrayPartial();
        InsId causingMid = branchEventInfo.eventMid;
        int p = ind_Start.row; // TODO: change to first not committed entry?
     
        for (int i = 0; i < DEPTH; i++) begin
            OpRecord row[WIDTH] = array[p % DEPTH].records;
            logic rowContains = 0;
            for (int c = 0; c < WIDTH; c++) begin
                if (row[c].mid == causingMid) begin
                    endPointer = (p+1) % (2*DEPTH);
                    rowContains = 1;
                end
                if (row[c].mid > causingMid) begin
                    putMilestoneM(row[c].mid, InstructionMap::RobFlush);
                    array[p % DEPTH].records[c] = EMPTY_RECORD;
                        array_N[p % DEPTH].records[c] = EMPTY_RECORD;
                    if (rowContains) begin
                        array[p % DEPTH].records[c].used = 1;  // !!
                        array_N[p % DEPTH].records[c].used = 1;  // !!
                    end
                end
            end
            p++;
        end
    endtask



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
                res[i] = '{1, ops[i].mid, initCompletedVec(nUops)};
            end
            else
                res[i].used = 1; // Empty slots within occupied rows
        end
        return res;
    endfunction

                        // .active, .mid
    task automatic add(input OpSlotAB in);
        OpRecordA rec = makeRecord(in);

        array[endPointer % DEPTH].records = makeRecord(in);
            array_N[endPointer % DEPTH].records = makeRecord(in);
        endPointer = (endPointer+1) % (2*DEPTH);
        
        foreach (rec[i]) begin
            putMilestoneM(rec[i].mid, InstructionMap::RobEnter);
            if (rec[i].completed.and() !== 0) putMilestoneM(rec[i].mid, InstructionMap::RobComplete);
        end
    endtask
       
    
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



    function automatic RetirementInfoA makeRetirementGroup();
        Row row = outRow;
        
        StoreQueueHelper::Entry outputSQ[3*ROB_WIDTH] = AbstractCore.theSq.outputQM;
        LoadQueueHelper::Entry outputLQ[3*ROB_WIDTH] = AbstractCore.theLq.outputQM;
        BranchQueueHelper::Entry outputBQ[3*ROB_WIDTH] = AbstractCore.theBq.outputQM;
        
        RetirementInfoA res = '{default: EMPTY_RETIREMENT_INFO};
        foreach (row.records[i]) begin
            InsId mid = row.records[i].mid;
            
            if (mid == -1) continue;
            res[i].active = 1;
            res[i].mid = mid;
            
            res[i].takenBranch = 0;
            res[i].exception = 0;
            res[i].refetch = 0;
            
            // Find corresponding entries of queues
            if (isStoreUop(decMainUop(mid))) begin
                StoreQueueHelper::Entry entry[$] = outputSQ.find with (item.mid == mid);
                res[i].refetch = entry[0].refetch;
                res[i].exception = entry[0].error;               
            end

            if (isLoadUop(decMainUop(mid))) begin
                 LoadQueueHelper::Entry entry[$] = outputLQ.find with (item.mid == mid);
                 res[i].refetch = entry[0].refetch;
                 res[i].exception = entry[0].error;
            end
            
            if (isBranchUop(decMainUop(mid))) begin
                UopName uname = //insMap.getU(FIRST_U(mid)).name;
                                decMainUop(mid);
                BranchQueueHelper::Entry entry[$] = outputBQ.find with (item.mid == mid);
                res[i].takenBranch = entry[0].taken;
                
                if (isBranchRegUop(uname))
                    res[i].target = entry[0].regTarget;
                else
                    res[i].target = entry[0].immTarget;
            end
        end

        return res;
    endfunction


    task automatic markCompleted();
        markPacketCompleted(theExecBlock.doneRegular0_E);
        markPacketCompleted(theExecBlock.doneRegular1_E);
    
        markPacketCompleted(theExecBlock.doneFloat0_E);
        markPacketCompleted(theExecBlock.doneFloat1_E);
    
        markPacketCompleted(theExecBlock.doneBranch_E);
        markPacketCompleted(theExecBlock.doneMem0_E);
        markPacketCompleted(theExecBlock.doneMem2_E);
        markPacketCompleted(theExecBlock.doneStoreData_E);
    endtask

    task automatic markPacketCompleted(input UopPacket p);         
        if (!p.active) return;
        
        for (int r = 0; r < DEPTH; r++)
            for (int c = 0; c < WIDTH; c++)
                if (array[r].records[c].mid == U2M(p.TMP_oid)) begin
                    array[r].records[c].completed[SUBOP(p.TMP_oid)] = 1;
                        array_N[r].records[c].completed[SUBOP(p.TMP_oid)] = 1;
                    if (array[r].records[c].completed.and() !== 0) putMilestoneM(U2M(p.TMP_oid), InstructionMap::RobComplete);
                end
    endtask



    // Experimental    
    function automatic TableIndex incIndex(input TableIndex ind);
        TableIndex res = ind;
        
        res.slot++;
        if (res.slot == WIDTH) begin
            res.slot = 0;
            res.row = (res.row+1) % (2*DEPTH);
        end
        
        return res;
    endfunction
    
    function automatic OpRecord entryAt(input TableIndex ind);
        return array[ind.row % DEPTH].records[ind.slot];
    endfunction

    
        function automatic logic entryCompleted_T(input OpRecord rec);
            return (rec.mid == -1) || (rec.completed.and() !== 0); // empty slots within used rows are by definition completed
        endfunction

        function automatic logic ptrInRange(input int p, input int range[2], input int SIZE);
            int start = range[0];
            int endN = (range[1] - start + 2*SIZE) % (2*SIZE); // Adding 2*SIZE to ensure positive arg for modulo
            int pN = (p - start + 2*SIZE) % (2*SIZE);          // Adding 2*SIZE to ensure positive arg for modulo
            
            return pN < endN;
        endfunction

        function automatic int TMP_int(input TableIndex ind);
            return ind.row * WIDTH + ind.slot;
        endfunction

        function automatic logic indexInRange(input TableIndex p, input TableIndex range[2], input int SIZE);            
            int TSIZE = SIZE * WIDTH;
            
            int start = TMP_int(range[0]);
            int endN = (TMP_int(range[1]) - start + 2*TSIZE) % (2*TSIZE); // Adding 2*SIZE to ensure positive arg for modulo
            int pN = (TMP_int(p) - start + 2*TSIZE) % (2*TSIZE);          // Adding 2*SIZE to ensure positive arg for modulo
            
            return pN < endN;
        endfunction

endmodule
