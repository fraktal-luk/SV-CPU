
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
    input OpPacket opP
);
    Mword result = 'x;

    OpPacket p0, p1 = EMPTY_OP_PACKET, pE0 = EMPTY_OP_PACKET, pD0 = EMPTY_OP_PACKET, pD1 = EMPTY_OP_PACKET;
    OpPacket p0_E, p1_E, pE0_E, pD0_E, pD1_E;

    OpPacket stage0, stage0_E;

    assign stage0 = setResult(pE0, result);
    assign stage0_E = setResult(pE0_E, result);

    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        
        pE0 <= performRegularE0(tickP(p1));
        
        result <= 'x;
        if (p1_E.active) result <= calcRegularOp(p1_E.id);
        
        
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
    input OpPacket opP
);
    Mword result = 'x;

    OpPacket p0, p1 = EMPTY_OP_PACKET, pE0 = EMPTY_OP_PACKET, pD0 = EMPTY_OP_PACKET, pD1 = EMPTY_OP_PACKET;
    OpPacket p0_E, p1_E, pE0_E, pD0_E, pD1_E;

    OpPacket stage0, stage0_E;
    
        BranchQueueHelper::Entry inputEntry = BranchQueueHelper::EMPTY_QENTRY;;
    
    assign stage0 = setResult(pE0, result);
    assign stage0_E = setResult(pE0_E, result);

    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        
            inputEntry <= AbstractCore.theBq.getEntry(p0_E);
        
        pE0 <= performBranchE0(tickP(p1));
        
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
    OpPacket doneRegular0, doneRegular1;
    OpPacket doneBranch;
    
    OpPacket doneMem0, doneMem2;
    
    OpPacket doneFloat0,  doneFloat1; 
    
    OpPacket doneSys = EMPTY_OP_PACKET;
    

    OpPacket doneRegular0_E, doneRegular1_E;
    OpPacket doneBranch_E;
    
    OpPacket doneMem0_E, doneMem2_E;
    
    OpPacket doneFloat0_E, doneFloat1_E; 
    
    OpPacket doneSys_E;


    DataReadReq readReqs[N_MEM_PORTS];
    DataReadResp readResps[N_MEM_PORTS];
    
    logic TMP_memAllow;
    
    OpPacket issuedReplayQueue;
    
    OpPacket toReplayQueue0, toReplayQueue2;
    OpPacket toReplayQueue[N_MEM_PORTS];

    OpPacket toLq[N_MEM_PORTS];
    OpPacket toSq[N_MEM_PORTS];
    OpPacket toBq[N_MEM_PORTS]; // TODO: Customize this width in MemBuffer (or make whole new module for BQ)?  

    OpPacket fromSq[N_MEM_PORTS];
    OpPacket fromLq[N_MEM_PORTS];
    OpPacket fromBq[N_MEM_PORTS];


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
            readResps[0],
            fromSq[0],
            fromLq[0]
    );


    // Mem 2 - for ReplayQueue only!
    MemSubpipe#(.HANDLE_UNALIGNED(1))
    mem2(
        insMap,
        branchEventInfo,
        lateEventInfo,
        issuedReplayQueue,
            readReqs[2],
            readResps[2],
            fromSq[2],
            fromLq[2]
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

    assign readReqs[1] = EMPTY_READ_REQ;
    assign readReqs[3] = EMPTY_READ_REQ;


    always @(posedge AbstractCore.clk) begin
       doneSys <= tickP(theIssueQueues.issuedSysP[0]);
    end

    assign doneSys_E = effP(doneSys);


    ReplayQueue replayQueue(
        insMap,
        AbstractCore.clk,
        branchEventInfo,
        lateEventInfo,
        toReplayQueue,
        issuedReplayQueue
    );
    

    assign TMP_memAllow = replayQueue.accept;


    function automatic OpPacket memToComplete(input OpPacket p);
        if (!(p.status inside {ES_OK, ES_REDO})) return EMPTY_OP_PACKET;
        else return p;
    endfunction

    function automatic OpPacket memToReplay(input OpPacket p);
        if (!(p.status inside {ES_OK, ES_REDO})) return p;
        else return EMPTY_OP_PACKET;
    endfunction



    assign doneRegular0 = regular0.stage0;
    assign doneRegular1 = regular1.stage0;
    assign doneBranch = branch0.stage0;
    
    assign doneMem0 = memToComplete(mem0.stage0);
    assign doneMem2 = memToComplete(mem2.stage0);
    
    assign doneFloat0 = float0.stage0;
    assign doneFloat1 = float1.stage0;

    assign doneRegular0_E = regular0.stage0_E;
    assign doneRegular1_E = regular1.stage0_E;
    assign doneBranch_E = branch0.stage0_E;
    
    assign doneMem0_E = memToComplete(mem0.stage0_E);
    assign doneMem2_E = memToComplete(mem2.stage0_E);
    
    assign doneFloat0_E = float0.stage0_E;
    assign doneFloat1_E = float1.stage0_E;


    assign toReplayQueue0 = memToReplay(mem0.stage0_E);
    assign toReplayQueue2 = memToReplay(mem2.stage0_E);
    
    assign toReplayQueue = '{0: toReplayQueue0, 2: toReplayQueue2, default: EMPTY_OP_PACKET};
    
    assign toLq = '{0: mem0.pE0_E, 2: mem2.pE0_E, default: EMPTY_OP_PACKET};
    assign toSq = toLq;

    assign toBq = '{0: branch0.pE0_E, default: EMPTY_OP_PACKET};


    ForwardingElement intImages[N_INT_PORTS][-3:1];
    ForwardingElement memImages[N_MEM_PORTS][-3:1];
    ForwardingElement floatImages[N_VEC_PORTS][-3:1];

    IntByStage intImagesTr;
    MemByStage memImagesTr;
    VecByStage floatImagesTr;

    ForwardsByStage_0 allByStage;

    assign intImages = '{0: regular0.image_E, 1: regular1.image_E, 2: branch0.image_E, default: EMPTY_IMAGE};
    assign memImages = '{0: mem0.image_E, 2: mem2.image_E, default: EMPTY_IMAGE};
    assign floatImages = '{0: float0.image_E, 1: float1.image_E, default: EMPTY_IMAGE};

    assign intImagesTr = trsInt(intImages);
    assign memImagesTr = trsMem(memImages);
    assign floatImagesTr = trsVec(floatImages);

    assign allByStage.ints = intImagesTr;
    assign allByStage.mems = memImagesTr;
    assign allByStage.vecs = floatImagesTr;



    function automatic OpPacket performRegularE0(input OpPacket p);
        if (p.id == -1) return p;
        begin
            OpPacket res = p;
            res.result = calcRegularOp(p.id);
            
            return res;
        end
    endfunction

    // TOPLEVEL
    function automatic Mword calcRegularOp(input InsId id);
        AbstractInstruction abs = decId(id);
                                
        Mword3 args = getAndVerifyArgs(id);
        Mword adr = getAdr(id);
        Mword result = calculateResult(abs, args, adr);
        
        insMap.setActualResult(id, result);
        
        return result;
    endfunction



    function automatic OpPacket performBranchE0(input OpPacket p);
        if (p.id == -1) return p;
        begin
            OpPacket res = p;
            res.result = getBranchResult(p.active, p.id);
            
            return res;
        end
    endfunction

    // TOPLEVEL
    task automatic runExecBranch(input logic active, input InsId id);
        AbstractCore.branchEventInfo <= EMPTY_EVENT_INFO;
        if (!active) return;
        insMap.setActualResult(id, getBranchResult(1, id));

        setBranchInCore(id);
        putMilestone(id, InstructionMap::ExecRedirect);
    endtask

    function automatic Mword getBranchResult(input logic active, input InsId id);
        if (!active) return 'x;
        else begin
            Mword adr = getAdr(id);
            return adr + 4;
        end
    endfunction

    task automatic setBranchInCore(input InsId id);
        OpSlot wholeOp = getOpSlotFromId(id);
        AbstractInstruction abs = decId(id);
        Mword3 args = getAndVerifyArgs(id);
        Mword adr = getAdr(id);

        ExecEvent evt = resolveBranch(abs, adr, args);
        BranchCheckpoint found[$] = AbstractCore.branchCheckpointQueue.find with (item.op.id == id);
        
        int ind[$] = AbstractCore.branchTargetQueue.find_first_index with (item.id == id);
        Mword trg = evt.redirect ? evt.target : adr + 4;
        
        AbstractCore.branchTargetQueue[ind[0]].target = trg;
        AbstractCore.branchCP = found[0];
        AbstractCore.branchEventInfo <= '{wholeOp, CO_none, 0, 0, evt.redirect, 0, 0, evt.target};
    endtask



    // Used before Exec0 to get final values
    function automatic Mword3 getAndVerifyArgs(input InsId id);
        InsDependencies deps = insMap.get(id).deps;
        Mword3 argsP = getArgValues(AbstractCore.registerTracker, deps);
        Mword3 argsM = insMap.get(id).argValues;
        
        if (argsP !== argsM) insMap.setArgError(id);
        
        return argsP;
    endfunction;


    // Used once
    function automatic Mword3 getArgValues(input RegisterTracker tracker, input InsDependencies deps);
        ForwardsByStage_0 fws = allByStage;
        Mword res[3];
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

    OpSlot lastRenamed = EMPTY_SLOT, lastCompleted = EMPTY_SLOT, lastRetired = EMPTY_SLOT, lastRefetched = EMPTY_SLOT;
    string lastRenamedStr, lastCompletedStr, lastRetiredStr, lastRefetchedStr;

    string bqStr;
    always @(posedge AbstractCore.clk) begin
        automatic int ids[$];
        foreach (AbstractCore.branchCheckpointQueue[i]) ids.push_back(AbstractCore.branchCheckpointQueue[i].op.id);
        $swrite(bqStr, "%p", ids);
    end

        assign lastRenamedStr = disasm(lastRenamed.bits);
        assign lastCompletedStr = disasm(lastCompleted.bits);
        assign lastRetiredStr = disasm(lastRetired.bits);
        assign lastRefetchedStr = disasm(lastRefetched.bits);

    logic cmp0, cmp1;
    Mword cmpmw0, cmpmw1, cmpmw2, cmpmw3;
   
endmodule
