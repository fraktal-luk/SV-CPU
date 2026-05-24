
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;

import RobDefs::*;


module Alt_ROB
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

        OpRecordA currentRow = '{default: EMPTY_RECORD}, prevRow = '{default: EMPTY_RECORD};

    int pDrain = 0, pCommit = 0, /*pCommitNext = 0,*/ pRead = 0, pScan = 0, pEnd = 0, pBackup = 0,  pScanPrev = 0, pReadPrev = 0;;


        InsId lastScannedId = -1, lastScannedIdVar = -1, lastCommittedId = -1, lastCommittedIdVar = -1, lastReadId = -1, lastReadIdVar = -1, prevReadId = -1;
        InsId lastScannedIdEvt = -1;

        logic eventFound = 0;

        Mword trg, trgEvt, trgCommitted;


    logic ch0, ch1, ch2, ch3, ch4;


    // always_comb ch0 = pointerOlderThan(pScan, pScanPrev, pScan);
    // always_comb ch1 = pointerOlderThan(pScan, pEnd, pCommit);

    // always_comb ch3 = pointerOlderThan(pScanPrev, pScan, pScan);
    // always_comb ch4 = pointerOlderThan(pEnd, pScan, pCommit);


        assign ch0 = (lastScannedId == theRob.lastOut);
        assign ch1 = (lastScannedId == theRob.lastScanned);
        
        assign ch2 = (lastReadId == theRob.lastOut);
        assign ch3 = (prevReadId == theRob.lastOut);


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



    task automatic commit();
        int p = pCommit;
        lastCommittedIdVar = lastCommittedId;


        while (array[p2i(p)].mid == -1 || array[p2i(p)].mid <= theRob.lastOut /*AbstractCore.lastRetired*/) begin

                   // assert (theRob.lastOut == prevReadId) else $error("id diff %d, %d", theRob.lastOut, prevReadId);

            if (p == pEnd) break;

                array[p2i(p)] = EMPTY_RECORD;
            array[p2i(p)].used = 'z;

            // if (array[p2i(p)].mid != -1)
            //     handleScan_Commit(array[p2i(p)]);

            p = movePtrOne(p);
        end

        pCommit <= p;
        lastCommittedId <= lastCommittedIdVar;

        moveRead();
        moveScan();
    endtask



    task automatic moveScan();
        int p = pScan; // Old value!
        lastScannedIdVar = lastScannedId;

        if (!eventFound) begin
            while (array[p2i(p)].mid == -1 || (array[p2i(p)].completed.and() !== 0)) begin

                    if (array[p2i(p)].mid == 5203) $error("SCANNING  5203");


                if (array[p2i(p)].mid != -1 && (array[p2i(p)].mid == eventUnit.general.id)) begin
                    // This slot has an event
                    eventFound <= 1;
                    TMP_handleScanEvt(array[p2i(p)]);
                    handleScan(array[p2i(p)]);
                    p = movePtrOne(p);
                    break;
                end
                if (p == pEnd) break;

                array[p2i(p)].used = 'x;

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

        //if (!eventFound) begin
            while (1) begin //array[p2i(p)].mid == -1 || (array[p2i(p)].completed.and() !== 0)) begin
                // if (array[p2i(p)].mid != -1 && (array[p2i(p)].mid == eventUnit.general.id)) begin
                //     // This slot has an event
                //     handleRead(array[p2i(p)]);
                //     break; // Don't mpve
                // end
                if (p == pScan) break;

                if (p == pNextRow) break;

                //array[p2i(p)].used = 'x;

                currentRow[p % WIDTH] <= array[p2i(p)];

                if (array[p2i(p)].mid != -1)
                    handleRead(array[p2i(p)]);

                p = movePtrOne(p);
            end
        //end

        pRead <= p;
        prevReadId <= lastReadId;
        lastReadId <= lastReadIdVar;

        pReadPrev <= pRead;
    endtask



    task automatic handleLateEvent();

        // if (eventUnit.general.active) begin
        //     // InstructionInfo info = insMap.get(mid);
        //     // BqEntry found[$] = AbstractCore.theBq.content.find_first with (item.mid == mid);

        //     handleScan(array[p2i(pScan)]);

        //     pScanPrev <= pScan;
        //     pScan <= movePtrOne(pScan);

        // end

            trg <= lateEventInfo.target;


        eventFound <= 0;
    endtask



    task automatic flushAll();
        int lc = 0;

        // Clear starting from pCommit
        int p = pCommit;

        while (p != pEnd) begin
            array[p2i(p)] = EMPTY_RECORD;

            lc++;
            if (lc > ROB_SIZE) begin
                $error("wrapped around whole ROB!");
                break;
            end

            p = movePtrOne(p);
        end

        // new pEnd: pCommit rounded up to beginning of row
        if (pCommit % WIDTH == 0) pEnd <= pCommit;
        else pEnd <= movePtrRow(pCommit);

        // move scan pointer:
        if (pCommit % WIDTH == 0) pScan <= pCommit;
        else pScan <= movePtrRow(pCommit);
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


    OpRecordA lastRec;


    task automatic writeInput(input OpSlotAB in);
        OpRecordA rec = makeRecord(in);

        array[p2i(pEnd) +: WIDTH] = rec;
            lastRec <= rec;
        pEnd <= movePtrRow(pEnd);

    endtask


    task automatic alt_markCompleted();
        alt_markPacketCompleted(theExecBlock.doneRegular0_E);
        alt_markPacketCompleted(theExecBlock.doneRegular1_E);

        alt_markPacketCompleted(theExecBlock.doneBranch_E);

        alt_markPacketCompleted(theExecBlock.doneDivider_E);

        alt_markPacketCompleted(theExecBlock.doneMultiplier0_E);
        alt_markPacketCompleted(theExecBlock.doneMultiplier1_E);


        alt_markPacketCompleted(theExecBlock.doneFloat0_E);
        alt_markPacketCompleted(theExecBlock.doneFloat1_E);
        alt_markPacketCompleted(theExecBlock.doneFloatDiv_E);

        alt_markPacketCompleted(theExecBlock.doneMem0_E);
        alt_markPacketCompleted(theExecBlock.doneMem2_E);
        alt_markPacketCompleted(theExecBlock.doneStoreData_E);
    endtask

    task automatic alt_markPacketCompleted(input UopPacket p);         
        int found[$];
        int sub = SUBOP(p.TMP_oid);

        if (!p.active) return;
        
        found = array.find_first_index with (item.mid == U2M(p.TMP_oid));

        assert (found.size() > 0) else $error("%p not found in ROB!", p.TMP_oid);

        array[found[0]].completed[sub] = 1;

         // TODO: if all completed, put milestone
        if (array[found[0]].completed.and()) begin
            //
        end
    endtask


    function automatic void handleScan_Commit(input OpRecord rec);
        InsId mid = rec.mid;
        InstructionInfo info = insMap.get(mid);
        BqEntry found[$] = AbstractCore.theBq.content.find_first with (item.mid == mid);

        trgCommitted <= findTarget(info, found);


        lastCommittedIdVar = mid;
    endfunction

    function automatic void handleScan(input OpRecord rec);
        InsId mid = rec.mid;
        InstructionInfo info = insMap.get(mid);
        BqEntry found[$] = AbstractCore.theBq.content.find_first with (item.mid == mid);

        trg <= findTarget(info, found);


        lastScannedIdVar = mid;
    endfunction

    function automatic void handleRead(input OpRecord rec);
        InsId mid = rec.mid;
        //InstructionInfo info = insMap.get(mid);

        lastReadIdVar = mid;
    endfunction



   function automatic void TMP_handleScanEvt(input OpRecord rec);
        // TODO
        InsId mid = rec.mid;
        InstructionInfo info = insMap.get(mid);
        BqEntry found[$] = AbstractCore.theBq.content.find_first with (item.mid == mid);

        trgEvt <= findTarget(info, found);

        lastScannedIdEvt <= mid;
    endfunction



    generate
        OpRecord recCommit, recScan, recScanPrev, recEnd;

        assign recCommit = array[p2i(pCommit)];        
        assign recScan = array[p2i(pScan)];        
        assign recScanPrev = array[p2i(pScanPrev)];        
        assign recEnd = array[p2i(pEnd)];        
    endgenerate


endmodule
