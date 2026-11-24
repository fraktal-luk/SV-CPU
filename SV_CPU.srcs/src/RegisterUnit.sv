
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



    MappingTable newestTable = '{default: 0}, newestTableIdeal = '{default: 0}, committedTable = '{default: 0};


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

                newestTable[vName] <= pName;
            end


            foreach (patch.vNames[i]) begin
                VirtualName vName = patch.vNames[i];
                PhysicalName pName = patch.pNames[i];

                if (patch.vNames[i] inside {-1, 0}) continue;

                newestTableIdeal[vName] <= pName;
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
            newestTableIdeal <= committedTable;
    endfunction


    function automatic void flushToCheckpoint(input BranchCheckpoint bc);
        registerTracker.restoreCP(bc.intMapR, bc.floatMapR, bc.intWriters, bc.floatWriters);
        registerTracker.flush(bc.id);
    endfunction

        function automatic void flushRegsToCheckpoint(input RegisterCheckpoint rc);
            RenamePatch patch = rc.patch;
            MappingTable newestTableIdealRecreated = rc.tb;

            foreach (patch.vNames[i]) begin
                if (i <= rc.index) begin
                    VirtualName vName = patch.vNames[i];
                    PhysicalName pName = patch.pNames[i];


                    if (!vName inside {-1, 0})
                        newestTableIdealRecreated[vName] = pName;
                    continue;
                end
                patch.vNames[i] = -1;
                patch.pNames[i] = -1;
                patch.pointers[i] = -1;
            end

            // write

            nextTakePointer <= rc.patch.pointers[rc.index];

            newestTable <= rc.tb;
            newestTableIdeal <= newestTableIdealRecreated;
            latestPatch <= patch;
        endfunction


    function automatic void write(input UopName name, input int vDest, input WriterId wid, input Mword value);
        
        putMilestone(wid, InstructionMap::WriteResult);

        registerTracker.writeValue(name, vDest, wid, value);
    endfunction


    typedef PhysicalName PhysicalName3[3];
    typedef VirtualName VirtualName3[3];
    // typedef PhysicalName PhysicalSourceGroup[RENAME_WIDTH][3];

    typedef int Int3[3];


    function automatic Int3 findCurrentDeps(input VirtualName dests[], input int index, input VirtualName3 srcs);
        Int3 res = '{default: 1};

        foreach (dests[i]) begin
            if (i >= index) break;

            foreach (res[j]) begin
                if (!srcs[j] inside {-1, 0} && srcs[j] == dests[i]) res[j] = i;
            end
        end

        return res;
    endfunction



    function automatic VirtualName3 getVirtSourcesInt(input AbstractInstruction ins);
        VirtualName3 res = '{default: -1};
        InsDependencies deps = registerTracker.getArgDeps(ins);

        foreach (res[i]) begin
            if (deps.types[i] == SRC_INT) res[i] = deps.sources[i];
        end

        return res;
    endfunction

    // get pysical soirces:
    // - get virt sources of every op: [RENAME_WIDTH][3]
    // - for each of them: read physical name from newestTableIdeal
    // - find dependencies on dests being set now: [RENAME_WIDTH] ints: -1 if not dependent, slot index if dependent
    // - wherever dependence matrix not -1, replace with new dest at index


endmodule
