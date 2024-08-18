
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;


module RegularSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpPacket opP
);
    Word result = 'x;

    OpPacket p0, p1 = EMPTY_OP_PACKET, pE0 = EMPTY_OP_PACKET, pD0 = EMPTY_OP_PACKET, pD1 = EMPTY_OP_PACKET;
    OpPacket p0_E, p1_E, pE0_E, pD0_E, pD1_E;

    OpPacket stage0, stage0_E;

    assign stage0 = setResult(pE0, result);
    assign stage0_E = setResult(pE0_E, result);

    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        pE0 <= tickP(p1);
        pD0 <= tickP(pE0);
        pD1 <= tickP(pD0);

        result <= 'x;
        if (p1_E.active) result <= calcRegularOp(p1_E.id);

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
    input OpPacket opP
);
    Word result = 'x;

    OpPacket p0, p1 = EMPTY_OP_PACKET, pE0 = EMPTY_OP_PACKET, pD0 = EMPTY_OP_PACKET, pD1 = EMPTY_OP_PACKET;
    OpPacket p0_E, p1_E, pE0_E, pD0_E, pD1_E;

    OpPacket stage0, stage0_E;
    
    assign stage0 = setResult(pE0, result);
    assign stage0_E = setResult(pE0_E, result);

    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        pE0 <= tickP(p1);
        pD0 <= tickP(pE0);
        pD1 <= tickP(pD0);

        runExecBranch(p1_E.active, p1_E.id);
        result <= getBranchResult(p1_E.active, p1_E.id);
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



module ExecBlock(ref InstructionMap insMap,
                input EventInfo branchEventInfo,
                input EventInfo lateEventInfo
);
    OpPacket doneRegular0;
    OpPacket doneRegular1;

    OpPacket doneBranch;
    
    OpPacket doneMem0;
    OpPacket doneMem2;
    
    OpPacket doneFloat0;
    OpPacket doneFloat1; 
    
    OpPacket doneSys = EMPTY_OP_PACKET;
    

    OpPacket doneRegular0_E;
    OpPacket doneRegular1_E;

    OpPacket doneBranch_E;
    
    OpPacket doneMem0_E;
    OpPacket doneMem2_E;
    
    OpPacket doneFloat0_E;
    OpPacket doneFloat1_E; 
    
    OpPacket doneSys_E;


    DataReadReq readReqs[N_MEM_PORTS];
    DataReadResp readResps[N_MEM_PORTS];
    
    
    OpPacket issuedReplayQueue;
        

    // Int 0
    RegularSubpipe regular0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedRegularP[0]
    );
    
    // Int 1
    RegularSubpipe regular1(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedRegularP[1]
    );
    
    // Int 2
    BranchSubpipe branch0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedBranchP[0]
    );
    
    // Mem 0
    MemSubpipe mem0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedMemP[0],
            readReqs[0],
            readResps[0]
    );


    // Mem 2 - for ReplayQueue only!
    MemSubpipe mem2(
        insMap,
        branchEventInfo,
        lateEventInfo,
        issuedReplayQueue,
            readReqs[2],
            readResps[2]
    );


    // Vec 0
    RegularSubpipe float0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedFloatP[0]
    );
    
    // Vec 1
    RegularSubpipe float1(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedFloatP[1]
    );

    always @(posedge AbstractCore.clk) begin
       doneSys <= tickP(theIssueQueues.issuedSysP[0]);
    end

    assign doneSys_E = effP(doneSys);


    ReplayQueue replayQueue(
        insMap,
        AbstractCore.clk,
        branchEventInfo,
        lateEventInfo,
        EMPTY_OP_PACKET,
        issuedReplayQueue
    );
    




    assign doneRegular0 = regular0.stage0;
    assign doneRegular1 = regular1.stage0;
    assign doneBranch = branch0.stage0;
    assign doneMem0 = mem0.stage0;
    assign doneMem2 = mem2.stage0;
    assign doneFloat0 = float0.stage0;
    assign doneFloat1 = float1.stage0;

    assign doneRegular0_E = regular0.stage0_E;
    assign doneRegular1_E = regular1.stage0_E;
    assign doneBranch_E = branch0.stage0_E;
    assign doneMem0_E = mem0.stage0_E;
    assign doneMem2_E = mem2.stage0_E;
    assign doneFloat0_E = float0.stage0_E;
    assign doneFloat1_E = float1.stage0_E;


    ForwardingElement intImages[N_INT_PORTS][-3:1];
    ForwardingElement memImages[N_MEM_PORTS][-3:1];
    ForwardingElement floatImages[N_VEC_PORTS][-3:1];

    IntByStage intImagesTr;
    MemByStage memImagesTr;
    VecByStage floatImagesTr;

    ForwardsByStage_0 allByStage;

    assign intImages = '{0: regular0.image_E, 1: regular1.image_E, 2: branch0.image_E, default: EMPTY_IMAGE};
    assign memImages = '{0: mem0.image_E, default: EMPTY_IMAGE};
    assign floatImages = '{0: float0.image_E, 1: float1.image_E, default: EMPTY_IMAGE};

    assign intImagesTr = trsInt(intImages);
    assign memImagesTr = trsMem(memImages);
    assign floatImagesTr = trsVec(floatImages);

    assign allByStage.ints = intImagesTr;
    assign allByStage.mems = memImagesTr;
    assign allByStage.vecs = floatImagesTr;


    // TOPLEVEL
    function automatic Word calcRegularOp(input InsId id);
        AbstractInstruction abs = decId(id);
                                
        Word3 args = getAndVerifyArgs(id);
        Word adr = getAdr(id);
        Word result = calculateResult(abs, args, adr);
        
        insMap.setActualResult(id, result);
        
        return result;
    endfunction

    // TOPLEVEL
    task automatic runExecBranch(input logic active, input InsId id);
        AbstractCore.branchEventInfo <= EMPTY_EVENT_INFO;
        if (!active) return;
        insMap.setActualResult(id, getBranchResult(1, id));

        setBranchInCore(id);
        putMilestone(id, InstructionMap::ExecRedirect);
    endtask

    function automatic Word getBranchResult(input logic active, input InsId id);
        if (!active) return 'x;
        else begin
            Word adr = getAdr(id);
            return adr + 4;
        end
    endfunction

    task automatic setBranchInCore(input InsId id);
        OpSlot wholeOp = getOpSlotFromId(id);
        AbstractInstruction abs = decId(id);
        Word3 args = getAndVerifyArgs(id);
        Word adr = getAdr(id);

        ExecEvent evt = resolveBranch(abs, adr, args);
        BranchCheckpoint found[$] = AbstractCore.branchCheckpointQueue.find with (item.op.id == id);
        
        int ind[$] = AbstractCore.branchTargetQueue.find_first_index with (item.id == id);
        Word trg = evt.redirect ? evt.target : adr + 4;
        
        AbstractCore.branchTargetQueue[ind[0]].target = trg;
        AbstractCore.branchCP = found[0];
        AbstractCore.branchEventInfo <= '{wholeOp, 0, 0, evt.redirect, 0, 0, evt.target}; // TODO: use function to create it
    endtask



    // Used before Exec0 to get final values
    function automatic Word3 getAndVerifyArgs(input InsId id);
        InsDependencies deps = insMap.get(id).deps;
        Word3 argsP = getArgValues(AbstractCore.registerTracker, deps);
        Word3 argsM = insMap.get(id).argValues;
        
        if (argsP !== argsM) insMap.setArgError(id);
        
        return argsP;
    endfunction;


    // Used once
    function automatic Word3 getArgValues(input RegisterTracker tracker, input InsDependencies deps);
        ForwardsByStage_0 fws = allByStage;
        Word res[3];
        logic3 ready = checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);
                    
        foreach (deps.types[i]) begin
            case (deps.types[i])
                SRC_ZERO:  res[i] = 0;
                SRC_CONST: res[i] = deps.sources[i];
                SRC_INT:   res[i] = getArgValueInt(insMap, tracker, deps.producers[i], deps.sources[i], fws, ready[i]);
                SRC_FLOAT: res[i] = getArgValueVec(insMap, tracker, deps.producers[i], deps.sources[i], fws, ready[i]);
            endcase
        end

        return res;
    endfunction


endmodule




module CoreDB();

    int insMapSize = 0, trSize = 0, nCompleted = 0, nRetired = 0; // DB

    OpSlot lastRenamed = EMPTY_SLOT, lastCompleted = EMPTY_SLOT, lastRetired = EMPTY_SLOT;
    string lastRenamedStr, lastCompletedStr, lastRetiredStr;

    string bqStr;
    always @(posedge AbstractCore.clk) begin
        automatic int ids[$];
        foreach (AbstractCore.branchCheckpointQueue[i]) ids.push_back(AbstractCore.branchCheckpointQueue[i].op.id);
        $swrite(bqStr, "%p", ids);
    end

        assign lastRenamedStr = disasm(lastRenamed.bits);
        assign lastCompletedStr = disasm(lastCompleted.bits);
        assign lastRetiredStr = disasm(lastRetired.bits);

    logic cmp0, cmp1;
    Word cmpw0, cmpw1, cmpw2, cmpw3;
   
endmodule
