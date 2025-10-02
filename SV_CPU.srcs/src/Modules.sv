
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

    assign stage0_E = pE0_E;

    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        pE0 <= performRegularE0(tickP(p1));
        pD0 <= tickP(pE0);
        pD1 <= tickP(pD0);
    end

    always_comb p0_E = effP(p0);
    always_comb p1_E = effP(p1);
    always_comb pE0_E = effP(pE0);
    always_comb pD0_E = effP(pD0);

    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -2: p0_E,
        -1: p1_E,
        0: pE0_E,
        1: pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };

endmodule




module MultiplierSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input UopPacket opP
);
    UopPacket p0, p1 = EMPTY_UOP_PACKET, pE0 = EMPTY_UOP_PACKET, pE1 = EMPTY_UOP_PACKET, pE2 = EMPTY_UOP_PACKET, pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
    UopPacket p0_E, p1_E, pE0_E, pE1_E, pE2_E, pD0_E, pD1_E;
    UopPacket stage0, stage0_E;

    assign stage0_E = pE2_E;

    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        pE0 <= performRegularE0(tickP(p1));
        pE1 <= (tickP(pE0));
        pE2 <= (tickP(pE1));
        pD0 <= tickP(pE2);
        pD1 <= tickP(pD0);
    end

    always_comb p0_E = effP(p0);
    always_comb p1_E = effP(p1);
    always_comb pE0_E = effP(pE0);
    always_comb pE1_E = effP(pE1);
    always_comb pE2_E = effP(pE2);
    always_comb pD0_E = effP(pD0);

    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -2: pE0_E,
        -1: pE1_E,
        0: pE2_E,
        1: pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };

endmodule



module FloatSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input UopPacket opP
);
    UopPacket p0, p1 = EMPTY_UOP_PACKET, pE0 = EMPTY_UOP_PACKET, pE1 = EMPTY_UOP_PACKET, pE2 = EMPTY_UOP_PACKET, pE3 = EMPTY_UOP_PACKET, pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
    UopPacket p0_E, p1_E, pE0_E, pE1_E, pE2_E, pE3_E, pD0_E, pD1_E;
    UopPacket stage0, stage0_E;

    assign stage0_E = pE3_E;

    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        pE0 <= performFP(tickP(p1));
        pE1 <= (tickP(pE0));
        pE2 <= (tickP(pE1));
        pE3 <= (tickP(pE2));
        pD0 <= tickP(pE3);
        pD1 <= tickP(pD0);
    end

    always_comb p0_E = effP(p0);
    always_comb p1_E = effP(p1);
    always_comb pE0_E = effP(pE0);
    always_comb pE1_E = effP(pE1);
    always_comb pE2_E = effP(pE2);
    always_comb pE3_E = effP(pE3);
    always_comb pD0_E = effP(pD0);

    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -2: pE1_E,
        -1: pE2_E,
        0: pE3_E,
        1: pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };


    function automatic UopPacket performFP(input UopPacket p);        
        UopPacket res = performRegularE0(p);
        
        if (p.TMP_oid == UIDT_NONE) return res;
        
        if (decUname(p.TMP_oid) == UOP_fp_inv) res.status = ES_FP_INVALID;
        else if (decUname(p.TMP_oid) == UOP_fp_ov) res.status = ES_FP_OVERFLOW;
        
        return res;
    endfunction

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


    assign stage0_E = pE0_E;
                      
    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);   
        pE0 <= performBranchE0(tickP(p1));
        pD0 <= tickP(pE0);
        pD1 <= tickP(pD0);

        runExecBranch(p1_E.active, p1_E.TMP_oid);

    end

    always_comb p0_E = effP(p0);
    always_comb p1_E = effP(p1);
    always_comb pE0_E = effP(pE0);
    always_comb pD0_E = effP(pD0);

    ForwardingElement image_E[-3:1];
    
    // Copied from RegularSubpipe
    assign image_E = '{
        -2: p0_E,
        -1: p1_E,
        0: pE0_E,
        1: pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };
    

    // TOPLEVEL
    function automatic UopPacket performBranchE0(input UopPacket p);
        if (!p.active) return p;
        begin
            UidT uid = p.TMP_oid;
            Mword3 args = getAndVerifyArgs(uid);
            p.result = resolveBranchDirection(decUname(uid), args[0]);// reg
        end
        return p;
    endfunction
    

    task automatic runExecBranch(input logic active, input UidT uid);
        AbstractCore.branchEventInfo <= EMPTY_EVENT_INFO;

        if (!active) return;

        setBranchInCore(uid);
        putMilestone(uid, InstructionMap::ExecRedirect);
    endtask


    task automatic setBranchInCore(input UidT uid);
        UopName uname = decUname(uid);
        Mword3 args = insMap.getU(uid).argsA;
        Mword adr = getAdr(U2M(uid));
        Mword takenTrg = takenTarget(uname, adr, args); // reg or stored in BQ
        
        logic predictedDir = insMap.get(U2M(uid)).frontBranch;
        logic dir = resolveBranchDirection(uname, args[0]);// reg
        logic redirect = predictedDir ^ dir;
        
        Mword expectedTrg = dir ? takenTrg : adr + 4;
        Mword resolvedTarget = finalTarget(uname, dir, args[1], AbstractCore.theBq.submod.lookupTarget, AbstractCore.theBq.submod.lookupLink);
        
        assert (resolvedTarget === expectedTrg) else $error("Branch target wrong!");
        assert (!$isunknown(predictedDir)) else $fatal(2, "Front branch info not in insMap");

        if (redirect) putMilestoneM(U2M(uid), InstructionMap::ExecRedirect);

        AbstractCore.branchEventInfo <= '{1, U2M(uid), CO_none, redirect, adr, resolvedTarget};
    endtask

endmodule



module DividerSubpipe#(
    parameter logic IS_FP = 0
)
(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input UopPacket opP
);

    localparam integer CONST_CYCLES = 9;

    UopPacket p0, p1 = EMPTY_UOP_PACKET,
              pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
    UopPacket p0_E, p1_E,
                pD0_E, pD1_E;
    UopPacket stage0, stage0_E;

    UopPacket mainStage = EMPTY_UOP_PACKET,
              outputStage0 = EMPTY_UOP_PACKET, // corresponds to pE{n} where n = CONST_CYCLES
              outputStage1 = EMPTY_UOP_PACKET,
              outputStage2 = EMPTY_UOP_PACKET,
              outputStage0_E, outputStage1_E, outputStage2_E, 
              mainStage_E;
    integer cnt = -1;


    assign stage0_E = outputStage2_E;
    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
       
        pD0 <= tickP(outputStage2);
        pD1 <= tickP(pD0);
    end



    always @(posedge AbstractCore.clk) begin
        
        if (p1_E.active) begin
            mainStage <= performRegularE0(p1_E); // New uop enters
            cnt <= 0;
        end
        else if (cnt == CONST_CYCLES-1) begin  // End of work for current uop
            mainStage <= EMPTY_UOP_PACKET;
            cnt <= -1;
        end
        else if (mainStage_E.active) begin
            cnt <= cnt + 1;
        end
        else begin
            mainStage <= EMPTY_UOP_PACKET;
            cnt <= -1;
        end
        
        
        if (cnt == CONST_CYCLES-1) outputStage0 <= tickP(mainStage);
        else outputStage0 <= EMPTY_UOP_PACKET;
        
        
        outputStage1 <= tickP(outputStage0);
        outputStage2 <= tickP(outputStage1);
    end


    logic lock = 0;
    logic empty, allowIssue, opSelected;

    assign opSelected = IS_FP ? theIssueQueues.fdivQueue.anySelected && theIssueQueues.fdivQueue.allow : theIssueQueues.dividerQueue.anySelected && theIssueQueues.dividerQueue.allow;

    // TODO: exclude outputStages from this because they don't need to be empty when mainStage gets another op
    assign empty = !(p0.active || p1.active || mainStage.active       || outputStage0.active || outputStage1.active || outputStage2.active
                    );

    // allow signal for divider IQ
    always @(posedge AbstractCore.clk) begin
        
        if (opSelected) lock <= 1;
        else if (empty) lock <= 0;
        
    end
    
    assign allowIssue = !lock;
    

    always_comb p0_E = effP(p0);
    always_comb p1_E = effP(p1);

    always_comb mainStage_E = effP(mainStage);

    always_comb outputStage0_E = effP(outputStage0);
    always_comb outputStage1_E = effP(outputStage1);
    always_comb outputStage2_E = effP(outputStage2);
    
    always_comb pD0_E = effP(pD0);

    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -2: outputStage0_E,
        -1: outputStage1_E,
        0: outputStage2_E,
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

    assign stage0_E = pE0_E;

    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        pE0 <= performStoreData(tickP(p1));
        pD0 <= tickP(pE0);
        pD1 <= tickP(pD0);
    end

    always_comb p0_E = effP(p0);
    always_comb p1_E = effP(p1);
    always_comb pE0_E = effP(pE0);
    always_comb pD0_E = effP(pD0);

    ForwardingElement image_E[-3:1];

    assign image_E = '{
        -2: p0_E,
        -1: p1_E,
        0: pE0_E,
        1: pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };


    function automatic UopPacket performStoreData(input UopPacket p);
        if (p.TMP_oid == UIDT_NONE) return p;

        begin
            UopPacket res = p;
            Mword3 args = getAndVerifyArgs(p.TMP_oid);
            res.result = args[2];
            return res;
        end
    endfunction

endmodule
