
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;
import Queues::*;


module RegularSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input UopPacket opP
);
    UopPacket p0, p1 = EMPTY_UOP_PACKET, pE0 = EMPTY_UOP_PACKET, pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
    UopPacket p0_E, p1_E, pE0_E, pD0_E, pD1_E;
    UopPacket stage0, stage0_E;

    assign stage0 = pE0;
    assign stage0_E = pE0_E;

    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        pE0 <= performRegularE0(tickP(p1));
        pD0 <= tickP(pE0);
        pD1 <= tickP(pD0);
    end

    assign p0_E = effP(p0);
    assign p1_E = effP(p1);
    assign pE0_E = effP(pE0);
    assign pD0_E = effP(pD0);

    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -2: p0_E,
        -1: p1_E,
        0: pE0_E,
        1: pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };

endmodule


module BranchSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input UopPacket opP
);
    UopPacket p0, p1 = EMPTY_UOP_PACKET, pE0 = EMPTY_UOP_PACKET, pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
    UopPacket p0_E, p1_E, pE0_E, pD0_E, pD1_E;
    UopPacket stage0, stage0_E;


    assign stage0 = pE0;
    assign stage0_E = pE0_E;
                      
    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);   
        pE0 <= performBranchE0(tickP(p1));
        pD0 <= tickP(pE0);
        pD1 <= tickP(pD0);

        runExecBranch(p1_E.active, p1_E.TMP_oid);

    end

    assign p0_E = effP(p0);
    assign p1_E = effP(p1);
    assign pE0_E = effP(pE0);
    assign pD0_E = effP(pD0);

    ForwardingElement image_E[-3:1];
    
    // Copied from RegularSubpipe
    assign image_E = '{
        -2: p0_E,
        -1: p1_E,
        0: pE0_E,
        1: pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };
endmodule



module StoreDataSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input UopPacket opP
);
    UopPacket p0, p1 = EMPTY_UOP_PACKET, pE0 = EMPTY_UOP_PACKET, pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
    UopPacket p0_E, p1_E, pE0_E, pD0_E, pD1_E;
    UopPacket stage0, stage0_E;

    assign stage0 = pE0;
    assign stage0_E = pE0_E;

    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        pE0 <= performStoreData(tickP(p1));
        pD0 <= tickP(pE0);
        pD1 <= tickP(pD0);
    end

    assign p0_E = effP(p0);
    assign p1_E = effP(p1);
    assign pE0_E = effP(pE0);
    assign pD0_E = effP(pD0);

    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -2: p0_E,
        -1: p1_E,
        0: pE0_E,
        1: pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };

endmodule
