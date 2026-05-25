
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



    Alt_ROB#(.WIDTH(WIDTH)) altRob(insMap, branchEventInfo, lateEventInfo, inGroup);
    
    logic allow, isEmpty;

    assign isEmpty = altRob.isEmpty;
    assign allow = altRob.allow;


    always @(posedge AbstractCore.clk) begin
        altRob.commit();
        altRob.alt_markCompleted();

        if (lateEventInfo.redirect) begin
            altRob.handleLateEvent();
            altRob.flushAll();
        end
        else if (branchEventInfo.redirect) begin
            altRob.flushPartial();
        end
        else if (anyActiveB(inGroup)) begin
            altRob.writeInput(inGroup);
        end
    end


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

    function automatic int TMP_int(input TableIndex ind);
        return ind.row * WIDTH + ind.slot;
    endfunction

endmodule
