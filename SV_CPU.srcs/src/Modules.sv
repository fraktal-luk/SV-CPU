
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
    input OpSlot op0,
    input OpPacket opP
);

    OpSlot op1 = EMPTY_SLOT, doneOp = EMPTY_SLOT, doneOpD0 = EMPTY_SLOT;
    OpSlot op0_E, op_E, doneOp_E, doneOpD0_E;
    Word result = 'x;

    OpPacket p0, p1 = EMPTY_OP_PACKET, pE0 = EMPTY_OP_PACKET, pD0 = EMPTY_OP_PACKET, pD1 = EMPTY_OP_PACKET;
    OpPacket p0_E, p1_E, pE0_E, pD0_E, pD1_E;

    OpPacket stage0, stage0_E;
    
    assign stage0 = makePacket(doneOp, result);
    assign stage0_E = makePacket(doneOp_E, result);


    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        pE0 <= tickP(p1);
        pD0 <= tickP(pE0);
        pD1 <= tickP(pD0);
    
        //////
        op1 <= tick(op0);

        result <= 'x;
    
        if (op_E.active)
            result <= calcRegularOp(op_E.id);
        doneOp <= tick(op1);
        doneOpD0 <= tick(doneOp);
    end

    assign op0_E = eff(op0);
    assign op_E = eff(op1);
    assign doneOp_E = eff(doneOp);
    assign doneOpD0_E = eff(doneOpD0);

    assign p0_E = effP(p0);
    assign p1_E = effP(p1);
    assign pE0_E = effP(pE0);
    assign pD0_E = effP(pD0);


    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -2: //'{id: op0_E.id},
            p0_E,
        -1: //'{id: op_E.id},
            p1_E,
        0: //'{id:  doneOp_E.id},
            pE0_E,
        1: //'{id:  doneOpD0_E.id},
            pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };

endmodule


module BranchSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpSlot op0,
    input OpPacket opP
);

    OpSlot op1 = EMPTY_SLOT, doneOp = EMPTY_SLOT, doneOpD0 = EMPTY_SLOT;;
    OpSlot op0_E, op_E, doneOp_E, doneOpD0_E;
    Word result = 'x;

    OpPacket p0, p1 = EMPTY_OP_PACKET, pE0 = EMPTY_OP_PACKET, pD0 = EMPTY_OP_PACKET, pD1 = EMPTY_OP_PACKET;
    OpPacket p0_E, p1_E, pE0_E, pD0_E, pD1_E;


    OpPacket stage0, stage0_E;
    
    assign stage0 = makePacket(doneOp, result);
    assign stage0_E = makePacket(doneOp_E, result);


    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        pE0 <= tickP(p1);
        pD0 <= tickP(pE0);
        pD1 <= tickP(pD0);
    
        //////
        op1 <= tick(op0);

        //result <= 'x;
    
        runExecBranch(op_E.active, op_E.id);

        if (op_E.active) begin
            //insMap.setActualResult(op_E.id, getBranchResult(op_E.active, op_E.id));
            //result <= op_E.adr + 4;
        end
        
        result <= getBranchResult(op_E.active, op_E.id);
        
        doneOp <= tick(op1);
        doneOpD0 <= tick(doneOp);
    end


    assign op0_E = eff(op0);
    assign op_E = eff(op1);
    assign doneOp_E = eff(doneOp);
    assign doneOpD0_E = eff(doneOpD0);

    assign p0_E = effP(p0);
    assign p1_E = effP(p1);
    assign pE0_E = effP(pE0);
    assign pD0_E = effP(pD0);


    ForwardingElement image_E[-3:1];
    
    // Copied from RegularSubpipe
    assign image_E = '{
        -2: //'{id: op0_E.id},
            p0_E,
        -1: //'{id: op_E.id},
            p1_E,
        0: //'{id:  doneOp_E.id},
            pE0_E,
        1: //'{id:  doneOpD0_E.id},
            pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };
endmodule


module MemSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpSlot op0,
    input OpPacket opP
);

    OpSlot op1 = EMPTY_SLOT, doneOpE0 = EMPTY_SLOT, doneOpE1 = EMPTY_SLOT, doneOpE2 = EMPTY_SLOT, doneOpD0 = EMPTY_SLOT;
    OpSlot op0_E, op_E, doneOpE0_E, doneOpE1_E, doneOpE2_E, doneOpD0_E;
    Word result = 'x;

    OpPacket p0, p1 = EMPTY_OP_PACKET, pE0 = EMPTY_OP_PACKET, pE1 = EMPTY_OP_PACKET, pE2 = EMPTY_OP_PACKET, pD0 = EMPTY_OP_PACKET, pD1 = EMPTY_OP_PACKET;
    OpPacket p0_E, p1_E, pE0_E, pE1_E, pE2_E, pD0_E, pD1_E;

    OpPacket stage0, stage0_E;
    
    assign stage0 = makePacket(doneOpE2, result);
    assign stage0_E = makePacket(doneOpE2_E, result);

    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        pE0 <= tickP(p1);
        pE1 <= tickP(pE0);
        pE2 <= tickP(pE1);
        pD0 <= tickP(pE2);
        pD1 <= tickP(pD0);
    
        //////
    
        op1 <= tick(op0);

        result <= 'x;
    
        AbstractCore.readInfo <= EMPTY_WRITE_INFO;

        if (op_E.active) performMemFirst(op_E.id);

        doneOpE0 <= tick(op1);
        
        doneOpE1 <= tick(doneOpE0);
        
        if (doneOpE1_E.active) begin
            result <= calcMemLater(doneOpE1_E.id); 
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

    assign p0_E = effP(p0);
    assign p1_E = effP(p1);
    assign pE0_E = effP(pE0);
    assign pE1_E = effP(pE1);
    assign pE2_E = effP(pE2);
    assign pD0_E = effP(pD0);
    assign pD1_E = effP(pD1);

    
    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -3: //'{id: op_E.id},
            p1_E,
        -2: //'{id: doneOpE0_E.id},
            pE0_E,
        -1: //'{id: doneOpE1_E.id},
            pE1_E,
        0: //'{id:  doneOpE2_E.id},
            pE2_E,
        1: //'{id:  doneOpD0_E.id},
            pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };
endmodule



module ExecBlock(ref InstructionMap insMap,
                input EventInfo branchEventInfo,
                input EventInfo lateEventInfo
);
    //typedef StoreQueueEntry StoreQueueExtract[$];

    //IssueGroup issuedSt0;
    
    OpSlot doneOpSys = EMPTY_SLOT;
    OpSlot doneOpSys_E;


    OpPacket doneRegular0;
    OpPacket doneRegular1;

    OpPacket doneBranch;
    OpPacket doneMem;
    
    OpPacket doneFloat0;
    OpPacket doneFloat1; 
    
    OpPacket doneSys;
    

    OpPacket doneRegular0_E;
    OpPacket doneRegular1_E;

    OpPacket doneBranch_E;
    OpPacket doneMem_E;
    
    OpPacket doneFloat0_E;
    OpPacket doneFloat1_E; 
    
    OpPacket doneSys_E;


    // Int 0
    RegularSubpipe regular0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        //issuedSt0.regular[0],
        theIssueQueues.issuedRegular[0],
        AbstractCore.theIssueQueues.issuedRegularP[0]
    );
    
    // Int 1
    RegularSubpipe regular1(
        insMap,
        branchEventInfo,
        lateEventInfo,
        //issuedSt0.regular[1],
        theIssueQueues.issuedRegular[1],
        AbstractCore.theIssueQueues.issuedRegularP[1]
    );
    
    // Int 2
    BranchSubpipe branch0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        //issuedSt0.branch,
        theIssueQueues.issuedBranch[0],
        AbstractCore.theIssueQueues.issuedBranchP[0]
    );
    
    // Mem 0
    MemSubpipe mem0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        //issuedSt0.mem,
        theIssueQueues.issuedMem[0],
        AbstractCore.theIssueQueues.issuedMemP[0]
    );
    
    // Vec 0
    RegularSubpipe float0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        //issuedSt0.float[0],
        theIssueQueues.issuedFloat[0],
        AbstractCore.theIssueQueues.issuedFloatP[0]
    );
    
    // Vec 1
    RegularSubpipe float1(
        insMap,
        branchEventInfo,
        lateEventInfo,
        //issuedSt0.float[1],
        theIssueQueues.issuedFloat[1],
        AbstractCore.theIssueQueues.issuedFloatP[1]
    );

//    assign issuedSt0.regular = theIssueQueues.issuedRegular;
//    assign issuedSt0.float = theIssueQueues.issuedFloat;
//    assign issuedSt0.branch = theIssueQueues.issuedBranch[0];
//    assign issuedSt0.mem = theIssueQueues.issuedMem[0];
//    assign issuedSt0.sys = theIssueQueues.issuedSys[0];



    always @(posedge AbstractCore.clk) begin
        doneOpSys <= tick(//issuedSt0.sys);
                          theIssueQueues.issuedSys[0]);
    end

    assign doneSys = makePacket(doneOpSys, 'x);
    assign doneSys_E = makePacket(doneOpSys_E, 'x);

    assign doneRegular0 = regular0.stage0;
    assign doneRegular1 = regular1.stage0;
    assign doneBranch = branch0.stage0;
    assign doneMem = mem0.stage0;
    assign doneFloat0 = float0.stage0;
    assign doneFloat1 = float1.stage0;

    assign doneRegular0_E = regular0.stage0_E;
    assign doneRegular1_E = regular1.stage0_E;
    assign doneBranch_E = branch0.stage0_E;
    assign doneMem_E = mem0.stage0_E;
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

    // TOPLEVEL
    task automatic performMemFirst(input InsId id);
        AbstractInstruction abs = decId(id);
        Word3 args = getAndVerifyArgs(id);
        Word adr = calculateEffectiveAddress(abs, args);

        // TODO: compare adr with that in memTracker
        if (isStoreIns(abs)) begin            
            if (isStoreMemIns(abs)) begin
                checkStoreValue(id, adr, args[2]);
                
                putMilestone(id, InstructionMap::WriteMemAddress);
                putMilestone(id, InstructionMap::WriteMemValue);
            end
        end

        AbstractCore.readInfo <= '{1, adr, 'x};
    endtask

    // TOPLEVEL
    function automatic Word calcMemLater(input InsId id);
        AbstractInstruction abs = decId(id);
        Word3 args = getAndVerifyArgs(id);

        InsId writerAllId = AbstractCore.memTracker.checkWriter(id);

        logic forwarded = (writerAllId !== -1);
        Word fwValue = AbstractCore.memTracker.getStoreValue(writerAllId);
        Word memData = forwarded ? fwValue : AbstractCore.readIn[0];
        Word data = isLoadSysIns(abs) ? getSysReg(args[1]) : memData;

        if (forwarded) begin
            putMilestone(writerAllId, InstructionMap::MemFwProduce);
            putMilestone(id, InstructionMap::MemFwConsume);
        end

        insMap.setActualResult(id, data);

        return data;
    endfunction


    function automatic void checkStoreValue(input InsId id, input Word adr, input Word value);
        Transaction tr[$] = AbstractCore.memTracker.stores.find with (item.owner == id);
        assert (tr[0].adr === adr && tr[0].val === value) else $error("Wrong store: op %d, %d@%d", id, value, adr);
    endfunction


    assign doneOpSys_E = eff(doneOpSys);


    function automatic Word3 getAndVerifyArgs(input InsId id);
        InsDependencies deps = insMap.get(id).deps;
        Word3 argsP = getArgValues(AbstractCore.registerTracker, deps);
        Word3 argsM = insMap.get(id).argValues;
        
        if (argsP !== argsM) insMap.setArgError(id);
        
        return argsP;
    endfunction;



    function automatic Word3 getArgValues(input RegisterTracker tracker, input InsDependencies deps);
        Word res[3];
        logic3 ready = checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);
        logic3 forw1 = checkForwardsReady(insMap, allByStage, deps, 1);
        logic3 forw0 = checkForwardsReady(insMap, allByStage, deps, 0);
        Word vals1[3] = getForwardedValues(insMap, allByStage, deps, 1);
        Word vals0[3] = getForwardedValues(insMap, allByStage, deps, 0);
        
        foreach (res[i]) begin
            case (deps.types[i])
                SRC_ZERO: res[i] = 0;
                SRC_CONST: res[i] = deps.sources[i];
                SRC_INT: begin
                    if (ready[i])
                        res[i] = tracker.ints.regs[deps.sources[i]];
                    else if (forw1[i]) begin
                        //$display("....get(1) a %d = %d", i, vals1[i]);
                        res[i] = vals1[i];
                    end
                    else if (forw0[i]) begin
                        //$display("....get(0) a %d = %d", i, vals0[i]);
                        res[i] = vals0[i];
                    end
                    else
                        $fatal(2, "oh no");
                end
                SRC_FLOAT: begin
                    if (ready[i])
                        res[i] = tracker.floats.regs[deps.sources[i]];
                    else if (forw1[i]) begin
                        //$display(".......");
                        res[i] = vals1[i];
                    end
                    else if (forw0[i]) begin
                        //$display(".......");
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
