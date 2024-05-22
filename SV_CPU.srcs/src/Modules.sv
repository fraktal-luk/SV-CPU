
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
    
      
        // Numbered exec ports:
        // I0
        // I1
        // I2
        // ...
        // M0
        // M1
        // M2
        // ...
        // V0
        // V1
        // V2
        // ...

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

endpackage

import ExecDefs::*;


module RegularSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpSlot op0
);

    OpSlot op0_E, op1 = EMPTY_SLOT, op_E;
    OpSlot doneOp = EMPTY_SLOT;
    OpSlot doneOp_E;
    Word result = 'x;

    always @(posedge AbstractCore.clk) begin
        op1 <= tick(op0);

        result <= 'x;
    
        if (op_E.active)
            result <= calcRegularOp(op_E);
        doneOp <= tick(op1);
    end

    assign op0_E = eff(op0);
    assign op_E = eff(op1);
    assign doneOp_E = eff(doneOp);

    function automatic OpSlot forward(input int stage);
        case (stage)
            -1: return op_E;
            0:  return doneOp_E;
            
            default: return EMPTY_SLOT;
        endcase
    endfunction 


    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -2: '{id: op0_E.id},
        -1: '{id: op_E.id},
        0: '{id:  doneOp_E.id},
        //1: '{id: op0.id},
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
    OpSlot doneOp = EMPTY_SLOT;
    OpSlot doneOp_E;
    Word result = 'x;

    always @(posedge AbstractCore.clk) begin
        op1 <= tick(op0);

        result <= 'x;
    
        runExecBranch(op_E);
        
        if (op_E.active)
            result <= op_E.adr + 4;
        
        doneOp <= tick(op1);
    end

    assign op0_E = eff(op0);
    assign op_E = eff(op1);
    assign doneOp_E = eff(doneOp);

    function automatic OpSlot forward(input int stage);
        case (stage)
            -1: return op_E;
            0:  return doneOp_E;
            
            default: return EMPTY_SLOT;
        endcase
    endfunction
    
    ForwardingElement image_E[-3:1];
    
    // Copied from RegularSubpipe
    assign image_E = '{
        -2: '{id: op0_E.id},
        -1: '{id: op_E.id},
        0: '{id:  doneOp_E.id},
        //1: '{id: op0.id},
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
    OpSlot doneOpE0 = EMPTY_SLOT, doneOpE1 = EMPTY_SLOT, doneOpE2 = EMPTY_SLOT;
    OpSlot doneOpE0_E, doneOpE1_E, doneOpE2_E;
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
        
    end

    assign op0_E = eff(op0);
    assign op_E = eff(op1);
    assign doneOpE0_E = eff(doneOpE0);
    assign doneOpE1_E = eff(doneOpE1);
    assign doneOpE2_E = eff(doneOpE2);

    function automatic OpSlot forward(input int stage);
        case (stage)
            -4: return op0_E;
            -3: return op_E;
            -2: return doneOpE0_E;
            -1: return doneOpE1_E;
            0:  return doneOpE2_E;
            
            default: return EMPTY_SLOT;
        endcase
    endfunction
    
    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -3: '{id: op_E.id},
        -2: '{id: doneOpE0_E.id},
        -1: '{id: doneOpE1_E.id},
        0: '{id:  doneOpE2_E.id},
        //1: '{id: op0.id},
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


    function automatic Word3 getPhysicalArgValues(input RegisterTracker tracker, input OpSlot op);
        InsDependencies deps = insMap.get(op.id).deps;
        return getArgValues(tracker, deps);            
    endfunction

    function automatic Word3 getAndVerifyArgs(input OpSlot op);
        Word3 argsP = getPhysicalArgValues(AbstractCore.registerTracker, op);
        Word3 argsM = insMap.get(op.id).argValues;
        
        if (argsP !== argsM) insMap.setArgError(op.id);
        
        return argsP;
    endfunction;




        function automatic void getForwards();
            // int results:
            // regular0
            // regular1
            // branch0
            // mem0
            
            // float results:
            // float0
            // float1
            
            
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

    //typedef logic ReadyVec[SIZE];
    //typedef logic ReadyVec3[SIZE][3];

    int num = 0;

    localparam logic dummy3[3] = '{'z, 'z, 'z};

    OpSlot content[$:SIZE];
    ReadyVec readyVec = '{default: 'z},
             forwardVecM2,// = '{default: 'z},
             forwardVecM1,// = '{default: 'z},
             forwardVec0,// = '{default: 'z},
             forwardVec1,// = '{default: 'z},
                    readyVec_A;
    ReadyVec3 ready3Vec,// = '{default: dummy3}, 
            forward3VecM3,// = '{default: dummy3},
            forward3VecM2,// = '{default: dummy3},
            forward3VecM1,// = '{default: dummy3}, 
            forward3Vec0,// = '{default: dummy3},
            forward3Vec1,// = '{default: dummy3},
              readyOrForward3Vec;// = '{default: dummy3};
    
    OpSlot issued[OUT_WIDTH] = '{default: EMPTY_SLOT};
    OpSlot issued1[OUT_WIDTH] = '{default: EMPTY_SLOT};
    
        logic cmpb;
        
        
    
    assign outGroup = issued;
    
    assign readyOrForward3Vec = gatherReadyOrForwards(ready3Vec, forward3VecM3, forward3VecM2, forward3VecM1, forward3Vec0, forward3Vec1);
    assign readyVec_A = makeReadyVec(readyOrForward3Vec);

    function automatic ReadyVec3 gatherReadyOrForwards(input ReadyVec3 ready, input ReadyVec3 fwM3, 
                                                      input ReadyVec3 fwM2, input ReadyVec3 fwM1,
                                                      input ReadyVec3 fw0, input ReadyVec3 fw1);
        ReadyVec3 res = ready;
        
        foreach (res[i]) begin
            logic slot[3] = res[i];
            foreach (slot[a])
                res[i][a] |= (fwM3[i][a] | fwM2[i][a] | fwM1[i][a] | fw0[i][a] | fw1[i][a]);
        end
        
        return res;    
    endfunction

    function automatic ReadyVec makeReadyVec(input ReadyVec3 argV);
        ReadyVec res;
        foreach (res[i]) res[i] = argV[i].and();
        return res;
    endfunction
    

    always @(posedge AbstractCore.clk) begin

        if (lateEventInfo.redirect || branchEventInfo.redirect)
            flushIq();
        else begin
            writeInput();
        end
        
        issue();
        
        foreach (issued[i])
            issued1[i] <= tick(issued[i]);
        
        num <= content.size();
        
        readyVec <= getReadyVec(content);
//            forwardVecM2 <= getForwardVec(content, -2);
//            forwardVecM1 <= getForwardVec(content, -1);
//            forwardVec0 <= getForwardVec(content, 0);
//            forwardVec1 <= getForwardVec(content, 1);
            
//        ready3Vec <= getReadyVec3(content);
//            forward3VecM3 <= getForwardVec3(content, -3);
//            forward3VecM2 <= getForwardVec3(content, -2);
//            forward3VecM1 <= getForwardVec3(content, -1);
//            forward3Vec0 <= getForwardVec3(content, 0);
//            forward3Vec1 <= getForwardVec3(content, 1);
    end

       // assign readyVec = getReadyVec(content);

       assign     ready3Vec = getReadyVec3(content);
       assign     forward3VecM3 = getForwardVec3(content, -3);
       assign     forward3VecM2 = getForwardVec3(content, -2);
       assign     forward3VecM1 = getForwardVec3(content, -1);
       assign     forward3Vec0 = getForwardVec3(content, 0);
       assign     forward3Vec1 = getForwardVec3(content, 1);


    task automatic flushIq();
        if (lateEventInfo.redirect) begin
            flushOpQueueAll();
        end
        else if (branchEventInfo.redirect) begin
            flushOpQueuePartial(branchEventInfo.op);
        end
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
        int n = OUT_WIDTH > num ? num : OUT_WIDTH;
        if (content.size() < n) n = content.size();
        
        issued = '{default: EMPTY_SLOT};
                
        foreach (issued[i]) begin
            OpSlot op;
        
            if (i < n && readyVec[i]) begin
                op = content.pop_front();
                issued[i] = tick(op);
                markOpIssued(op);
            end
            else
                break;
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


    function automatic logic3 checkArgsReady(input InsDependencies deps);
        logic3 res;
        foreach (deps.types[i])
            case (deps.types[i])
                SRC_ZERO:  res[i] = 1;
                SRC_CONST: res[i] = 1;
                SRC_INT:   res[i] = AbstractCore.intRegsReadyV[deps.sources[i]];
                SRC_FLOAT: res[i] = AbstractCore.floatRegsReadyV[deps.sources[i]];
            endcase      
        return res;
    endfunction

    function automatic logic3 checkForwardsReady(input InsDependencies deps, input int stage);
        logic3 res;
        foreach (deps.types[i])
            case (deps.types[i])
                SRC_ZERO:  res[i] = 0;
                SRC_CONST: res[i] = 0;
                SRC_INT:   begin
                    ForwardingElement feInt[N_INT_PORTS] = theExecBlock.intImagesTr[stage];
                    ForwardingElement feMem[N_MEM_PORTS] = theExecBlock.memImagesTr[stage];
                    res[i] = 0;
                    foreach (feInt[i]) begin
                        InstructionInfo ii;
                        if (feInt[i].id == -1) continue;
                        ii = insMap.get(feInt[i].id);
                        if (ii.physDest === deps.sources[i]) begin
                            res[i] = 1;
                            //    $display("huhu!");
                        end
                    end
                    foreach (feMem[i]) begin
                        InstructionInfo ii;
                        if (feMem[i].id == -1) continue;
                        ii = insMap.get(feMem[i].id);
                        if (ii.physDest === deps.sources[i]) begin
                            res[i] = 1;
                            //$display(" haaa ha!");
                        end
                    end
                end
                SRC_FLOAT: begin
                    ForwardingElement feVec[N_VEC_PORTS] = theExecBlock.floatImagesTr[stage];
                    res[0] = 0;
                    foreach (feVec[i]) begin
                        InstructionInfo ii;
                        if (feVec[i].id == -1) continue;
                        ii = insMap.get(feVec[i].id);
                        if (ii.physDest === deps.sources[i]) begin
                            res[i] = 1;
                        end
                    end
                end
            endcase      
        return res;
    endfunction



    function automatic ReadyVec getReadyVec(input OpSlot iq[$:OP_QUEUE_SIZE]);
        ReadyVec res = '{default: 'z};
        foreach (iq[i]) begin
            InsDependencies deps = insMap.get(iq[i].id).deps;
            logic3 ra = checkArgsReady(deps);
            res[i] = ra.and();
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
    
        function automatic ReadyVec getForwardVec(input OpSlot iq[$:OP_QUEUE_SIZE], input int stage);
            ReadyVec res = '{default: 'z};
            foreach (iq[i]) begin
                InsDependencies deps = insMap.get(iq[i].id).deps;
                logic3 ra = checkForwardsReady(deps, stage);
                res[i] = ra.and();
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
