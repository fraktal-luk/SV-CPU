
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;
import Queues::*;


module RegisterUnit();
    RegisterTracker #(N_REGS_INT, N_REGS_FLOAT) registerTracker = new();




    typedef PhysicalName PhysicalNameQ[$];


    function automatic PhysicalNameQ initFreeList();
        PhysicalNameQ res = '{};

        for (int i = 0; i < N_REGS_INT; i++) 
            res.push_back(i);

        return res;
    endfunction


    PhysicalNameQ freeList = initFreeList();

    PhysicalName allocationList[N_REGS_INT] = initFreeList();
    int nextTakePointer = 1; // which is first to take
    int nextCommitPointer = 1; // which is first to commit (not yet committed)
    int nextWritePointer = 0; // which will be filled

    typedef PhysicalName MappingTable[32];





    MappingTable newestTable = '{default: 0}, committedTable = '{default: 0};


    RenamePatch latestPatch;


    function automatic RenamePatch reserve(input OpSlotAF ops);
        RenamePatch patch = '{'{default: -1}, '{default: -1}, '{default: -1}};
        int readPtr = nextTakePointer;

        // For the beginning: only Int

        foreach (ops[i]) begin
            if (ops[i].mid == -1) continue;

            begin
                UopName mainUop = decMainUop(ops[i].mid);

                if (uopHasIntDest(mainUop)) begin
                    int vReg = decMainUopInfo(ops[i].mid).vDest;
                    //if (vReg == 0) continue;
                    patch.vNames[i] = vReg;
                    patch.pNames[i] = allocationList[readPtr % N_REGS_INT]; //freeList.size() > 0 ? freeList.pop_front() : -1;
                    readPtr++;
                end

                patch.pointers[i] = readPtr % N_REGS_INT;


                // if (uopHasFloatDest(mainUop)) begin
                //     int vReg = decMainUopInfo(ops[i].mid).vDest;
                //     patch.vNames[i] = vReg;
                // end
            end
        end

            nextTakePointer <= readPtr % N_REGS_INT;
            latestPatch <= patch;


            foreach (latestPatch.vNames[i]) begin
                VirtualName vName = latestPatch.vNames[i];
                PhysicalName pName = latestPatch.pNames[i];


                if (latestPatch.vNames[i] inside {-1, 0}) continue;

                newestTable[vName] = pName;
            end


        return patch;
    endfunction


    function automatic void releaseRegs(input RobDefs::OpRecordA ops, input logic evt, input int evtSlot);
        logic selectInt[RENAME_WIDTH] = '{default: 0},
              selectFloat[RENAME_WIDTH] = '{default: 0};
              //selectEvt[RENAME_WIDTH] = '{default: 0};

        int readPtr = nextCommitPointer;

        MappingTable tmpCommittedTable = committedTable;

        foreach (ops[i]) begin
            if (ops[i].mid == -1) continue;

            begin
                UopName mainUop = decMainUop(ops[i].mid);

                if (evt && i == evtSlot) begin
                    // TODO: this op is exceptional. don't commit register but free it
                    //      FUTURE: there may be exceptions which do commit their register? (like for FP traps with default result?) 
                    PhysicalName pName = allocationList[readPtr++ % N_REGS_INT];

                    if (!pName inside {-1, 0})
                        allocationList[nextWritePointer++ % N_REGS_INT] = pName;

                    break;
                end

                selectInt[i] = (uopHasIntDest(mainUop));
                selectFloat[i] = (uopHasFloatDest(mainUop));

                if (uopHasIntDest(mainUop)) begin
                    int vReg = decMainUopInfo(ops[i].mid).vDest;
                    PhysicalName pName = allocationList[readPtr % N_REGS_INT];
                    PhysicalName toFree = -1;

                    if (vReg inside {-1, 0}) continue;

                    readPtr++;

                    toFree = tmpCommittedTable[vReg];
                    tmpCommittedTable[vReg] = pName;

                    if (!toFree inside {-1, 0})
                        allocationList[nextWritePointer++ % N_REGS_INT] = toFree;
                end



            end

        end

            nextWritePointer %= N_REGS_INT;

            committedTable <= tmpCommittedTable;

            nextCommitPointer <= readPtr % N_REGS_INT;

    endfunction


    function automatic void flushToStable();
        registerTracker.restoreStable();
        registerTracker.flushAll();

            nextTakePointer <= nextCommitPointer;
            newestTable <= committedTable;
    endfunction


    function automatic void flushToCheckpoint(input BranchCheckpoint bc);
        registerTracker.restoreCP(bc.intMapR, bc.floatMapR, bc.intWriters, bc.floatWriters);
        registerTracker.flush(bc.id);
    endfunction

        function automatic void flushRegsToCheckpoint(input RegisterCheckpoint rc);
            RenamePatch patch = rc.patch;

            foreach (patch.vNames[i]) begin
                if (i <= rc.index) continue;
                
                patch.vNames[i] = -1;
                patch.pNames[i] = -1;
                patch.pointers[i] = -1;
            end

            nextTakePointer <= rc.patch.pointers[rc.index];

            newestTable <= rc.tb;
            latestPatch <= patch;
        endfunction


    function automatic void write(input UopName name, input int vDest, input WriterId wid, input Mword value);
        
        putMilestone(wid, InstructionMap::WriteResult);

        registerTracker.writeValue(name, vDest, wid, value);
    endfunction

endmodule
