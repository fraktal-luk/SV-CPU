
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;



module AbstractCore
#(
)
(
    input logic clk,
    output logic insReq, output Word insAdr, input Word insIn[FETCH_WIDTH],
    output logic readReq[LOAD_WIDTH], output Word readAdr[LOAD_WIDTH], input Word readIn[LOAD_WIDTH],
    output logic writeReq, output Word writeAdr, output Word writeOut,
    
    input logic interrupt,
    input logic reset,
    output logic sig,
    output logic wrong
);
    
    logic dummy = '1;

    // DB
    CoreDB coreDB();
    InstructionMap insMap = new();
    Emulator renamedEmul = new(), retiredEmul = new();

    RegisterTracker #(N_REGS_INT, N_REGS_FLOAT) registerTracker = new();
    MemTracker memTracker = new();
    
    BranchTargetEntry branchTargetQueue[$:BC_QUEUE_SIZE];
    BranchCheckpoint branchCheckpointQueue[$:BC_QUEUE_SIZE];

    //..............................
    
    int cycleCtr = 0;

    always @(posedge clk) cycleCtr++;

    // Overall
    logic fetchAllow, renameAllow, iqsAccepting, csqEmpty = 0;
    IqLevels oooLevels, oooAccepts;
    int nFreeRegsInt = 0, nFreeRegsFloat = 0, bcqSize = 0;

    // OOO
    IndexSet renameInds = '{default: 0}, commitInds = '{default: 0};

        typedef struct {
            InsId last = -1;
            InsId lastWq = -1;
        } CommittedState;
        
        CommittedState committedState;


    // Exec
    logic intRegsReadyV[N_REGS_INT] = '{default: 'x};
    logic floatRegsReadyV[N_REGS_FLOAT] = '{default: 'x};



    Word instructionCacheOut[FETCH_WIDTH];

    EventInfo branchEventInfo = EMPTY_EVENT_INFO,
              lateEventInfo = EMPTY_EVENT_INFO, lateEventInfoWaiting = EMPTY_EVENT_INFO;
    Events evts;

    BranchCheckpoint branchCP;

    MemWriteInfo readInfo = EMPTY_WRITE_INFO; // Exec

    
    // Store interface
        // Committed
        StoreQueueEntry csq[$] = '{'{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}};
            StoreQueueEntry csq_Mirror[4] = '{'{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}};
            string csqStr;
            
        StoreQueueEntry storeHead = '{EMPTY_SLOT, 'x, 'x}, drainHead = '{EMPTY_SLOT, 'x, 'x};
        MemWriteInfo writeInfo; // Committed
    
    // Event control
        Word sysRegs[32];
        Word retiredTarget = 0;


    OpSlotA robOut;

    ///////////////////////////
        DataReadReq TMP_readReqs[N_MEM_PORTS];
        DataReadResp TMP_readResps[N_MEM_PORTS];
                
        Word TMP_readAddresses[N_MEM_PORTS];
        Word TMP_readData[N_MEM_PORTS];
        
        logic TMP_writeReqs[2];
        Word TMP_writeAddresses[2];
        Word TMP_writeData[2];

        logic cmpA, cmpB, cmpC, cmpD;
            
    InstructionL1 instructionCache(clk, insAdr, instructionCacheOut);
    DataL1        dataCache(clk, 
                            TMP_readReqs, TMP_readResps,
                            TMP_writeReqs, TMP_writeAddresses, TMP_writeData);
    
        assign TMP_readAddresses[0] = theExecBlock.mem0.effAdr;
        
        assign TMP_writeReqs[0] = writeInfo.req;
        assign TMP_writeAddresses[0] = writeInfo.adr;
        assign TMP_writeData[0] = writeInfo.value;
    
        assign TMP_readReqs = theExecBlock.readReqs;
        assign theExecBlock.readResps = TMP_readResps;
    
    
            assign cmpA = instructionCacheOut === insIn;
            
          

    Frontend theFrontend(insMap, branchEventInfo, lateEventInfo);

    // Rename
    OpSlotA stageRename1 = '{default: EMPTY_SLOT};
    OpSlotA sqOut, lqOut, bqOut;

    ReorderBuffer theRob(insMap, branchEventInfo, lateEventInfo, stageRename1, robOut);
    StoreQueue#(.SIZE(SQ_SIZE))
        theSq(insMap, branchEventInfo, lateEventInfo, stageRename1, sqOut, theExecBlock.toSq);
    StoreQueue#(.IS_LOAD_QUEUE(1), .SIZE(LQ_SIZE))
        theLq(insMap, branchEventInfo, lateEventInfo, stageRename1, lqOut, theExecBlock.toLq);
    StoreQueue#(.IS_BRANCH_QUEUE(1), .SIZE(BQ_SIZE))
        theBq(insMap, branchEventInfo, lateEventInfo, stageRename1, bqOut, theExecBlock.toBq);

    IssueQueueComplex theIssueQueues(insMap, branchEventInfo, lateEventInfo, stageRename1);

    ExecBlock theExecBlock(insMap, branchEventInfo, lateEventInfo);

    ///////////////////////////////////////////

    assign writeInfo = '{storeHead.op.active && isStoreMemIns(decAbs(storeHead.op)), storeHead.adr, storeHead.val};


    always @(posedge clk) begin
            insMap.endCycle();
    
        activateEvent();

        drainWriteQueue();
            TMP_WQ();        
        advanceCommit();        
        putWrite();

        if (reset) execReset();
        else if (interrupt) execInterrupt();

        if (lateEventInfo.redirect || branchEventInfo.redirect)
            redirectRest();
        else
            runInOrderPartRe();

        // Complete + write regs
        handleCompletion();
        
            //csq_Mirror <= csq[0:$];
        
            $swrite(csqStr, "%p", csq);
        
        updateBookkeeping();
    end


    task automatic handleCompletion();
        completePacket(theExecBlock.doneRegular0_E);
        completePacket(theExecBlock.doneRegular1_E);
        completePacket(theExecBlock.doneFloat0_E);
        completePacket(theExecBlock.doneFloat1_E);
        completePacket(theExecBlock.doneBranch_E);
        completePacket(theExecBlock.doneMem0_E);
        completePacket(theExecBlock.doneMem2_E);
        completePacket(theExecBlock.doneSys_E);
    endtask

    task automatic updateBookkeeping();
        bcqSize <= branchCheckpointQueue.size();
        
        nFreeRegsInt <= registerTracker.getNumFreeInt();
        nFreeRegsFloat <= registerTracker.getNumFreeFloat();
        
        intRegsReadyV <= registerTracker.ints.ready;
        floatRegsReadyV <= registerTracker.floats.ready;

        // Overall DB
            coreDB.insMapSize = insMap.size();
            coreDB.trSize = memTracker.transactions.size();
    endtask


    // Event processing

    function automatic LateEvent getLateEvt(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word sr2 = getSysReg(2);
        Word sr3 = getSysReg(3);
        return getLateEvent(op, abs, sr2, sr3);
    endfunction

    task automatic activateEvent();
        LateEvent lateEvt;
    
        lateEventInfo <= EMPTY_EVENT_INFO;
    
        if (!csqEmpty) return;    

        lateEventInfoWaiting <= EMPTY_EVENT_INFO;

        if (!(lateEventInfoWaiting.op.active | lateEventInfoWaiting.reset | lateEventInfoWaiting.interrupt)) return;

        lateEvt = getLateEvt(lateEventInfoWaiting.op);

        if (lateEventInfoWaiting.op.active) begin
            modifyStateSync(sysRegs, lateEventInfoWaiting.op.adr, decAbs(lateEventInfoWaiting.op));               
            retiredTarget <= lateEvt.target;
            lateEventInfo <= '{lateEventInfoWaiting.op, 0, 0, lateEvt.redirect, getSendSignal(decAbs(lateEventInfoWaiting.op)), getWrongSignal(decAbs(lateEventInfoWaiting.op)), lateEvt.target};
        end
        else if (lateEventInfoWaiting.reset) begin
            saveStateAsync(sysRegs, retiredTarget);
            retiredTarget <= IP_RESET;
            lateEventInfo <= '{EMPTY_SLOT, 0, 1, 1, 0, 0, IP_RESET};
        end
        else if (lateEventInfoWaiting.interrupt) begin
            saveStateAsync(sysRegs, retiredTarget);
            retiredTarget <= IP_INT;
            lateEventInfo <= '{EMPTY_SLOT, 1, 0, 1, 0, 0, IP_INT};
        end
    endtask

    ////////////////

    task automatic drainWriteQueue();
       StoreQueueEntry sqe = csq.pop_front();

           drainHead <= csq[0];

       if (storeHead.op.active && isStoreSysIns(decAbs(storeHead.op))) setSysReg(storeHead.adr, storeHead.val);

       if (sqe.op.id == -1) return;

       if (isStoreIns(decAbs(sqe.op))) memTracker.drain(sqe.op);  // TODO: remove condition? Always satisfied for any CSQ op.

       putMilestone(sqe.op.id, InstructionMap::Drain);
       putMilestone(sqe.op.id, InstructionMap::WqExit);
    endtask

    task automatic putWrite();            
        if (csq.size() < 4) begin
            csq.push_back('{EMPTY_SLOT, 'x, 'x});
            csqEmpty <= 1;
        end
        else begin
            csqEmpty <= 0;
        end
        
        storeHead <= csq[3];
    endtask


    task automatic renameGroup(input OpSlotA ops);
        if (anyActive(ops))
            renameInds.renameG = (renameInds.renameG + 1) % (2*theRob.DEPTH);
    
        foreach (ops[i]) begin
            if (ops[i].active) begin
                renameOp(ops[i], i);
                putMilestone(ops[i].id, InstructionMap::Rename);
            end
        end
    endtask

    task automatic addToQueues(input OpSlot op);    
        if (isBranchIns(decAbs(op))) branchTargetQueue.push_back('{op.id, 'z});
    endtask

    // Frontend, rename and everything before getting to OOO queues
    task automatic runInOrderPartRe();
        renameGroup(theFrontend.stageRename0);
        stageRename1 <= theFrontend.stageRename0;
        
        foreach (stageRename1[i]) begin
            OpSlot op = stageRename1[i];
            if (op.active) addToQueues(op);
        end 
    endtask


    assign oooLevels.iqRegular = theIssueQueues.regularQueue.num;
    assign oooLevels.iqFloat = theIssueQueues.floatQueue.num;
    assign oooLevels.iqBranch = theIssueQueues.branchQueue.num;
    assign oooLevels.iqMem = theIssueQueues.memQueue.num;
    assign oooLevels.iqSys = theIssueQueues.sysQueue.num;
    
    assign oooAccepts = getBufferAccepts(oooLevels);
    assign iqsAccepting = iqsAccept(oooAccepts);

    assign fetchAllow = fetchQueueAccepts(theFrontend.fqSize) && bcQueueAccepts(bcqSize);
    assign renameAllow = iqsAccepting && regsAccept(nFreeRegsInt, nFreeRegsFloat)
                                                && theRob.allow && theSq.allow && theLq.allow;;

    function automatic IqLevels getBufferAccepts(input IqLevels levels);
        IqLevels res;
     
        res.iqRegular = levels.iqRegular <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH;
        res.iqFloat = levels.iqFloat <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH;
        res.iqBranch = levels.iqBranch <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH;
        res.iqMem = levels.iqMem <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH;
        res.iqSys = levels.iqSys <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH;

        return res;
    endfunction

    function automatic logic iqsAccept(input IqLevels acc);
        return 1
                && acc.iqRegular
                && acc.iqFloat
                && acc.iqBranch
                && acc.iqMem
                && acc.iqSys;
    endfunction


    // Helper (inline it?)
    function logic regsAccept(input int nI, input int nF);
        return nI > FETCH_WIDTH && nF > FETCH_WIDTH;
    endfunction

    // Helper (inline it?)
    function logic fetchQueueAccepts(input int k);
        return k <= FETCH_QUEUE_SIZE - 3; // 2 stages between IP stage and FQ
    endfunction

    function logic bcQueueAccepts(input int k);
        return k <= BC_QUEUE_SIZE - 3*FETCH_WIDTH - FETCH_QUEUE_SIZE*FETCH_WIDTH; // 2 stages + FETCH_QUEUE entries, FETCH_WIDTH each
    endfunction


    // $$Bufs
    // write queue is not flushed!
    task automatic flushOooBuffersAll();        
        flushBranchCheckpointQueueAll();
        flushBranchTargetQueueAll();
    endtask
    
    task automatic flushBranchCheckpointQueueAll();
        while (branchCheckpointQueue.size() > 0) void'(branchCheckpointQueue.pop_back());
    endtask    

    task automatic flushBranchTargetQueueAll();
        while (branchTargetQueue.size() > 0) void'(branchTargetQueue.pop_back());
    endtask
 
    task automatic flushBranchCheckpointQueuePartial(input OpSlot op);
        while (branchCheckpointQueue.size() > 0 && branchCheckpointQueue[$].op.id > op.id) void'(branchCheckpointQueue.pop_back());
    endtask    

    task automatic flushBranchTargetQueuePartial(input OpSlot op);
        while (branchTargetQueue.size() > 0 && branchTargetQueue[$].id > op.id) void'(branchTargetQueue.pop_back());
    endtask

    task automatic flushOooBuffersPartial(input OpSlot op);
        flushBranchCheckpointQueuePartial(op);
        flushBranchTargetQueuePartial(op);
    endtask

    task automatic rollbackToCheckpoint(input BranchCheckpoint single);
        renamedEmul.coreState = single.state;
        renamedEmul.tmpDataMem.copyFrom(single.mem);
        renameInds = single.inds;
    endtask

    task automatic rollbackToStable();    
        renamedEmul.setLike(retiredEmul);
        renameInds = commitInds;
    endtask


    task automatic redirectRest();
        stageRename1 <= '{default: EMPTY_SLOT};
        markKilledRenameStage(stageRename1);

        if (lateEventInfo.redirect) begin
            rollbackToStable(); // Rename stage

            flushOooBuffersAll();
            
            if (lateEventInfo.reset)
                registerTracker.restoreReset();
            else
                registerTracker.restoreStable();
                    
            registerTracker.flushAll();
            memTracker.flushAll();
            
            if (lateEventInfo.reset) begin
                sysRegs = SYS_REGS_INITIAL;
                renamedEmul.reset();
                retiredEmul.reset();
            end
        end
        else if (branchEventInfo.redirect) begin
            BranchCheckpoint foundCP[$] = AbstractCore.branchCheckpointQueue.find with (item.op.id == branchEventInfo.op.id);
            BranchCheckpoint causingCP = foundCP[0];
        
            rollbackToCheckpoint(causingCP); // Rename stage
        
            flushOooBuffersPartial(branchEventInfo.op);  
            
            registerTracker.restoreCP(causingCP.intMapR, causingCP.floatMapR, causingCP.intWriters, causingCP.floatWriters);
            registerTracker.flush(branchEventInfo.op);
            memTracker.flush(branchEventInfo.op);
        end
        
    endtask

    
    // Frontend/Rename

    task automatic markKilledRenameStage(ref OpSlotA stage);
        foreach (stage[i]) begin
            if (!stage[i].active) continue;
            putMilestone(stage[i].id, InstructionMap::FlushOOO);
            //insMap.setKilled(stage[i].id);
        end
    endtask

    task automatic saveCP(input OpSlot op);
        BranchCheckpoint cp = new(op, renamedEmul.coreState, renamedEmul.tmpDataMem,
                                    //registerTracker.wrTracker.intWritersR, registerTracker.wrTracker.floatWritersR,
                                    registerTracker.ints.writersR, registerTracker.floats.writersR,
                                    registerTracker.ints.MapR, registerTracker.floats.MapR,
                                    renameInds);
        branchCheckpointQueue.push_back(cp);
    endtask


    task automatic renameOp(input OpSlot op, input int currentSlot);
        AbstractInstruction ins = decAbs(op);
        Word result, target;
        InsDependencies deps;
        Word argVals[3];
        int physDest = -1;
        
        // For insMap and mem queues
        argVals = getArgs(renamedEmul.coreState.intRegs, renamedEmul.coreState.floatRegs, ins.sources, parsingMap[ins.fmt].typeSpec);
        result = computeResult(renamedEmul.coreState, op.adr, ins, renamedEmul.tmpDataMem); // Must be before modifying state. For ins map
        deps = registerTracker.getArgDeps(ins); // For insMap

        runInEmulator(renamedEmul, op.adr, op.bits);
        renamedEmul.drain();
        target = renamedEmul.coreState.target; // For insMap

        updateInds(renameInds, op); // Crucial state

        physDest = registerTracker.reserve(ins, op.id);
        
        if (isStoreIns(ins) || isLoadIns(ins)) memTracker.add(op, ins, argVals); // DB

        if (isBranchIns(decAbs(op))) begin
            saveCP(op); // Crucial state
        end

        insMap.setResult(op.id, result);
        insMap.setTarget(op.id, target);
        insMap.setDeps(op.id, deps);
        insMap.setPhysDest(op.id, physDest);
        insMap.setArgValues(op.id, argVals);
        
        insMap.setInds(op.id, renameInds);
        insMap.setSlot(op.id, currentSlot);

        coreDB.lastRenamed = op;
    endtask


        task automatic TMP_WQ();
            OpSlotA ops = theSq.outGroup;
            
            // TODO
        endtask


    function automatic logic breaksCommit(input OpSlot op);
        return (isSysIns(decAbs(op)) && !isStoreSysIns(decAbs(op)));
    endfunction

    function automatic logic breaksCommitId(input InsId id);
        return (isSysIns(decId(id)) && !isStoreSysIns(decId(id)));
    endfunction


    task automatic advanceCommit();
        logic cancelRest = 0;
        // Don't commit anything more if event is being handled
        if (interrupt || reset || lateEventInfoWaiting.redirect || lateEventInfo.redirect) return;

        foreach (robOut[i]) begin
            OpSlot opC = robOut[i];
            if (opC.active && !cancelRest) commitOp(opC);
            else if (opC.active && cancelRest) cancelOp(opC); // TODO: assert this never happens
            else continue;

            if (breaksCommit(opC)) cancelRest = 1;
        end
        
        insMap.commitCheck();
    endtask


    task automatic verifyOnCommit(input OpSlot op);
        InstructionInfo info = insMap.get(op.id);

        Word trg = retiredEmul.coreState.target; // DB
        Word nextTrg;
        Word bits = fetchInstruction(TMP_getP(), trg); // DB

        assert (trg === op.adr) else $fatal(2, "Commit: mm adr %h / %h", trg, op.adr);
        assert (bits === op.bits) else $fatal(2, "Commit: mm enc %h / %h", bits, op.bits);
        assert (info.argError === 0) else $fatal(2, "Arg error on op %d", op.id);

        if (hasIntDest(decAbs(op)) || hasFloatDest(decAbs(op))) // DB
            assert (info.actualResult === info.result) else $error(" not matching result. %p, %s; %d but should be %d", op, disasm(op.bits), info.actualResult, info.result);

        runInEmulator(retiredEmul, op.adr, op.bits);
        retiredEmul.drain();
        nextTrg = retiredEmul.coreState.target; // DB

        if (isBranchIns(decAbs(op))) // DB
            assert (branchTargetQueue[0].target === nextTrg) else $error("Mismatch in BQ id = %d, target: %h / %h", op.id, branchTargetQueue[0].target, nextTrg);
    endtask


    task automatic commitOp(input OpSlot opC);
        InstructionInfo insInfo = insMap.get(opC.id);
        OpSlot op = '{1, insInfo.id, insInfo.adr, insInfo.bits};
                
            committedState.last <= op.id; 
            
        assert (op.id == opC.id) else $error("no match: %d / %d", op.id, opC.id);

        verifyOnCommit(op);
        checkUnimplementedInstruction(decAbs(op));

        updateInds(commitInds, op); // Crucial
        commitInds.renameG = insMap.get(op.id).inds.renameG;

        registerTracker.commit(insInfo.dec, op.id);
        
        if (isStoreIns(decAbs(op))) begin
            Transaction tr = memTracker.findStore(op.id);
            StoreQueueEntry sqe = '{op, tr.adrAny, tr.val};
            
                committedState.lastWq <= op.id;
            
            csq.push_back(sqe);
            putMilestone(op.id, InstructionMap::WqEnter);
        end
        
        if (isStoreIns(decAbs(op)) || isLoadIns(decAbs(op))) memTracker.remove(op); // DB?
        if (isSysIns(decAbs(op))) setLateEvent(op); // Crucial state

        // Crucial state
        retiredTarget <= getCommitTarget(decAbs(op), retiredTarget, branchTargetQueue[0].target);        

        releaseQueues(op); // Crucial state

            coreDB.lastRetired = op;
            coreDB.nRetired++;
            
            putMilestone(op.id, InstructionMap::Retire);
            insMap.setRetired(op.id);
    endtask



    task automatic cancelOp(input OpSlot opC);
        InstructionInfo insInfo = insMap.get(opC.id);
        OpSlot op = '{1, insInfo.id, insInfo.adr, insInfo.bits};
                
        //    committedState.last <= op.id; 
            
        assert (op.id == opC.id) else $error("no match: %d / %d", op.id, opC.id);

        //verifyOnCommit(op);
        //checkUnimplementedInstruction(decAbs(op));

        //updateInds(commitInds, op); // Crucial
        //commitInds.renameG = insMap.get(op.id).inds.renameG;

        //registerTracker.commit(insInfo.dec, op.id);
        
        
        //if (isStoreIns(decAbs(op)) || isLoadIns(decAbs(op))) memTracker.remove(op); // DB?
        //if (isSysIns(decAbs(op))) setLateEvent(op); // Crucial state

        // Crucial state
        //retiredTarget <= getCommitTarget(decAbs(op), retiredTarget, branchTargetQueue[0].target);        

        //releaseQueues(op); // Crucial state

//            coreDB.lastRetired = op;
//            coreDB.nRetired++;
            
         $error(" cancel at commit %d", opC.id);
            
            putMilestone(op.id, InstructionMap::FlushCommit);
            //insMap.setKilled(op.id);
    endtask




    function automatic void updateInds(ref IndexSet inds, input OpSlot op);
        inds.rename = (inds.rename + 1) % (2*ROB_SIZE);
        if (isBranchIns(decAbs(op))) inds.bq = (inds.bq + 1) % (2*BC_QUEUE_SIZE);
        if (isLoadIns(decAbs(op))) inds.lq = (inds.lq + 1) % (2*LQ_SIZE);
        if (isStoreIns(decAbs(op))) inds.sq = (inds.sq + 1) % (2*SQ_SIZE);
    endfunction

    task automatic setLateEvent(input OpSlot op);    
        LateEvent evt = getLateEvt(op);
        lateEventInfoWaiting <= '{op, 0, 0, evt.redirect, 0, 0, evt.target};
    endtask

    task automatic releaseQueues(input OpSlot op);
        if (isBranchIns(decAbs(op))) begin // Br queue entry release
            BranchCheckpoint bce = branchCheckpointQueue.pop_front();
            BranchTargetEntry bte = branchTargetQueue.pop_front();
            assert (bce.op === op) else $error("Not matching op: %p / %p", bce.op, op);
            assert (bte.id === op.id) else $error("Not matching op id: %p / %d", bte, op.id);
        end
    endtask


    task automatic execReset();
         //   insMap.cleanDescs();
    
        lateEventInfoWaiting <= '{EMPTY_SLOT, 0, 1, 1, 0, 0, IP_RESET};
        performAsyncEvent(retiredEmul.coreState, IP_RESET, retiredEmul.coreState.target);
    endtask

    task automatic execInterrupt();
        $display(">> Interrupt !!!");
        lateEventInfoWaiting <= '{EMPTY_SLOT, 1, 0, 1, 0, 0, IP_INT};
        retiredEmul.interrupt();
    endtask

    
    
    task automatic completePacket(input OpPacket p);
        if (!p.active) return;
        else begin
            OpSlot os = getOpSlotFromPacket(p);
            writeResult(os, p.result);
            
            coreDB.lastCompleted = os;
            coreDB.nCompleted++;
        end
    endtask
    

    function automatic OpSlot getOpSlotFromId(input InsId id);
        OpSlot res;
        InstructionInfo ii = insMap.get(id);
        
        res.active = 1;
        res.id = id;
        res.adr = ii.adr;
        res.bits = ii.bits;
        
        return res;
    endfunction;

    function automatic OpSlot getOpSlotFromPacket(input OpPacket p);
        OpSlot res;
        InstructionInfo ii = insMap.get(p.id);
        
        res.active = p.active;
        res.id = p.id;
        res.adr = ii.adr;
        res.bits = ii.bits;
        
        return res;
    endfunction;


    function automatic Word getSysReg(input Word adr);
        return sysRegs[adr];
    endfunction

    function automatic void setSysReg(input Word adr, input Word val);
        sysRegs[adr] = val;
    endfunction

    task automatic writeResult(input OpSlot op, input Word value);
        if (!op.active) return;
        putMilestone(op.id, InstructionMap::WriteResult);
        registerTracker.writeValue(decAbs(op), op.id, value);
    endtask


    // General
    
    function automatic AbstractInstruction decAbs(input OpSlot op);
        if (!op.active || op.id == -1) return DEFAULT_ABS_INS;     
        return insMap.get(op.id).dec;
    endfunction

    function automatic AbstractInstruction decId(input InsId id);
        if (id == -1) return DEFAULT_ABS_INS;     
        return insMap.get(id).dec;
    endfunction

    function automatic Word getAdr(input InsId id);
        if (id == -1) return 'x;     
        return insMap.get(id).adr;
    endfunction
 

    function automatic void putMilestone(input InsId id, input InstructionMap::Milestone kind);
        insMap.putMilestone(id, kind, cycleCtr);
    endfunction




    function automatic OpPacket tickP(input OpPacket op);
        OpPacket res = op;
        
        if (shouldFlushPoison(op.poison)) begin
            putMilestone(op.id, InstructionMap::FlushPoison);
            return EMPTY_OP_PACKET;
        end
    
        // TODO: check whether op is nonempty before putting milestone on it?
        if (shouldFlushEvent(op.id)) begin 
            putMilestone(op.id, InstructionMap::FlushExec);
            return EMPTY_OP_PACKET;
        end
        return res;
    endfunction

    function automatic OpPacket effP(input OpPacket op);
        OpPacket res = op;

        if (shouldFlushPoison(op.poison))
            return EMPTY_OP_PACKET;
            
        if (shouldFlushEvent(op.id)) begin
            return EMPTY_OP_PACKET;
        end
        
        return res;
    endfunction


    function automatic logic shouldFlushEvent(input InsId id);
        return lateEventInfo.redirect || (branchEventInfo.redirect && id > branchEventInfo.op.id);
    endfunction

    function automatic logic checkMemDep(input Poison p, input ForwardingElement fe);
        if (fe.id != -1) begin
            int inds[$] = p.find with (item == fe.id);
            return inds.size() != 0;
        end
        return 0;
    endfunction

    function automatic logic shouldFlushPoison(input Poison poison);
        ForwardingElement memStage0[N_MEM_PORTS] = theExecBlock.memImagesTr[0];
        
        foreach (memStage0[p])
            if (checkMemDep(poison, memStage0[p]) && memStage0[p].status != ES_OK) return 1;
        
        return 0;
    endfunction



    assign insAdr = theFrontend.ipStage[0].adr;

    assign readReq[0] = TMP_readReqs[0].active;
    assign readAdr[0] = TMP_readReqs[0].adr;

    assign writeReq = writeInfo.req;
    assign writeAdr = writeInfo.adr;
    assign writeOut = writeInfo.value;

    assign sig = lateEventInfo.sigOk;
    assign wrong = lateEventInfo.sigWrong;

endmodule
