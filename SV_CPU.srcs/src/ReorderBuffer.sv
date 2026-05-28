
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;

import RobDefs::*;


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


    OpRecord array[ROB_SIZE] = '{default: EMPTY_RECORD};

    OpRecordA currentRow = '{default: EMPTY_RECORD}, prevRow = '{default: EMPTY_RECORD}, lastRec = '{default: EMPTY_RECORD};

    int pDrain = 0, pCommit = 0, pRead = 0, pScan = 0, pEnd = 0, pScanPrev = 0, pReadPrev = 0;;

    InsId lastScannedId = -1, lastScannedIdVar = -1, lastReadId = -1, lastReadIdVar = -1, prevReadId = -1, lastScannedIdEvt = -1;

    logic eventFound = 0;

    Mword trg = 'x, trgEvt = 'x;


    logic isEmpty, allow;
    int size;


    always_comb isEmpty = (pEnd === pCommit);
    assign size = (pEnd - pDrain + 2*ROB_SIZE) % (2*ROB_SIZE);
    assign allow = (size < ROB_SIZE - WIDTH*N_RENAME_STAGES);


    always @(posedge AbstractCore.clk) begin
        commit();
        markCompleted();

        if (lateEventInfo.redirect) begin
            handleLateEvent();
            flushAll();
        end
        else if (branchEventInfo.redirect) begin
            flushPartial();
        end
        else if (anyActiveB(inGroup)) begin
            writeInput(inGroup);
        end
    end


    task automatic commit();
        int p = pCommit;

        while (array[p2i(p)].mid == -1 || array[p2i(p)].mid <= prevReadId) begin
            if (p == pEnd) break;

            array[p2i(p)] = EMPTY_RECORD;
            p = movePtrOne(p);
        end

        pCommit <= p;
        pDrain <= pCommit; // For now pDrain is assumed to always go one step behind pCommit

        moveRead();
        moveScan();
    endtask



    task automatic moveScan();
        int p = pScan; // Old value!
        lastScannedIdVar = lastScannedId;

        if (!eventFound) begin
            while (array[p2i(p)].mid == -1 || (array[p2i(p)].completed.and() !== 0)) begin
                if (array[p2i(p)].mid != -1 && (array[p2i(p)].mid == eventUnit.general.id)) begin
                    // This slot has an event
                    eventFound <= 1;
                    handleScan(array[p2i(p)]);
                    p = movePtrOne(p);
                    break;
                end
                if (p == pEnd) break;

                if (array[p2i(p)].mid != -1)
                    handleScan(array[p2i(p)]);

                p = movePtrOne(p);
            end
        end

        pScan <= p;
        lastScannedId <= lastScannedIdVar;

        pScanPrev <= pScan;
    endtask


    task automatic moveRead();
        int p = pRead; // Old value!
        int pNextRow = movePtrRow(pRead);
        lastReadIdVar = lastReadId;

        prevRow <= currentRow;
        currentRow <= '{default: EMPTY_RECORD};

        while (1) begin
            if (p == pScan) break;
            if (p == pNextRow) break;

            currentRow[p % WIDTH] <= array[p2i(p)];
            putMilestoneM(array[p2i(p)].mid, InstructionMap::RobExit);

            if (array[p2i(p)].mid != -1)
                handleRead(array[p2i(p)]);

            p = movePtrOne(p);
        end

        pRead <= p;
        prevReadId <= lastReadId;
        lastReadId <= lastReadIdVar;

        pReadPrev <= pRead;
    endtask


    task automatic handleLateEvent();
        trg <= lateEventInfo.target;
        eventFound <= 0;
    endtask

    task automatic flushAll();
        int lc = 0;

        int p = pCommit; // Clear starting from pCommit

        while (p != pEnd) begin
            putMilestoneM(array[p2i(p)].mid, InstructionMap::RobFlush);
            array[p2i(p)] = EMPTY_RECORD;

            lc++;
            if (lc > ROB_SIZE) begin
                $error("wrapped around whole ROB!");
                break;
            end

            p = movePtrOne(p);
        end

        if (pCommit % WIDTH == 0) begin
            pEnd <= pCommit;
            pScan <= pCommit;
            pRead <= pCommit;
        end
        else begin
            pEnd <= movePtrRow(pCommit);
            pScan <= movePtrRow(pCommit);
            pRead <= movePtrRow(pCommit);
        end
    endtask

    task automatic flushPartial();
        int lc = 0;
        int pEndNew = -1;

        // Clear starting from given
        int p = pCommit;

        // move until finding proper mid
        while (array[p2i(p)].mid != branchEventInfo.eventMid) begin
            lc++;
            if (lc >= ROB_SIZE) begin
                $error("not found causing id");
                break;
            end
            p = movePtrOne(p);
        end

        pEndNew = movePtrRow(p);
        // from next after mid - clear
        p = movePtrOne(p);

        lc = 0;

        while (p != pEnd) begin
            putMilestoneM(array[p2i(p)].mid, InstructionMap::RobFlush);

            array[p2i(p)] = EMPTY_RECORD;

            lc++;
            if (lc > ROB_SIZE) begin
                $error("wrapped around whole ROB!");
                break;
            end
            p = movePtrOne(p);
        end

        pEnd <= pEndNew;
    endtask


    task automatic writeInput(input OpSlotAB in);
        OpRecordA rec = makeRecord(in);

        array[p2i(pEnd) +: WIDTH] = rec;

        foreach (rec[i]) begin
            putMilestoneM(rec[i].mid, InstructionMap::RobEnter);
            if (rec[i].completed.and() !== 0) putMilestoneM(rec[i].mid, InstructionMap::RobComplete);
        end

        lastRec <= rec;
        pEnd <= movePtrRow(pEnd);
    endtask


    task automatic markCompleted();
        markPacketCompleted(theExecBlock.doneRegular0_E);
        markPacketCompleted(theExecBlock.doneRegular1_E);

        markPacketCompleted(theExecBlock.doneBranch_E);

        markPacketCompleted(theExecBlock.doneDivider_E);

        markPacketCompleted(theExecBlock.doneMultiplier0_E);
        markPacketCompleted(theExecBlock.doneMultiplier1_E);


        markPacketCompleted(theExecBlock.doneFloat0_E);
        markPacketCompleted(theExecBlock.doneFloat1_E);
        markPacketCompleted(theExecBlock.doneFloatDiv_E);

        markPacketCompleted(theExecBlock.doneMem0_E);
        markPacketCompleted(theExecBlock.doneMem2_E);
        markPacketCompleted(theExecBlock.doneStoreData_E);
    endtask

    task automatic markPacketCompleted(input UopPacket p);         
        int found[$];
        int sub = SUBOP(p.TMP_oid);

        if (!p.active) return;
        
        found = array.find_first_index with (item.mid == U2M(p.TMP_oid));

        assert (found.size() > 0) else $error("%p not found in ROB!", p.TMP_oid);

        array[found[0]].completed[sub] = 1;

        if (array[found[0]].completed.and() !== 0) putMilestoneM(U2M(p.TMP_oid), InstructionMap::RobComplete);
    endtask


    function automatic void handleScan(input OpRecord rec);
        InsId mid = rec.mid;
        InstructionInfo info = insMap.get(mid);
        BqEntry found[$] = AbstractCore.theBq.content.find_first with (item.mid == mid);

        trg <= findTarget(info, found);

        lastScannedIdVar = mid;
    endfunction


    function automatic void handleRead(input OpRecord rec);
        lastReadIdVar = rec.mid;
    endfunction

    generate
        OpRecord recCommit, recScan, recScanPrev, recEnd;

        assign recCommit = array[p2i(pCommit)];        
        assign recScan = array[p2i(pScan)];        
        assign recScanPrev = array[p2i(pScanPrev)];        
        assign recEnd = array[p2i(pEnd)];        
    endgenerate


    function automatic int properMod(input int what, input int by);
        int mayBeMinus = what % by;
        if (mayBeMinus < 0) return mayBeMinus + by;
        else return mayBeMinus;
    endfunction


    // Is left older than right?
    function automatic logic pointerOlderThan(input int left, input int right, input int pRef); 
        int leftRel = properMod(left - pRef, 2*ROB_SIZE);
        int rightRel = properMod(right - pRef, 2*ROB_SIZE);
        return leftRel < rightRel;
    endfunction


    function automatic int p2i(input int p);
        return p % ROB_SIZE;
    endfunction


    function automatic int movePtrOne(input int p);
        int pNew = (p + 1) % (2*ROB_SIZE);
        return pNew;
    endfunction

    function automatic int movePtrRow(input int p);
        int pBase = p - (p % WIDTH);
        int pNew = (pBase + WIDTH) % (2*ROB_SIZE);
        return pNew;
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

endmodule
