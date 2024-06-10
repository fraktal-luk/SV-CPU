
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;


package ExecDefs;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    
    import AbstractSim::*;


    localparam int N_INT_PORTS = 4;
    localparam int N_MEM_PORTS = 4;
    localparam int N_VEC_PORTS = 4;

    typedef logic ReadyVec[OP_QUEUE_SIZE];
    typedef logic ReadyVec3[OP_QUEUE_SIZE][3];

    typedef struct {
        InsId id;
    } ForwardingElement;

    localparam ForwardingElement EMPTY_FORWARDING_ELEMENT = '{id: -1}; 

    typedef struct {
        ForwardingElement pipesInt[N_INT_PORTS];
        
        ForwardingElement subpipe0[-3:1];
        
        InsId regular1;
        InsId branch0;
        InsId mem0;
        
        InsId float0;
        InsId float1;
    } Forwarding_0;

    localparam ForwardingElement EMPTY_IMAGE[-3:1] = '{default: EMPTY_FORWARDING_ELEMENT};
    
    typedef ForwardingElement IntByStage[-3:1][N_INT_PORTS];
    typedef ForwardingElement MemByStage[-3:1][N_MEM_PORTS];
    typedef ForwardingElement VecByStage[-3:1][N_VEC_PORTS];


    function automatic IntByStage trsInt(input ForwardingElement imgs[N_INT_PORTS][-3:1]);
        IntByStage res;
        
        foreach (imgs[p]) begin
            ForwardingElement img[-3:1] = imgs[p];
            foreach (img[s])
                res[s][p] = img[s];
        end
        
        return res;
    endfunction

    function automatic MemByStage trsMem(input ForwardingElement imgs[N_MEM_PORTS][-3:1]);
        MemByStage res;
        
        foreach (imgs[p]) begin
            ForwardingElement img[-3:1] = imgs[p];
            foreach (img[s])
                res[s][p] = img[s];
        end
        
        return res;
    endfunction

    function automatic VecByStage trsVec(input ForwardingElement imgs[N_VEC_PORTS][-3:1]);
        VecByStage res;
        
        foreach (imgs[p]) begin
            ForwardingElement img[-3:1] = imgs[p];
            foreach (img[s])
                res[s][p] = img[s];
        end
        
        return res;
    endfunction

endpackage

import ExecDefs::*;


module RegularSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpSlot op0
);

    OpSlot op0_E, op1 = EMPTY_SLOT, op_E;
    OpSlot doneOp = EMPTY_SLOT, doneOpD0 = EMPTY_SLOT;;
    OpSlot doneOp_E, doneOpD0_E;
    Word result = 'x;

    always @(posedge AbstractCore.clk) begin
        op1 <= tick(op0);

        result <= 'x;
    
        if (op_E.active)
            result <= calcRegularOp(op_E);
        doneOp <= tick(op1);
        doneOpD0 <= tick(doneOp);
    end

    assign op0_E = eff(op0);
    assign op_E = eff(op1);
    assign doneOp_E = eff(doneOp);
    assign doneOpD0_E = eff(doneOpD0);

    function automatic OpSlot forward(input int stage);
        case (stage)
            -2: return op0_E;
            -1: return op_E;
            0:  return doneOp_E;
            1:  return doneOpD0_E;
            default: return EMPTY_SLOT;
        endcase
    endfunction 


    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -2: '{id: op0_E.id},
        -1: '{id: op_E.id},
        0: '{id:  doneOp_E.id},
        1: '{id:  doneOpD0_E.id},
        default: EMPTY_FORWARDING_ELEMENT
    };

endmodule


module BranchSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpSlot op0
);

    OpSlot op0_E, op1 = EMPTY_SLOT, op_E;
    OpSlot doneOp = EMPTY_SLOT, doneOpD0 = EMPTY_SLOT;;
    OpSlot doneOp_E, doneOpD0_E;
    Word result = 'x;

    always @(posedge AbstractCore.clk) begin
        op1 <= tick(op0);

        result <= 'x;
    
        runExecBranch(op_E);
        
        if (op_E.active) begin
            insMap.setActualResult(op_E.id, op_E.adr + 4);
            result <= op_E.adr + 4;
        end
        
        doneOp <= tick(op1);
        doneOpD0 <= tick(doneOp);
    end

    assign op0_E = eff(op0);
    assign op_E = eff(op1);
    assign doneOp_E = eff(doneOp);
    assign doneOpD0_E = eff(doneOpD0);

    function automatic OpSlot forward(input int stage);
        case (stage)
            -2: return op0_E;
            -1: return op_E;
            0:  return doneOp_E;
            1:  return doneOpD0_E;
            default: return EMPTY_SLOT;
        endcase
    endfunction
    
    ForwardingElement image_E[-3:1];
    
    // Copied from RegularSubpipe
    assign image_E = '{
        -2: '{id: op0_E.id},
        -1: '{id: op_E.id},
        0: '{id:  doneOp_E.id},
        1: '{id:  doneOpD0_E.id},
        default: EMPTY_FORWARDING_ELEMENT
    };
endmodule


module MemSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpSlot op0
);

    OpSlot op0_E, op1 = EMPTY_SLOT, op_E;
    OpSlot doneOpE0 = EMPTY_SLOT, doneOpE1 = EMPTY_SLOT, doneOpE2 = EMPTY_SLOT, doneOpD0 = EMPTY_SLOT;
    OpSlot doneOpE0_E, doneOpE1_E, doneOpE2_E, doneOpD0_E;
    Word result = 'x;

    always @(posedge AbstractCore.clk) begin
        op1 <= tick(op0);

        result <= 'x;
    
        AbstractCore.readInfo <= EMPTY_WRITE_INFO;

        if (op_E.active) performMemFirst(op_E);

        doneOpE0 <= tick(op1);
        
        doneOpE1 <= tick(doneOpE0);
        
        if (doneOpE1_E.active) begin
            result <= calcMemLater(doneOpE1_E); 
        end
        
        doneOpE2 <= tick(doneOpE1);
        doneOpD0 <= tick(doneOpE2);
    end

    assign op0_E = eff(op0);
    assign op_E = eff(op1);
    assign doneOpE0_E = eff(doneOpE0);
    assign doneOpE1_E = eff(doneOpE1);
    assign doneOpE2_E = eff(doneOpE2);
    assign doneOpD0_E = eff(doneOpD0);

    function automatic OpSlot forward(input int stage);
        case (stage)
            -4: return op0_E;
            -3: return op_E;
            -2: return doneOpE0_E;
            -1: return doneOpE1_E;
            0:  return doneOpE2_E;
            1:  return doneOpD0_E;
            default: return EMPTY_SLOT;
        endcase
    endfunction
    
    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -3: '{id: op_E.id},
        -2: '{id: doneOpE0_E.id},
        -1: '{id: doneOpE1_E.id},
        0: '{id:  doneOpE2_E.id},
        1: '{id:  doneOpD0_E.id},
        default: EMPTY_FORWARDING_ELEMENT
    };
endmodule



module ExecBlock(ref InstructionMap insMap,
                input EventInfo branchEventInfo,
                input EventInfo lateEventInfo
);
    typedef StoreQueueEntry StoreQueueExtract[$];

    IssueGroup issuedSt0;
    
    OpSlot doneOpBranch, doneOpMem, doneOpSys = EMPTY_SLOT;
    OpSlot doneOpBranch_E, doneOpMem_E, doneOpSys_E;

    OpSlot doneOpsRegular[2];
    OpSlot doneOpsRegular_E[2];
    Word execResultsRegular[2];

    OpSlot doneOpsFloat[2];
    OpSlot doneOpsFloat_E[2];
    Word execResultsFloat[2];
    Word execResultLink, execResultMem;

    // Int 0
    RegularSubpipe regular0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        issuedSt0.regular[0]
    );
    
    // Int 1
    RegularSubpipe regular1(
        insMap,
        branchEventInfo,
        lateEventInfo,
        issuedSt0.regular[1]
    );
    
    // Int 2
    BranchSubpipe branch0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        issuedSt0.branch
    );
    
    // Mem 0
    MemSubpipe mem0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        issuedSt0.mem
    );
    
    // Vec 0
    RegularSubpipe float0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        issuedSt0.float[0]
    );
    
    // Vec 1
    RegularSubpipe float1(
        insMap,
        branchEventInfo,
        lateEventInfo,
        issuedSt0.float[1]
    );


    always @(posedge AbstractCore.clk) begin
        doneOpSys <= tick(issuedSt0.sys);
    end


    assign doneOpsRegular[0] = regular0.doneOp;
    assign doneOpsRegular[1] = regular1.doneOp;
    
    assign doneOpsFloat[0] = float0.doneOp;
    assign doneOpsFloat[1] = float1.doneOp;

    assign doneOpBranch = branch0.doneOp;
    assign doneOpMem = mem0.doneOpE2;

    assign execResultsRegular[0] = regular0.result;
    assign execResultsRegular[1] = regular1.result;
    
    assign execResultsFloat[0] = float0.result;
    assign execResultsFloat[1] = float1.result;
    
    assign execResultLink = branch0.result;
    assign execResultMem = mem0.result;


    ForwardingElement intImages[N_INT_PORTS][-3:1];
    ForwardingElement memImages[N_MEM_PORTS][-3:1];
    ForwardingElement floatImages[N_VEC_PORTS][-3:1];

    IntByStage intImagesTr;
    MemByStage memImagesTr;
    VecByStage floatImagesTr;

    assign intImages = '{0: regular0.image_E, 1: regular1.image_E, 2: branch0.image_E, default: EMPTY_IMAGE};
    assign memImages = '{0: mem0.image_E, default: EMPTY_IMAGE};
    assign floatImages = '{0: float0.image_E, 1: float1.image_E, default: EMPTY_IMAGE};

    assign intImagesTr = trsInt(intImages);
    assign memImagesTr = trsMem(memImages);
    assign floatImagesTr = trsVec(floatImages);


    function automatic Word calcRegularOp(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word3 args = getAndVerifyArgs(op);
        Word result = calculateResult(abs, args, op.adr); // !!!!
        
        insMap.setActualResult(op.id, result);
        
        return result;
    endfunction


    task automatic runExecBranch(input OpSlot op);
        AbstractCore.branchEventInfo <= EMPTY_EVENT_INFO;
        if (op.active) begin
            setBranchInCore(op);
        end
    endtask

    task automatic setBranchInCore(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word3 args = getAndVerifyArgs(op);

        ExecEvent evt = resolveBranch(abs, op.adr, args);
        BranchCheckpoint found[$] = AbstractCore.branchCheckpointQueue.find with (item.op.id == op.id);
        
        int ind[$] = AbstractCore.branchTargetQueue.find_first_index with (item.id == op.id);
        Word trg = evt.redirect ? evt.target : op.adr + 4;
        
        AbstractCore.branchTargetQueue[ind[0]].target = trg;
        AbstractCore.branchCP = found[0];
        AbstractCore.branchEventInfo <= '{op, 0, 0, evt.redirect, evt.target};
    endtask


    task automatic performMemFirst(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word3 args = getAndVerifyArgs(op);
        Word adr = calculateEffectiveAddress(abs, args);

        // TODO: compare adr with that in memTracker
        if (isStoreIns(decAbs(op))) begin
            updateSQ(op.id, adr, args[2]);
            
            if (isStoreMemIns(decAbs(op))) begin
                checkStoreValue(op.id, adr, args[2]);
                
                putMilestone(op.id, InstructionMap::WriteMemAddress);
                putMilestone(op.id, InstructionMap::WriteMemValue);
            end
        end

        AbstractCore.readInfo <= '{1, adr, 'x};
    endtask


    function automatic Word calcMemLater(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word3 args = getAndVerifyArgs(op);

        Word adr = calculateEffectiveAddress(abs, args);

        StoreQueueEntry matchingStores[$] = getMatchingStores(op, adr);
        // Get last (youngest) of the matching stores
        Word memData = (matchingStores.size() != 0) ? matchingStores[$].val : AbstractCore.readIn[0];
        Word data = isLoadSysIns(abs) ? getSysReg(args[1]) : memData;
    
        if (matchingStores.size() != 0) begin
          //  $display("SQ forwarding %d->%d", matchingStores[$].op.id, op.id);
        end

        insMap.setActualResult(op.id, data);

        return data;
    endfunction


    task automatic updateSQ(input InsId id, input Word adr, input Word val);
        int ind[$] = AbstractCore.storeQueue.find_first_index with (item.op.id == id);
        AbstractCore.storeQueue[ind[0]].adr = adr;
        AbstractCore.storeQueue[ind[0]].val = val;
    endtask

    function automatic StoreQueueExtract getMatchingStores(input OpSlot op, input Word adr);  
        // TODO: develop adr overlap check?
        StoreQueueEntry oooMatchingStores[$] = AbstractCore.storeQueue.find with (item.adr == adr && isStoreMemIns(decAbs(item.op)) && item.op.id < op.id);
        StoreQueueEntry committedMatchingStores[$] = AbstractCore.csq_N.find with (item.adr == adr && isStoreMemIns(decAbs(item.op)) && item.op.id < op.id);
        StoreQueueEntry matchingStores[$] = {committedMatchingStores, oooMatchingStores};
        return matchingStores;
    endfunction


    assign issuedSt0 = theIssueQueues.ig;

    assign doneOpsRegular_E[0] = eff(doneOpsRegular[0]);
    assign doneOpsRegular_E[1] = eff(doneOpsRegular[1]);
    assign doneOpsFloat_E[0] = eff(doneOpsFloat[0]);
    assign doneOpsFloat_E[1] = eff(doneOpsFloat[1]);
    assign doneOpBranch_E = eff(doneOpBranch);
    assign doneOpMem_E = eff(doneOpMem);
    assign doneOpSys_E = eff(doneOpSys);


    function automatic Word3 getAndVerifyArgs(input OpSlot op);
        InsDependencies deps = insMap.get(op.id).deps;
        Word3 argsP = getArgValues_F(AbstractCore.registerTracker, deps);
        Word3 argsM = insMap.get(op.id).argValues;
        
        if (argsP !== argsM) begin
            insMap.setArgError(op.id);
            //$display("Arg error at %d, %p for %p", op.id, argsP, argsM);
            //$display("%p, %s // %p", op,  disasm(op.bits), deps);
        end
        
        return argsP;
    endfunction;


    function automatic Word3 getArgValues_F(input RegisterTracker tracker, input InsDependencies deps);
        Word res[3];
        logic3 ready = checkArgsReady(deps);
        logic3 forw1 = checkForwardsReady(deps, 1);
        logic3 forw0 = checkForwardsReady(deps, 0);
        Word vals1[3] = getForwardedValues(deps, 1);
        Word vals0[3] = getForwardedValues(deps, 0);
        
        foreach (res[i]) begin
            case (deps.types[i])
                SRC_ZERO: res[i] = 0;
                SRC_CONST: res[i] = deps.sources[i];
                SRC_INT: begin
                    if (ready[i])
                        res[i] = tracker.intRegs[deps.sources[i]];
                    else if (forw1[i]) begin
                        $display("....get(1) a %d = %d", i, vals1[i]);
                        res[i] = vals1[i];
                    end
                    else if (forw0[i]) begin
                        $display("....get(0) a %d = %d", i, vals0[i]);
                        res[i] = vals0[i];
                    end
                    else
                        $fatal(2, "oh no");
                end
                SRC_FLOAT: begin
                    if (ready[i])
                        res[i] = tracker.floatRegs[deps.sources[i]];
                    else if (forw1[i]) begin
                        $display(".......");
                        res[i] = vals1[i];
                    end
                    else if (forw0[i]) begin
                        $display(".......");
                        res[i] = vals0[i];
                    end
                    else
                        $fatal(2, "oh no");
                end
            endcase
        end

        return res;
    endfunction

endmodule




module IssueQueue
#(
    parameter int SIZE = OP_QUEUE_SIZE,
    parameter int OUT_WIDTH = 1
)
(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpSlotA inGroup,
    input logic inMask[$size(OpSlotA)],
    
    output OpSlot outGroup[OUT_WIDTH]
);

    int num = 0;

    localparam logic dummy3[3] = '{'z, 'z, 'z};

    localparam ReadyVec3 FORWARDING_VEC_ALL_Z = '{default: dummy3};
    localparam ReadyVec3 FORWARDING_ALL_Z[-3:1] = '{default: FORWARDING_VEC_ALL_Z};

    OpSlot content[$:SIZE];
    ReadyVec readyVec, readyVec_A;
    ReadyVec3   ready3Vec,
                readyOrForward3Vec_N;
    ReadyVec3   forwardingMatches[-3:1] = FORWARDING_ALL_Z;
    

    OpSlot issued[OUT_WIDTH] = '{default: EMPTY_SLOT};
    OpSlot issued1[OUT_WIDTH] = '{default: EMPTY_SLOT};

        logic cmpb, cmpb0, cmpb1;


    assign outGroup = issued;


    function automatic ReadyVec3 gatherReadyOrForwards_N(input ReadyVec3 ready, input ReadyVec3 forwards[-3:1]);
        ReadyVec3 res = '{default: dummy3};
        
        foreach (res[i]) begin
            logic slot[3] = res[i];
            foreach (slot[a]) begin
                if ($isunknown(ready[i][a])) res[i][a] = 'z;
                else begin
                    res[i][a] = ready[i][a];
                    // CAREFUL: not using -3 here
                    for (int s = -3 + 1; s <= 1; s++) res[i][a] |= forwards[s][i][a];
                end
            end
        end
        
        return res;    
    endfunction

    function automatic ReadyVec makeReadyVec(input ReadyVec3 argV);
        ReadyVec res = '{default: 'z};
        foreach (res[i]) 
            res[i] = $isunknown(argV[i]) ? 'z : argV[i].and();
        return res;
    endfunction
    

    always @(posedge AbstractCore.clk) begin
        ready3Vec = getReadyVec3(content);
        foreach (forwardingMatches[i]) forwardingMatches[i] = getForwardVec3(content, i);

        readyVec = makeReadyVec(ready3Vec);

        readyOrForward3Vec_N = gatherReadyOrForwards_N(ready3Vec, forwardingMatches);
        readyVec_A = makeReadyVec(readyOrForward3Vec_N);

        if (lateEventInfo.redirect || branchEventInfo.redirect)
            flushIq();
        else begin
            writeInput();
        end
        
        issue();
        
        foreach (issued[i])
            issued1[i] <= tick(issued[i]);
        
        num <= content.size();

    end

     //   assign cmpb = (readyVec_A === readyVec_T);
     //   assign cmpb0 = (readyOrForward3Vec_N === readyOrForward3Vec);
     //  assign cmpb1 = (readyVec_C === readyVec_T);


    task automatic flushIq();
        if (lateEventInfo.redirect) flushOpQueueAll();
        else if (branchEventInfo.redirect) flushOpQueuePartial(branchEventInfo.op);
    endtask


    task automatic flushOpQueueAll();
        while (content.size() > 0) begin
            void'(content.pop_back());
        end
    endtask

    task automatic flushOpQueuePartial(input OpSlot op);
        while (content.size() > 0 && content[$].id > op.id) begin
            void'(content.pop_back());
        end
    endtask

    task automatic writeInput();
        foreach (inGroup[i]) begin
            OpSlot op = inGroup[i];
            if (op.active && inMask[i]) begin
                content.push_back(op);
            end
        end
    endtask

    task automatic issue();
        OpSlot ops[$];
        int n = OUT_WIDTH > num ? num : OUT_WIDTH;
        if (content.size() < n) n = content.size();
        
        issued <= '{default: EMPTY_SLOT};
         
        foreach (issued[i]) begin
            OpSlot op;
        
            if (i < n && readyVec[i]) begin // TODO: switch to readyVec_A when ready
                op = content[i];
                ops.push_back(op);
            end
            else
                break;
        end
        
        foreach (ops[i]) begin
            OpSlot op = ops[i];
            issued[i] <= tick(op);
            markOpIssued(op);
            
            void'(content.pop_front());
        end
    endtask

    function automatic void markOpIssued(input OpSlot op);
        if (!op.active || op.id == -1) return;
        
        putMilestone(op.id, InstructionMap::Issue);
    endfunction

endmodule



module IssueQueueComplex(
                        ref InstructionMap insMap,
                        input EventInfo branchEventInfo,
                        input EventInfo lateEventInfo,
                        input OpSlotA inGroup
);

    localparam int IN_WIDTH = $size(inGroup);


    logic regularMask[IN_WIDTH];
    OpSlot issuedRegular[2];
    OpSlot issuedFloat[2];
    OpSlot issuedMem[1];
    OpSlot issuedSys[1];
    OpSlot issuedBranch[1];
    
    
    IssueQueue#(.OUT_WIDTH(2)) regularQueue(insMap, branchEventInfo, lateEventInfo, inGroup, regularMask,
                                            issuedRegular);
    IssueQueue#(.OUT_WIDTH(2)) floatQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.float,
                                            issuedFloat);
    IssueQueue#(.OUT_WIDTH(1)) branchQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.branch,
                                            issuedBranch);
    IssueQueue#(.OUT_WIDTH(1)) memQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.mem,
                                            issuedMem);
    IssueQueue#(.OUT_WIDTH(1)) sysQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.sys,
                                            issuedSys);
    
    typedef struct {
        logic regular[IN_WIDTH];
        logic float[IN_WIDTH];
        logic branch[IN_WIDTH];
        logic mem[IN_WIDTH];
        logic sys[IN_WIDTH];
    } RoutingInfo;
    
    const RoutingInfo DEFAULT_ROUTING_INFO = '{
        regular: '{default: 0},
        float: '{default: 0},
        branch: '{default: 0},
        mem: '{default: 0},
        sys: '{default: 0}
    };
    
    RoutingInfo routingInfo;
    
    assign routingInfo = routeOps(inGroup); 
    assign regularMask = routingInfo.regular;


    function automatic RoutingInfo routeOps(input OpSlotA gr);
        RoutingInfo res = DEFAULT_ROUTING_INFO;
        
        foreach (gr[i]) begin
            OpSlot op = gr[i];
            
            if (isLoadIns(decAbs(op)) || isStoreIns(decAbs(op))) res.mem[i] = 1;
            else if (isSysIns(decAbs(op))) res.sys[i] = 1;
            else if (isBranchIns(decAbs(op))) res.branch[i] = 1;
            else if (isFloatCalcIns(decAbs(op))) res.float[i] = 1;
            else res.regular[i] = 1;
        end
        
        return res;
    endfunction


    function automatic ReadyVec3 getReadyVec3(input OpSlot iq[$:OP_QUEUE_SIZE]);
        logic D3[3] = '{'z, 'z, 'z};
        ReadyVec3 res = '{default: D3};
        foreach (iq[i]) begin
            InsDependencies deps = insMap.get(iq[i].id).deps;
            logic3 ra = checkArgsReady(deps);
            res[i] = ra;
        end
        return res;
    endfunction
    
    function automatic ReadyVec3 getForwardVec3(input OpSlot iq[$:OP_QUEUE_SIZE], input int stage);
        logic D3[3] = '{'z, 'z, 'z};
        ReadyVec3 res = '{default: D3};
        foreach (iq[i]) begin
            InsDependencies deps = insMap.get(iq[i].id).deps;
            logic3 ra = checkForwardsReady(deps, stage);
            res[i] = ra;
        end
        return res;
    endfunction


    IssueGroup ig;

    assign ig.regular = issuedRegular;
    assign ig.float = issuedFloat;
    assign ig.branch = issuedBranch[0];
    assign ig.mem = issuedMem[0];
    assign ig.sys = issuedSys[0];

    assign    AbstractCore.oooLevels_N.iqRegular = regularQueue.num;
    assign    AbstractCore.oooLevels_N.iqBranch = branchQueue.num;
    assign    AbstractCore.oooLevels_N.iqMem = memQueue.num;
    assign    AbstractCore.oooLevels_N.iqSys = sysQueue.num;

endmodule
