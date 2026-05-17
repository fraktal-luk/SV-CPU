
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


        int pDrain = 0, pCommit = 0, /*pCommitNext = 0,*/ pRead = 0, pScan = 0, pEnd = 0, pBackup = 0;  



        function automatic int movePtrOne(input int p);
            int pNew = (p + 1) % (2*ROB_SIZE);
            return pNew;
        endfunction

        function automatic int movePtrRow(input int p);
            int pBase = p % WIDTH;
            int pNew = (pBase + WIDTH) % (2*ROB_SIZE);
            return pNew;
        endfunction




    task automatic flushAll();
        // Clear starting from pCommit
        int p = pCommit;


            return;

        while (p != pEnd) begin
            array[p] = EMPTY_RECORD;

            p = movePtrOne(p);
        end

        // new pEnd: pCommit rounded up to beginning of row
        if (pCommit % WIDTH == 0) pEnd <= pCommit;
        else pEnd <= movePtrRow(pCommit);
    endtask

    task automatic flushPartial();
        int pNew = -1;

        // Clear starting from given
        int p = pCommit;

            return;

        // move until finding proper mid
        while (array[p].mid != branchEventInfo.eventMid) p = movePtrOne(p);

        // set ptrs to next after mid (next row beginning)
        pNew = movePtrRow(p);
        // from next after mid - clear
        p = movePtrOne(p);

        while (p != pEnd) begin
            array[p] = EMPTY_RECORD;

            p = movePtrOne(p);
        end

        pEnd <= pNew;
    endtask


    task automatic writeInput(input OpSlotAB in);
        OpRecordA rec = makeRecord(in);

        array[pEnd +: WIDTH] = rec;
        pEnd <= movePtrRow(pEnd);
        
        // foreach (rec[i]) begin
        //     putMilestoneM(rec[i].mid, InstructionMap::RobEnter);
        //     if (rec[i].completed.and() !== 0) putMilestoneM(rec[i].mid, InstructionMap::RobComplete);
        // end
    endtask


endmodule
