
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


        initial begin
            $error("(0 - 252) mod 256: %d", (0-252) % 256);
            $error("(0 - 252) pmod 256: %d", properMod(0-252 ,256));

            $error("0 olde than 4 @ 0: %d", pointerOlderThan(0, 4, 0));
            $error("0 olde than 4 @ 4: %d", pointerOlderThan(0, 4, 4));

        end


        OpRecord array[ROB_SIZE] = '{default: EMPTY_RECORD};


        int pDrain = 0, pCommit = 0, /*pCommitNext = 0,*/ pRead = 0, pScan = 0, pEnd = 0, pBackup = 0,  pScanPrev = 0;  
        int ct = -1;


            logic ch0, ch1, ch2, ch3, ch4;


            always_comb ch0 = pointerOlderThan(pScan, pScanPrev, pScan);
            always_comb ch1 = pointerOlderThan(pScan, pEnd, pCommit);


            always_comb ch3 = pointerOlderThan(pScanPrev, pScan, pScan);
            always_comb ch4 = pointerOlderThan(pEnd, pScan, pCommit);


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

        while (array[p2i(p)].mid == -1 || array[p2i(p)].mid <= AbstractCore.lastRetired) begin
            if (p == pEnd) break;
            array[p2i(p)].used = 'z;
            p = movePtrOne(p);
            //if (p == pEnd) break;
        end

        pCommit <= p;


        p = pScan; // Old value!
        while (array[p2i(p)].mid == -1 || (array[p2i(p)].completed.and() !== 0)) begin
            if (array[p2i(p)].mid != -1 && (array[p2i(p)].mid == eventUnit.general.id)) break; // Don't mpve
            if (p == pEnd) break;

            array[p2i(p)].used = 'x;
            p = movePtrOne(p);
        end

        pScan <= p;




            pScanPrev <= pScan;
    endtask



    task automatic flushAll();
        int lc = 0;

        // Clear starting from pCommit
        int p = pCommit;

            // $error("flush a");

            // return;

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


            // $error("flush p");

            // return;

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


    generate
        OpRecord recCommit, recScan, recScanPrev, recEnd;

        assign recCommit = array[p2i(pCommit)];        
        assign recScan = array[p2i(pScan)];        
        assign recScanPrev = array[p2i(pScanPrev)];        
        assign recEnd = array[p2i(pEnd)];        
    endgenerate


endmodule
