
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

    always_comb p0 = opP;

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

    ForwardingElement image_E[-3:2];
    
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

    ForwardingElement image_E[-3:2];
    
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
    UopPacket p0, p1 = EMPTY_UOP_PACKET, pE0 = EMPTY_UOP_PACKET, pE1 = EMPTY_UOP_PACKET, pE2 = EMPTY_UOP_PACKET, pE3 = EMPTY_UOP_PACKET,
              pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
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

    ForwardingElement image_E[-3:2];
    
    assign image_E = '{
        -2: pE1_E,
        -1: pE2_E,
        0: pE3_E,
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

    assign stage0_E = pE0_E;  
    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);   
        pE0 <= performBranchE0(tickP(p1));
        pD0 <= tickP(pE0);
        pD1 <= tickP(pD0);

        runExecBranch(p1_E.active, p1_E.uid);
    end

    always_comb p0_E = effP(p0);
    always_comb p1_E = effP(p1);
    always_comb pE0_E = effP(pE0);
    always_comb pD0_E = effP(pD0);

    ForwardingElement image_E[-3:2];
    
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
            UopId uid = p.uid;
            Mword3 args = rn.getAndVerifyArgs(uid);
            p.result = resolveBranchDirection(decUname(uid), args[0]);// reg
        end
        return p;
    endfunction
    

    task automatic runExecBranch(input logic active, input UopId uid);
        AbstractCore.branchEventInfo <= EMPTY_EVENT_INFO;

        if (!active) return;

        setBranchInCore(uid);
        putMilestone(uid, InstructionMap::ExecRedirect);
    endtask


    task automatic setBranchInCore(input UopId uid);
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

        insMap.setBranchDir(U2M(uid), dir);

        AbstractCore.branchEventInfo <= '{1, U2M(uid), PE_NONE, redirect, dir, adr, resolvedTarget};
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
            if (IS_FP)
                mainStage <= performFP(p1_E); // New uop enters     
            else
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
    assign empty = !(p0.active || p1.active || mainStage.active);

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

    ForwardingElement image_E[-3:2];
    
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

    ForwardingElement image_E[-3:2];

    assign image_E = '{
        -2: p0_E,
        -1: p1_E,
        0: pE0_E,
        1: pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };


    function automatic UopPacket performStoreData(input UopPacket p);
        if (p.uid == UID_NONE) return p;

        begin
            UopPacket res = p;
            Mword3 args = rn.getAndVerifyArgs(p.uid);
            res.result = args[2];
            return res;
        end
    endfunction

endmodule


module BranchTracker;

    BranchGroup histFull[16];

    int lastCount = -1;
    int lastLen = -1;

    int newCount = -1;
    int newLen = -1; // 

    Mword p0i = -1, p0, p1, p2;
    Mword a0i, a0, a1, a2;

        logic ch0, ch1, ch2, ch3, ch4; 



        //struct {
            TMP_PredState committedPredState = DEFAULT_PRED_STATE;
            TMP_PredState committedPredStatePrev = DEFAULT_PRED_STATE;
            logic latestPredPresent = 0;
        //} latePredStates;



    task automatic addGroupPredInfo();

    endtask

    task automatic addBranchPredInfo();

    endtask


    function automatic void update(input BqEntry entry);
        BranchGroup allZ = '{default: 'z};

        lastCount = entry.histCount;
        lastLen = entry.histLen;


        if (entry.histLen + 1 > newLen) begin // Open new group
            histFull = {allZ, histFull[0:14]};
        end

        histFull[0][entry.slot] = entry.taken;

        newCount = entry.histCount + 1;
        newLen = entry.histLen + 1;

    endfunction


    function automatic Mbyte getSimplePredictionSig();
        return 'z;
    endfunction

    function automatic Mword getSimplePredictionTarget();
        return 'x;
    endfunction


    function automatic Mbyte getAdvancedPredictionSig();
        return 0;
    endfunction

    function automatic Mword getAdvancedPredictionTarget();
        return 'x;
    endfunction



    function automatic void startPrediction(input int count, input int len, input Mword adr);
        a0i <= adr;
        p0i <= len;
    endfunction

    function automatic void move();
        p0 <= p0i;
        p1 <= p0;
        p2 <= p1;

        a0 <= a0i;
        a1 <= a0;
        a2 <= a1;
    endfunction




    task automatic updateBpState(input InstructionInfo insInfo);

        // Start new block for predictor
        if (AbstractCore.CurrentConfig.enableMmu) begin
            if (insInfo.firstInGroup) begin
                latestPredPresent = 0;
                committedPredStatePrev = committedPredState;
                committedPredState = updatePredCommit(committedPredState, '{default: 'z}, insInfo.basicData.adr); // don't inc len

                branchTracker.addGroupPredInfo(); // needs: group vadr, predF0, targetF0?
            end
        end

        if (isBranchUop(decMainUop(insInfo.id))) begin // Br queue entry release
            BranchCheckpoint bce = checkpointUnit.frontElem();
            checkpointUnit.pop();

            assert (bce.id === insInfo.id) else $error("Not matching op: %p / %p", bce, insInfo.id);
            assert (
                    bce.predState.count === committedPredStatePrev.count
                &&  bce.predState.len === committedPredStatePrev.len
                &&  bce.predState.histCoded === committedPredStatePrev.histCoded
                &&  bce.predState.recentCoded === committedPredStatePrev.recentCoded
                    )
                else $error("Diffr, op %d\n%d: %s\nprev pred state:\n%p\n%p",
                            insInfo.id, insInfo.basicData.adr, disasm(insInfo.basicData.bits), bce.predState, committedPredStatePrev);

            if (AbstractCore.CurrentConfig.enableMmu) begin
                BranchGroup bg = updateBranchGroup(bce.ownPred, bce.slotInd, insInfo.takenBranch);

                if (!latestPredPresent) committedPredState = replacePredFirst(committedPredState, bg);
                else                    committedPredState = replacePred(committedPredState, bg);

                branchTracker.addBranchPredInfo(); // needs: vadr, target, predF2, slot, dir

                latestPredPresent = 1;
            end

        end
    endtask



endmodule



module CheckpointUnit();
    BranchCheckpoint branchCheckpointQueue[$:BC_QUEUE_SIZE];

    function automatic int getSize();
        return branchCheckpointQueue.size();
    endfunction

    function automatic BranchCheckpoint getCheckpoint(input InsId mid);
        BranchCheckpoint foundCP[$] = checkpointUnit.branchCheckpointQueue.find with (item.id == mid);
        return foundCP[0];
    endfunction

    task automatic flushAll();
        branchCheckpointQueue = '{};
    endtask

    task automatic flushPartial(input InsId id);
        while (branchCheckpointQueue.size() > 0 && branchCheckpointQueue[$].id > id) begin
            void'(branchCheckpointQueue.pop_back());
        end
    endtask  


    task automatic addCheckpoint(input BranchCheckpoint cp);
        branchCheckpointQueue.push_back(cp);
    endtask


    function automatic BranchCheckpoint frontElem();
        return branchCheckpointQueue[0];
    endfunction

    task automatic pop();
        branchCheckpointQueue.pop_front();
    endtask

endmodule



module WriteBuffer();

    logic csqEmpty = 0;
    logic wqFree;
    
    SqEntry csq[$] = '{StoreQueueHelper::EMPTY_QENTRY, StoreQueueHelper::EMPTY_QENTRY};
    SqEntry drainHead = StoreQueueHelper::EMPTY_QENTRY;
    MemWriteInfo writeInfo = EMPTY_WRITE_INFO, sysWriteInfo = EMPTY_WRITE_INFO;

    MemWriteInfo dcacheWriteInfos[2];
    MemWriteInfo sysWriteInfos[1];



    assign wqFree = csqEmpty && !dataCache.uncachedSubsystem.uncachedBusy;
    assign dcacheWriteInfos[0] = writeInfo;
    assign dcacheWriteInfos[1] = EMPTY_WRITE_INFO;
    assign sysWriteInfos[0] = sysWriteInfo;



    function automatic void add(input InsId id, input logic cancel);
        SqEntry found[$] = theSq.content.find_first with (item.mid == id);
        SqEntry foundElem = found[0];

        if (cancel) foundElem.valReady = 0; // Make sure it's inactive

        csq.push_back(foundElem); // Normal
        putMilestoneM(id, InstructionMap::WqEnter); // Normal
    endfunction


    function automatic void publish();
        if (drainHead.mid != -1) begin
            AbstractCore.memTracker.drain(drainHead.mid);
            putMilestoneC(drainHead.mid, InstructionMap::WqExit);
        end

        void'(csq.pop_front());

        assert (csq.size() > 0) else $fatal(2, "csq must never become physically empty");

        if (csq.size() < 2) begin // slot [0] doesn't count, it is already written and serves to signal to drain SQ 
            csq.push_back(StoreQueueHelper::EMPTY_QENTRY);
            csqEmpty <= 1;
        end
        else begin
            csqEmpty <= 0;
        end

        drainHead <= csq[0];
        writeInfo <= makeWriteInfo(csq[1]);
        sysWriteInfo <= makeSysWriteInfo(csq[1]);
    endfunction


    function automatic void clear();
        csq = '{StoreQueueHelper::EMPTY_QENTRY, StoreQueueHelper::EMPTY_QENTRY};
    endfunction

endmodule




module RegisterNetwork();

    ForwardingElement intImages[N_INT_PORTS][-3:2];
    ForwardingElement memImages[N_MEM_PORTS][-3:2];
    ForwardingElement memImagesVec[N_MEM_PORTS][-3:2];
    ForwardingElement memImagesVec_M1[N_MEM_PORTS][-3:2];
    ForwardingElement floatImages[N_VEC_PORTS][-3:2];

    IntByStage intImagesTr;
    MemByStage memImagesTr;
    MemByStage memImagesVecTr;
    VecByStage floatImagesTr;

    ForwardsByStage_0 allByStage, allByStageVec;




    // Used before Exec0 to get final values
    function automatic Mword3 getAndVerifyArgs(input UopId uid);
        InsDependencies deps = AbstractCore.insMap.getU(uid).deps;
        Mword3 argsP = getArgValues(/*AbstractCore.registerTracker,*/ deps);
        AbstractCore.insMap.setActualArgs(uid, argsP);
        return argsP;
    endfunction;


    // Used once, file internal
    function automatic Mword3 getArgValues(/*input RegisterTracker tracker, */input InsDependencies deps);
        Mword res[3];
        logic3 ready = checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);

        foreach (deps.types[i]) begin
            case (deps.types[i])
                SRC_ZERO:  res[i] = 0;
                SRC_CONST: res[i] = deps.sources[i];
                SRC_INT:   res[i] = getArgValueInt(AbstractCore.insMap, AbstractCore.registerTracker, deps.producers[i], deps.sources[i], allByStage, ready[i]);
                SRC_FLOAT: res[i] = getArgValueVec(AbstractCore.insMap, AbstractCore.registerTracker, deps.producers[i], deps.sources[i], allByStageVec, ready[i]);
            endcase
        end

        return res;
    endfunction


    // File internal
    function automatic Mword getArgValueInt(input InstructionMap imap, input RegisterTracker tracker,
                                            input UopId producer, input int source, input ForwardsByStage_0 fws, input logic ready);
        FEQ found1, found0;

        if (ready) return tracker.ints.regs[source];
        
        found1 = findForwardInt(producer, fws.ints[1], fws.mems[1]);
        if (found1.size() != 0) begin
            verifyForward(producer, source, found1[0].result);
            return found1[0].result;
        end
        
        found0 = findForwardInt(producer, fws.ints[0], fws.mems[0]);
        if (found0.size() != 0) begin
            verifyForward(producer, source, found0[0].result);
            return found0[0].result;
        end

        $fatal(2, "oh no\n%p, %d", producer, source);
    endfunction


    // File internal
    function automatic Mword getArgValueVec(input InstructionMap imap, input RegisterTracker tracker,
                                            input UopId producer, input int source, input ForwardsByStage_0 fws, input logic ready);
        FEQ found1, found0;

        if (ready) return tracker.floats.regs[source];

        found1 = findForwardVec(producer, fws.vecs[1], fws.mems[1]);
        if (found1.size() != 0) begin
            verifyForward(producer, source, found1[0].result);
            return found1[0].result;
        end

        found0 = findForwardVec(producer, fws.vecs[0], fws.mems[0]);
        if (found0.size() != 0) begin
            verifyForward(producer, source, found0[0].result);
            return found0[0].result;
        end

        $fatal(2, "oh no");
    endfunction


    // File internal
    function automatic FEQ findForwardInt(input UopId producer, input ForwardingElement feInt[N_INT_PORTS], input ForwardingElement feMem[N_MEM_PORTS]);
        FEQ res = feInt.find with (matchProducer(item, producer));
        if (res.size() == 0)
            res = feMem.find with (matchProducer(item, producer));
        return res;
    endfunction

    // File internal
    function automatic FEQ findForwardVec(input UopId producer, input ForwardingElement feVec[N_VEC_PORTS], input ForwardingElement feMem[N_MEM_PORTS]);
        FEQ res = feVec.find with (matchProducer(item, producer));
        if (res.size() == 0)
            res = feMem.find with (matchProducer(item, producer));
        return res;
    endfunction


    // File internal
    function automatic void verifyForward(input UopId producer, input int source, input Mword result);
        InstructionInfo ii = AbstractCore.insMap.get(U2M(producer));
        UopInfo ui = AbstractCore.insMap.getU(producer);

        assert (ui.physDest === source) else $fatal(2, "Not correct match, should be %p:", ii.id);
        assert (ui.resultA === result) else $fatal(2, "Value differs! %d // %d;\n %p\n%s", ui.resultA, result, ii, disasm(ii.basicData.bits));
    endfunction





        function automatic IntByStage trsInt(input ForwardingElement imgs[N_INT_PORTS][-3:2]);
            IntByStage res;
            
            foreach (imgs[p]) begin
                ForwardingElement img[-3:2] = imgs[p];
                foreach (img[s])
                    res[s][p] = img[s];
            end
            
            return res;
        endfunction

        function automatic MemByStage trsMem(input ForwardingElement imgs[N_MEM_PORTS][-3:2]);
            MemByStage res;
            
            foreach (imgs[p]) begin
                ForwardingElement img[-3:2] = imgs[p];
                foreach (img[s])
                    res[s][p] = img[s];
            end
            
            return res;
        endfunction

        function automatic VecByStage trsVec(input ForwardingElement imgs[N_VEC_PORTS][-3:2]);
            VecByStage res;
            
            foreach (imgs[p]) begin
                ForwardingElement img[-3:2] = imgs[p];
                foreach (img[s])
                    res[s][p] = img[s];
            end
            
            return res;
        endfunction




    assign intImages = '{0: theExecBlock.regular0.image_E,
                         1: theExecBlock.regular1.image_E,
                         2: theExecBlock.branch0.image_E,
                         3: theExecBlock.divider.image_E,
                         4: theExecBlock.multiplier0.image_E,
                         5: theExecBlock.multiplier1.image_E,
                         default: EMPTY_IMAGE};
    assign floatImages = '{0: theExecBlock.float0.image_E, 1: theExecBlock.float1.image_E, 2: theExecBlock.fdiv.image_E, default: EMPTY_IMAGE};

    assign memImages = '{0: theExecBlock.mem0.image_E, 1: theExecBlock.mem1.image_E, 2: theExecBlock.mem2.image_E, default: EMPTY_IMAGE};
    assign memImagesVec = memImages; //  TODO: separate, 1c longer load pipe on FP side? 

    assign memImagesVec_M1 = '{0: theExecBlock.mem0.imageM1_E,
                              1: theExecBlock.mem1.imageM1_E,
                              2: theExecBlock.mem2.imageM1_E, default: EMPTY_IMAGE};


    always_comb intImagesTr = trsInt(intImages);
    always_comb memImagesTr = trsMem(memImages);
    always_comb memImagesVecTr = trsMem(memImagesVec);
    always_comb floatImagesTr = trsVec(floatImages);

    assign allByStage.ints = intImagesTr;
    assign allByStage.mems = memImagesTr;
    assign allByStage.vecs = floatImagesTr;


    assign allByStageVec.ints = intImagesTr;
    assign allByStageVec.mems = memImagesVecTr;
    assign allByStageVec.vecs = floatImagesTr;




    // IQs
    function automatic Wakeup checkForwardSourceInt(input UopId producer);
        ForwardingElement fea[N_INT_PORTS][-3:2] = intImages;
        Wakeup res = EMPTY_WAKEUP;
        if (producer == UID_NONE) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.uid == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe %d (%d):\n%p", p, found, fea[p]);
            
            if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

            res.active = 1;
            res.producer = producer;
            res.group = PG_INT;
            res.port = p;
            res.stage = found[0];
            res.poison = fea[p][found[0]].poison;
            return res;
        end
        return res;
    endfunction;

    function automatic Wakeup checkForwardSourceVec(input UopId producer);
        ForwardingElement fea[N_VEC_PORTS][-3:2] = floatImages;
        Wakeup res = EMPTY_WAKEUP;
        if (producer == UID_NONE) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.uid == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe");
            
            if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

            res.active = 1;
            res.producer = producer;
            res.group = PG_VEC;
            res.port = p;
            res.stage = found[0];
            res.poison = fea[p][found[0]].poison;
            return res;
        end
        return res;
    endfunction;


    function automatic Wakeup checkForwardSourceMem(input UopId producer);
        ForwardingElement fea[N_MEM_PORTS][-3:2] = memImages;
        Wakeup res = EMPTY_WAKEUP;
        if (producer == UID_NONE) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.uid == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe");
            
            if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

            res.active = 1;

            // Don't wake up if this is a failed op
            if (fea[p][found[0]].status != ES_OK && found[0] >= 0) res.active = 0;
            
            res.producer = producer;
            res.group = PG_MEM;
            res.port = p;
            res.stage = found[0];
            res.poison = addProducer(fea[p][found[0]].poison, producer, fea);
            return res;
        end
        return res;
    endfunction;

    function automatic Wakeup checkForwardSourceMemVec(input UopId producer);
        ForwardingElement fea[N_MEM_PORTS][-3:2] = memImagesVec;
        Wakeup res = EMPTY_WAKEUP;
        if (producer == UID_NONE) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.uid == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe");
            
            if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

            res.active = 1;

            // Don't wake up if this is a failed op
            if (fea[p][found[0]].status != ES_OK && found[0] >= 0) res.active = 0;
            
            res.producer = producer;
            res.group = PG_MEM;
            res.port = p;
            res.stage = found[0];
            res.poison = addProducer(fea[p][found[0]].poison, producer, fea);
            return res;
        end
        return res;
    endfunction;

endmodule

