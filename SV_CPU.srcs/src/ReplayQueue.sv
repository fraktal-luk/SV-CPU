
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;


module ReplayQueue(
    ref InstructionMap insMap,
    input logic clk,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpPacket inPacket,
    output OpPacket outPacket
);

    localparam int SIZE = 16;

    typedef struct {
        logic used;
        InsId id;
    } Entry;

    localparam Entry EMPTY_ENTRY = '{0, -1};

    int numUsed = 0;
    Entry content[SIZE] = '{default: EMPTY_ENTRY};

    OpPacket issued0 = EMPTY_OP_PACKET, issued1 = EMPTY_OP_PACKET;


    always @(posedge clk) begin
        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
           flush();
        end
        
        issue();
        
        if (!(lateEventInfo.redirect || branchEventInfo.redirect))
            writeInput();
        

        issued1 <= tickP(issued0);
        
        numUsed <= getNumUsed();
    end


    task automatic writeInput();
    
    endtask

    task automatic issue();
    
    endtask

    task automatic flush();
        foreach (content[i]) begin
            if (lateEventInfo.redirect || (branchEventInfo.redirect && content[i].id > branchEventInfo.op.id)) begin
                if (content[i].used) putMilestone(content[i].id, InstructionMap::RqFlush);
                content[i] = EMPTY_ENTRY;
            end
        end
    endtask

    function automatic int getNumUsed();
        int res = 0;
        
        foreach (content[i]) if (content[i].used) res++;
        
        return res;
    endfunction


    assign outPacket = EMPTY_OP_PACKET;

endmodule
