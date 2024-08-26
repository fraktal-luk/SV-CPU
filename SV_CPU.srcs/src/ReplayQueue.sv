
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
    input OpPacket inPackets[N_MEM_PORTS],
    output OpPacket outPacket
);

    localparam int SIZE = 16;

    typedef struct {
        logic used;
        logic active;
        logic ready;
        InsId id;
    } Entry;

    localparam Entry EMPTY_ENTRY = '{0, 0, 0, -1};

    int numUsed = 0;
    logic accept;
    Entry content[SIZE] = '{default: EMPTY_ENTRY};

    Entry selected = EMPTY_ENTRY;


    typedef int InputLocs[N_MEM_PORTS];
    InputLocs inLocs = '{default: -1};

    function automatic InputLocs getInputLocs();
        InputLocs res = '{default: -1};
        int nFound = 0;

        foreach (content[i])
            if (!content[i].used) res[nFound++] = i;

        return res;
    endfunction


    OpPacket issued1 = EMPTY_OP_PACKET, issued0 = EMPTY_OP_PACKET, issued0__ = EMPTY_OP_PACKET;


    always @(posedge clk) begin
        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
           flush();
        end
        
        
        issue();
        
        if (!(lateEventInfo.redirect || branchEventInfo.redirect))
            writeInput();
        
       
        removeIssued();

        
          issued0__ <= tickP(inPackets[0]);
          issued0__.status <= ES_OK;

        issued1 <= tickP(issued0);
        
        numUsed <= getNumUsed();
    end


    task automatic writeInput();
        inLocs = getInputLocs();
        
        foreach (inPackets[i]) begin
            if (!inPackets[i].active) continue;
            content[inLocs[i]] = '{inPackets[i].active, inPackets[i].active, inPackets[i].active, inPackets[i].id};
            putMilestone(inPackets[i].id, InstructionMap::RqEnter);
        end
    endtask



    task automatic removeIssued();
        foreach (content[i]) begin
            if (content[i].used && !content[i].active) begin
                putMilestone(content[i].id, InstructionMap::RqExit);
                content[i] = EMPTY_ENTRY;
            end
        end
    endtask


    task automatic issue();
        OpPacket newPacket = EMPTY_OP_PACKET;
    
        selected <= EMPTY_ENTRY;

        foreach (content[i]) begin
            if (content[i].active && content[i].ready) begin
                selected <= content[i];
                
                newPacket = '{1, content[i].id, ES_OK, EMPTY_POISON, 'x, 'x};
                
                putMilestone(content[i].id, InstructionMap::RqIssue);
                content[i].active = 0;
                break;
            end
        end
           
        issued0 <= tickP(newPacket);
    endtask


    task automatic flush();
        foreach (content[i]) begin
            if (lateEventInfo.redirect || (branchEventInfo.redirect && content[i].id > branchEventInfo.op.id)) begin
                if (content[i].used) putMilestone(content[i].id, InstructionMap::RqFlush);
                content[i] = EMPTY_ENTRY;
            end
        end
        
        if (lateEventInfo.redirect || (branchEventInfo.redirect && selected.id > branchEventInfo.op.id)) begin
            selected = EMPTY_ENTRY;
        end
    endtask

    function automatic int getNumUsed();
        int res = 0;
        
        foreach (content[i]) if (content[i].used) res++;
        
        return res;
    endfunction



    assign accept = numUsed < SIZE - 5;
    assign outPacket = effP(issued0);

endmodule
