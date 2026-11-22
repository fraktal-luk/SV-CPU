
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



    typedef PhysicalName MappingTable[32];





    MappingTable newestTable = '{default: 0}, committedTable = '{default: 0};


    RenamePatch latestPatch;


    function automatic RenamePatch reserve(input OpSlotAF ops);
        RenamePatch patch;

        foreach (ops[i]) begin
            if (ops[i].mid == -1) continue;

            begin
                UopName mainUop = decMainUop(ops[i].mid);

                if (uopHasIntDest(mainUop)) begin
                    int vReg = decMainUopInfo(ops[i].mid).vDest;
                    //if (vReg == 0) continue;
                    patch.vNames[i] = vReg;
                end

                if (uopHasFloatDest(mainUop)) begin
                    int vReg = decMainUopInfo(ops[i].mid).vDest;
                    patch.vNames[i] = vReg;
                end
            end
        end

            latestPatch <= patch;

        return patch;
    endfunction


    function automatic void releaseRegs(input RobDefs::OpRecordA ops, input logic evt, input int evtSlot);
        logic selectInt[RENAME_WIDTH] = '{default: 0},
              selectFloat[RENAME_WIDTH] = '{default: 0};
              //selectEvt[RENAME_WIDTH] = '{default: 0};

        foreach (ops[i]) begin
            UopName mainUop = decMainUop(ops[i].mid);

            if (evt && i == evtSlot) begin
                // TODO: this op is exceptional. don't commit register but free it
                //      FUTURE: there may be exceptions which do commit their register? (like for FP traps with default result?) 

                break;
            end

            selectInt[i] = (uopHasIntDest(mainUop));
            selectFloat[i] = (uopHasFloatDest(mainUop));

        end
    endfunction


    function automatic void flushToStable();
        registerTracker.restoreStable();
        registerTracker.flushAll();
    endfunction


    function automatic void flushToCheckpoint(input BranchCheckpoint bc);
        registerTracker.restoreCP(bc.intMapR, bc.floatMapR, bc.intWriters, bc.floatWriters);
        registerTracker.flush(bc.id);
    endfunction


    function automatic void write(input UopName name, input int vDest, input WriterId wid, input Mword value);
        
        putMilestone(wid, InstructionMap::WriteResult);

        registerTracker.writeValue(name, vDest, wid, value);
    endfunction

endmodule
