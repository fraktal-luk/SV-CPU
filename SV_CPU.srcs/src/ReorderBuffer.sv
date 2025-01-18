
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
        

    int savedPointer = 0,
        startPointer = 0,
        startPointer_ArrHead = 0, // Probably should be the point to restore endPointer + startPointer!
        startPointer_OutRow = 0,  endPointer = 0,           drainPointer = 0;
    int size, size_N;
    logic allow;

        int backupPointer;
        
        assign backupPointer = //startPointer;
                               //startPointer_ArrHead;
                               savedPointer;


    OpSlotAB outGroupPrev = '{default: EMPTY_SLOT_B};

    RetirementInfoA retirementGroup, retirementGroupPrev = '{default: EMPTY_RETIREMENT_INFO};

    Row arrayHeadRow = EMPTY_ROW, outRow = EMPTY_ROW;
    Row array[DEPTH] = '{default: EMPTY_ROW};
        Row array_N[DEPTH] = '{default: EMPTY_ROW};

    InsId lastScanned = -1, // last id whoch was transfered to output queue
          lastOut = -1;     // last accepted as committed
    logic lastIsBreaking = 0;
    logic lateEventOngoing;

        RRQ rrq;
        RobResult rrq_View[40];
        int rrqSize = -1;

    assign size = (endPointer - startPointer + 2*DEPTH) % (2*DEPTH);
        assign size_N = (endPointer - drainPointer + 2*DEPTH) % (2*DEPTH);
    assign allow = (size < DEPTH - 3)
                                        && (size_N < DEPTH - 3);
    

    always_comb outGroup = makeOutGroup(outRow);
    always_comb retirementGroup = makeRetirementGroup();
    
    always_comb lateEventOngoing = AbstractCore.interrupt || AbstractCore.reset || lateEventInfo.redirect
                                || AbstractCore.lateEventInfoWaiting.active
                                || lastIsBreaking;

        TableIndex indA = '{0, 0, -1}, indB = '{0, 0, -1}, indCommitted = '{-1, -1, -1};
        TableIndex indReady = '{0, 0, -1};

        logic evtWaiting = 0;


    
    function automatic Row takeFromQueue(input Row row);
        Row res = EMPTY_ROW;

        foreach (row.records[i]) begin
            if (row.records[i].mid != -1) begin
                assert (row.records[i].completed.and() !== 0) else $fatal(2, "not compl"); // Will be 0 if any 0 is there
                res.records[i] = row.records[i];
                if (breaksCommitId(row.records[i].mid)) break;
            end
        end

        return res;
    endfunction


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



    task automatic readTable();
        Row arrayHeadRowVar;
        Row outRowVar;
        Row row;

        startPointer_OutRow = startPointer_ArrHead;
        startPointer_ArrHead = startPointer;

        if (lateEventOngoing) begin            
            arrayHeadRow <= EMPTY_ROW;
        end
        else begin
            if (frontCompleted())
                arrayHeadRowVar = readOutRow();
            else
                arrayHeadRowVar = EMPTY_ROW;
                
            arrayHeadRow <= arrayHeadRowVar;
            lastScanned <= getLastOut(lastScanned, arrayHeadRowVar.records);   
        end




        row = tickRow(arrayHeadRow);

        if (lateEventOngoing) begin            
            outRow <= EMPTY_ROW;
            lastIsBreaking <= 0;
        end
        else begin
            outRowVar = takeFromQueue(row);
            
            outRow <= outRowVar;
            lastOut <= getLastOut(lastOut, outRowVar.records);
            
            lastIsBreaking <= isLastBreaking(outRowVar.records);
                
            savedPointer = (startPointer_OutRow + 1) % (2*DEPTH);
        end

    endtask


        localparam logic DELAY_SCAN = 1;

    always @(posedge AbstractCore.clk) begin
        outGroupPrev <= outGroup;
        retirementGroupPrev <= retirementGroup;

        readTable();

            // Vqriant: Completed status set in this cycle won't be noticed yet
            if (DELAY_SCAN) indsAB();

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

            // Variant: Completed status set in this cycle will be noticed
            if (!DELAY_SCAN) indsAB();

    end


    task automatic indsAB();
        if (lateEventInfo.redirect) begin
            indA = '{backupPointer, 0, indA.mid};
                indB = '{backupPointer, 0, -1};
                rrq.delete();
            
            indReady = '{backupPointer, 0, -1};
            evtWaiting = 0;
        end
        else begin
            
            
            // Advance indA, indB
            while (entryCompleted(entryAt(indA))) begin
                if (entryAt(indA).mid != -1)
                    indA.mid = entryAt(indA).mid;
                indA = incIndex(indA);
            end
            
            while (ptrInRange(indB.row, '{/*startPointer*/ startPointer_OutRow, endPointer}, DEPTH) && entryCompleted_T(entryAt(indB))) begin
                    InsId thisMid = entryAt(indB).mid;

                    if (entryAt(indB).mid != -1) begin
                        logic ct = isControlUop(decMainUop(thisMid));
                        logic rf = insMap.get(thisMid).refetch;
                        logic ex = insMap.get(thisMid).exception;
                        rrq.push_back('{thisMid, '{indB.row, indB.slot, thisMid}, ct, rf, ex});
                    end
                indB = incIndex(indB);
            end
            
                if (indA.row != indB.row || indA.slot != indB.slot) begin
                    $error("Differing inds %p, %p", indA, indB);
                end
                
        end        


       while (rrq.size() > 0 && (rrq[0].id <= coreDB.lastRetired.mid || rrq[0].id <= coreDB.lastRefetched.mid)) void'(rrq.pop_front());
       
       while (1) begin
            // head row contains something younger than last retired?
           int fd[$] = array_N[drainPointer % DEPTH].records.find_index with ( item.mid != -1 && (item.mid >= coreDB.lastRetired.mid && item.mid >= coreDB.lastRefetched.mid) );
           
                if (size_N > 30) $fatal(2, "overwti");
            
           if (drainPointer == /*startPointer*/ startPointer_OutRow) break;
            
           if (fd.size() == 0) begin
               array_N[drainPointer % DEPTH] = EMPTY_ROW;
               drainPointer = (drainPointer+1) % (2*DEPTH);
           end
           else break;
       end
       
        rrqSize <= rrq.size();
   
        rrq_View = '{default: EMPTY_ROB_RESULT};
        foreach (rrq[i])
            rrq_View[i] = rrq[i];
        //end
    endtask




    task automatic flushArrayAll();        
        foreach (array[r]) begin
            OpRecord row[WIDTH] = array[r].records;
            foreach (row[c])
                putMilestoneM(row[c].mid, InstructionMap::RobFlush);
        end

        endPointer = backupPointer;
        startPointer = backupPointer;
            startPointer_ArrHead = backupPointer;
            startPointer_OutRow = backupPointer;
        
        
        array = '{default: EMPTY_ROW};
        
        foreach (array_N[r]) begin
            Row row = array_N[r];
            foreach (row.records[c])
                if (array_N[r].records[c].used !== 'z) array_N[r].records[c] = EMPTY_RECORD;
        end
    endtask


    task automatic flushArrayPartial();
        logic clear = 0;
        InsId causingMid = branchEventInfo.eventMid;
        int p = startPointer;
     
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


    function automatic Row readOutRow();
        Row row = array[startPointer % DEPTH];
        
        foreach (row.records[i])
            if (row.records[i].mid != -1) putMilestoneM(row.records[i].mid, InstructionMap::RobExit);

        array[startPointer % DEPTH] = EMPTY_ROW;
            
//        foreach (row.records[k])    
//            array_N[startPointer % DEPTH].records[k].used = 'z;

            foreach (row.records[k])    
                array_N[startPointer_ArrHead % DEPTH].records[k].used = 'z;
                
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
                CompletedVec initialCompleted = initCompletedVec(nUops);
                res[i] = '{1, ops[i].mid, initialCompleted};
            end
            else
                res[i].used = 1; // Empty slots within occupied rows
        end
        return res;
    endfunction


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
    
    function automatic logic frontCompleted();
        OpRecordA records = array[startPointer % DEPTH].records;
        if (endPointer == startPointer) return 0;

        foreach (records[i])
            if (records[i].mid != -1 && (records[i].completed.and() === 0      || records[i].mid > indA.mid))
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

    function automatic OpSlotAB makeOutGroup(input Row row);
        OpSlotAB res = '{default: EMPTY_SLOT_B};
        foreach (row.records[i]) begin
            if (row.records[i].mid == -1) continue;
            res[i].active = 1;
            res[i].mid = row.records[i].mid;
        end

        return res;
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
            if (isStoreUop(insMap.get(mid).mainUop)) begin
                StoreQueueHelper::Entry entry[$] = outputSQ.find with (item.mid == mid);
                res[i].refetch = entry[0].refetch;
                res[i].exception = entry[0].error;               
            end

            if (isLoadUop(insMap.get(mid).mainUop)) begin
                 LoadQueueHelper::Entry entry[$] = outputLQ.find with (item.mid == mid);
                 res[i].refetch = entry[0].refetch;
                 res[i].exception = entry[0].error;
            end
            
            if (isBranchUop(insMap.get(mid).mainUop)) begin
                UopName uname = insMap.getU(FIRST_U(mid)).name;

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
        markPacketCompleted(theExecBlock.doneSys_E);
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
    
    function automatic logic entryCompleted(input OpRecord rec);
        return rec.used && ((rec.mid == -1) || (rec.completed.and() !== 0)); // empty slots within used rows are by definition completed
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
