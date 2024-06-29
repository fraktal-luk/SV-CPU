
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;

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

    RobEntry rob[$:ROB_SIZE];
    LoadQueueEntry loadQueue[$:LQ_SIZE];
    StoreQueueEntry storeQueue[$:SQ_SIZE];
    //..............................
    
    int cycleCtr = 0;

    always @(posedge clk) cycleCtr++;

    // Overall
    logic fetchAllow, renameAllow, buffersAccepting, csqEmpty = 0;
    BufferLevels oooLevels, oooLevels_N, oooAccepts;

    int nFreeRegsInt = 0, nFreeRegsFloat = 0, bcqSize = 0;

    // OOO
    IndexSet renameInds = '{default: 0}, commitInds = '{default: 0};

    // Exec
    logic intRegsReadyV[N_REGS_INT] = '{default: 'x};
    logic floatRegsReadyV[N_REGS_FLOAT] = '{default: 'x};


    EventInfo branchEventInfo = EMPTY_EVENT_INFO,
              lateEventInfo = EMPTY_EVENT_INFO, lateEventInfoWaiting = EMPTY_EVENT_INFO;
    Events evts;

    BranchCheckpoint branchCP;

    MemWriteInfo readInfo = EMPTY_WRITE_INFO; // Exec

    
    // Store interface
        // Committed
        StoreQueueEntry csq[$] = '{'{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}};
        StoreQueueEntry storeHead = '{EMPTY_SLOT, 'x, 'x};
        MemWriteInfo writeInfo; // Committed
    
    // Event control
        // Control
        Word sysRegs[32];
        Word retiredTarget = 0;


    OpSlotA robOut;

    ///////////////////////////

    Frontend theFrontend(insMap, branchEventInfo, lateEventInfo);

    // Rename
    OpSlotA stageRename1 = '{default: EMPTY_SLOT};

    ReorderBuffer theRob(insMap, branchEventInfo, lateEventInfo, stageRename1, robOut);
    StoreQueue#(.SIZE(SQ_SIZE))
        theSq(insMap, branchEventInfo, lateEventInfo, stageRename1);
    StoreQueue#(.IS_LOAD_QUEUE(1), .SIZE(LQ_SIZE))
        theLq(insMap, branchEventInfo, lateEventInfo, stageRename1);
    StoreQueue#(.IS_BRANCH_QUEUE(1), .SIZE(BQ_SIZE))
        theBq(insMap, branchEventInfo, lateEventInfo, stageRename1);

    IssueQueueComplex theIssueQueues(insMap, branchEventInfo, lateEventInfo, stageRename1);

    ExecBlock theExecBlock(insMap, branchEventInfo, lateEventInfo);

    ///////////////////////////////////////////


    always @(posedge clk) begin
            insMap.endCycle();
    
        activateEvent();

        drainWriteQueue();
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
        
        updateBookkeeping();
    end


    assign insAdr = theFrontend.ipStage[0].adr;

    assign    oooLevels_N.iqRegular = theIssueQueues.regularQueue.num;
    assign    oooLevels_N.iqFloat = theIssueQueues.floatQueue.num;
    assign    oooLevels_N.iqBranch = theIssueQueues.branchQueue.num;
    assign    oooLevels_N.iqMem = theIssueQueues.memQueue.num;
    assign    oooLevels_N.iqSys = theIssueQueues.sysQueue.num;


    task automatic handleCompletion();
        foreach (theExecBlock.doneOpsRegular_E[i]) begin
            completeOp(theExecBlock.doneOpsRegular_E[i]);
            writeResult(theExecBlock.doneOpsRegular_E[i], theExecBlock.execResultsRegular[i]);
        end

        foreach (theExecBlock.doneOpsFloat_E[i]) begin
            completeOp(theExecBlock.doneOpsFloat_E[i]);
            writeResult(theExecBlock.doneOpsFloat_E[i], theExecBlock.execResultsFloat[i]);
        end
                    
        completeOp(theExecBlock.doneOpBranch_E);
        writeResult(theExecBlock.doneOpBranch_E, theExecBlock.execResultLink);

        completeOp(theExecBlock.doneOpMem_E);
        writeResult(theExecBlock.doneOpMem_E, theExecBlock.execResultMem);

        completeOp(theExecBlock.doneOpSys_E);
    endtask

    task automatic updateBookkeeping();
        bcqSize <= branchCheckpointQueue.size();
        oooLevels <= getBufferLevels();
        
        nFreeRegsInt <= registerTracker.getNumFreeInt();
        nFreeRegsFloat <= registerTracker.getNumFreeFloat();
        
        intRegsReadyV <= registerTracker.intReady;
        floatRegsReadyV <= registerTracker.floatReady;

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
       StoreQueueEntry sqe;
       if (storeHead.op.active && isStoreSysOp(storeHead.op)) setSysReg(storeHead.adr, storeHead.val);
       sqe = csq.pop_front();
       putMilestone(sqe.op.id, InstructionMap::Drain);
    endtask

    task automatic putWrite();            
        if (csq.size() < 4) begin
            csq.push_back('{EMPTY_SLOT, 'x, 'x});
            csqEmpty <= 1;
        end
        else csqEmpty <= 0;
        
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
        rob.push_back('{op});      
        if (isLoadIns(decAbs(op))) loadQueue.push_back('{op});
        if (isStoreIns(decAbs(op))) storeQueue.push_back('{op, 'x, 'x});
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
    
    
    assign oooAccepts = getBufferAccepts(oooLevels, oooLevels_N);
    assign buffersAccepting = buffersAccept(oooAccepts);

    assign fetchAllow = fetchQueueAccepts(theFrontend.fqSize) && bcQueueAccepts(bcqSize);
    assign renameAllow = buffersAccepting && regsAccept(nFreeRegsInt, nFreeRegsFloat)
                                                && theRob.allow && theSq.allow && theLq.allow;;

    assign writeInfo = '{storeHead.op.active && isStoreMemIns(decAbs(storeHead.op)), storeHead.adr, storeHead.val};

    assign readReq[0] = readInfo.req;
    assign readAdr[0] = readInfo.adr;

    assign writeReq = writeInfo.req;
    assign writeAdr = writeInfo.adr;
    assign writeOut = writeInfo.value;

    assign sig = lateEventInfo.sigOk;
    assign wrong = lateEventInfo.sigWrong;


    // Helper (inline it?)
    function logic fetchQueueAccepts(input int k);
        return k <= FETCH_QUEUE_SIZE - 3; // 2 stages between IP stage and FQ
    endfunction
    
    function logic bcQueueAccepts(input int k);
        return k <= BC_QUEUE_SIZE - 3*FETCH_WIDTH - FETCH_QUEUE_SIZE*FETCH_WIDTH; // 2 stages + FETCH_QUEUE entries, FETCH_WIDTH each
    endfunction

    function automatic BufferLevels getBufferLevels();
        BufferLevels res;
        res.oooq = 0;//oooQueue.size();
        res.rob = rob.size();
        res.lq = loadQueue.size();
        res.sq = storeQueue.size();
        return res;
    endfunction

    function automatic BufferLevels getBufferAccepts(input BufferLevels levels, input BufferLevels levels_N);
        BufferLevels res;
        
            res.iqRegular = levels_N.iqRegular <= OP_QUEUE_SIZE - 3*FETCH_WIDTH;
            res.iqFloat = levels_N.iqFloat <= OP_QUEUE_SIZE - 3*FETCH_WIDTH;
            res.iqBranch = levels_N.iqBranch <= OP_QUEUE_SIZE - 3*FETCH_WIDTH;
            res.iqMem = levels_N.iqMem <= OP_QUEUE_SIZE - 3*FETCH_WIDTH;
            res.iqSys = levels_N.iqSys <= OP_QUEUE_SIZE - 3*FETCH_WIDTH;
        
        res.oooq = 1;//levels.oooq <= OOO_QUEUE_SIZE - 3*FETCH_WIDTH;
        res.rob = levels.rob <= ROB_SIZE - 3*FETCH_WIDTH;
        res.lq = levels.lq <= LQ_SIZE - 3*FETCH_WIDTH;
        res.sq = levels.sq <= SQ_SIZE - 3*FETCH_WIDTH;
        res.csq = 1;
        return res;
    endfunction

    function automatic logic buffersAccept(input BufferLevels acc);
        return 1 //acc.oq
                && acc.iqRegular
                && acc.iqFloat
                && acc.iqBranch
                && acc.iqMem
                && acc.iqSys
                                  && acc.rob && acc.lq && acc.sq && acc.csq;
    endfunction
  
    // Helper (inline it?)
    function logic regsAccept(input int nI, input int nF);
        return nI > FETCH_WIDTH && nF > FETCH_WIDTH;
    endfunction
    
    
    // $$Bufs
    // write queue is not flushed!
    task automatic flushOooBuffersAll();        
        flushBranchCheckpointQueueAll();
        flushBranchTargetQueueAll();
        flushRobAll();
        flushStoreQueueAll();
        flushLoadQueueAll();
    endtask
    
    task automatic flushBranchCheckpointQueueAll();
        while (branchCheckpointQueue.size() > 0) void'(branchCheckpointQueue.pop_back());
    endtask    

    task automatic flushBranchTargetQueueAll();
        while (branchTargetQueue.size() > 0) void'(branchTargetQueue.pop_back());
    endtask

    task automatic flushRobAll();
        while (rob.size() > 0) begin
            RobEntry entry = (rob.pop_back());
            putMilestone(entry.op.id, InstructionMap::FlushOOO);
            insMap.setKilled(entry.op.id);
        end
    endtask
 
    task automatic flushLoadQueueAll();
        while (loadQueue.size() > 0) void'(loadQueue.pop_back());
    endtask
   
    task automatic flushStoreQueueAll();
        while (storeQueue.size() > 0) void'(storeQueue.pop_back());
    endtask
 
    task automatic flushBranchCheckpointQueuePartial(input OpSlot op);
        while (branchCheckpointQueue.size() > 0 && branchCheckpointQueue[$].op.id > op.id) void'(branchCheckpointQueue.pop_back());
    endtask    

    task automatic flushBranchTargetQueuePartial(input OpSlot op);
        while (branchTargetQueue.size() > 0 && branchTargetQueue[$].id > op.id) void'(branchTargetQueue.pop_back());
    endtask

    task automatic flushRobPartial(input OpSlot op);
        while (rob.size() > 0 && rob[$].op.id > op.id) begin
            RobEntry entry = (rob.pop_back());
            putMilestone(entry.op.id, InstructionMap::FlushOOO);
            insMap.setKilled(entry.op.id);
        end
    endtask

    task automatic flushLoadQueuePartial(input OpSlot op);
        while (loadQueue.size() > 0 && loadQueue[$].op.id > op.id) void'(loadQueue.pop_back());
    endtask
   
    task automatic flushStoreQueuePartial(input OpSlot op);
        while (storeQueue.size() > 0 && storeQueue[$].op.id > op.id) void'(storeQueue.pop_back());
    endtask


    task automatic flushOooBuffersPartial(input OpSlot op);
        flushBranchCheckpointQueuePartial(op);
        flushBranchTargetQueuePartial(op);
        flushRobPartial(op);
        flushStoreQueuePartial(op);
        flushLoadQueuePartial(op);
    endtask


    task automatic rollbackToCheckpoint();
        BranchCheckpoint single = branchCP;
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
            rollbackToCheckpoint(); // Rename stage
        
            flushOooBuffersPartial(branchEventInfo.op);  
            
            registerTracker.restoreCP(branchCP.intMapR, branchCP.floatMapR, branchCP.intWriters, branchCP.floatWriters);
            registerTracker.flush(branchEventInfo.op);
            memTracker.flush(branchEventInfo.op);
        end
        
    endtask

    
    // Frontend/Rename
    task automatic markKilledFrontStage(ref Stage_N stage);
        foreach (stage[i]) begin
            if (!stage[i].active) continue;
            putMilestone(stage[i].id, InstructionMap::FlushFront);
            insMap.setKilled(stage[i].id);
        end
    endtask

    task automatic markKilledRenameStage(ref Stage_N stage);
        foreach (stage[i]) begin
            if (!stage[i].active) continue;
            putMilestone(stage[i].id, InstructionMap::FlushOOO);
            insMap.setKilled(stage[i].id);
        end
    endtask

    task automatic saveCP(input OpSlot op);
        BranchCheckpoint cp = new(op, renamedEmul.coreState, renamedEmul.tmpDataMem,
                                    registerTracker.wrTracker.intWritersR, registerTracker.wrTracker.floatWritersR,
                                    registerTracker.intMapR, registerTracker.floatMapR,
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
        deps = getPhysicalArgs_N(op, registerTracker); // For insMap

        runInEmulator(renamedEmul, op);
        renamedEmul.drain();
        target = renamedEmul.coreState.target; // For insMap

        updateInds(renameInds, op); // Crucial state

        physDest = registerTracker.reserve(op);
        if (isMemOp(op)) memTracker.add(op, ins, argVals); // DB

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


    task automatic advanceCommit();
        // Don't commit anything more if event is being handled
        if (interrupt || reset || lateEventInfoWaiting.redirect || lateEventInfo.redirect) return;

        foreach (robOut[i]) begin
            OpSlot opC = robOut[i];
            if (opC.active) commitOp(opC);
            else continue;

            if (isSysIns(decAbs(opC)) && !isStoreSysIns(decAbs(opC))) break;
        end
    endtask



    task automatic verifyOnCommit(input OpSlot op);
        InstructionInfo info = insMap.get(op.id);

        Word trg = retiredEmul.coreState.target; // DB
        Word nextTrg;
        Word bits = fetchInstruction(TMP_getP(), trg); // DB

        assert (trg === op.adr) else $fatal(2, "Commit: mm adr %h / %h", trg, op.adr);
        assert (bits === op.bits) else $fatal(2, "Commit: mm enc %h / %h", bits, op.bits);
        assert (info.argError === 0) else $fatal(2, "Arg error on op %d", op.id);

        if (writesIntReg(op) || writesFloatReg(op)) // DB
            assert (info.actualResult === info.result) else $error(" not matching result. %p, %s", op, disasm(op.bits));

        runInEmulator(retiredEmul, op);
        retiredEmul.drain();
        nextTrg = retiredEmul.coreState.target; // DB

        if (isBranchIns(decAbs(op))) // DB
            assert (branchTargetQueue[0].target === nextTrg) else $error("Mismatch in BQ id = %d, target: %h / %h", op.id, branchTargetQueue[0].target, nextTrg);
    endtask


    task automatic commitOp(input OpSlot opC);
        InstructionInfo insInfo = insMap.get(opC.id);
        OpSlot op = '{1, insInfo.id, insInfo.adr, insInfo.bits};
        //OpSlot op = takeFrontOp(opC);

        assert (op.id == opC.id) else $error("no match: %d / %d", op.id, opC.id);

        verifyOnCommit(op);
        checkUnimplementedInstruction(decAbs(op));

        updateInds(commitInds, op); // Crucial
            commitInds.renameG = insMap.get(op.id).inds.renameG;

        registerTracker.commit(op);
        if (isMemOp(op)) memTracker.remove(op); // DB?

        if (isStoreIns(decAbs(op))) csq.push_back(storeQueue[0]); // Crucial state
        if (isSysIns(decAbs(op))) setLateEvent(op); // Crucial state

        // Crucial state
        retiredTarget <= getCommitTarget(decAbs(op), retiredTarget, branchTargetQueue[0].target);        

        releaseQueues(op); // Crucial state

            coreDB.lastRetired = op;
            coreDB.nRetired++;
            
            putMilestone(op.id, InstructionMap::Retire);
            insMap.setRetired(op.id);
            insMap.verifyMilestones(op.id);
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
        RobEntry re = rob.pop_front();
        assert (re.op === op) else $error("Not matching op: %p / %p", re.op, op);
        
        if (isBranchIns(decAbs(op))) begin // Br queue entry release
            BranchCheckpoint bce = branchCheckpointQueue.pop_front();
            BranchTargetEntry bte = branchTargetQueue.pop_front();
            assert (bce.op === op) else $error("Not matching op: %p / %p", bce.op, op);
            assert (bte.id === op.id) else $error("Not matching op id: %p / %d", bte, op.id);
        end
        
        if (isLoadIns(decAbs(op))) begin
            LoadQueueEntry lqe = loadQueue.pop_front();
            assert (lqe.op === op) else $error("Not matching op: %p / %p", lqe.op, op);
        end
        
        if (isStoreIns(decAbs(op))) begin // Br queue entry release
            StoreQueueEntry sqe = storeQueue.pop_front();
            assert (sqe.op === op) else $error("Not matching op: %p / %p", sqe.op, op);
        end
    endtask


    task automatic execReset();
            insMap.cleanDescs();
    
        lateEventInfoWaiting <= '{EMPTY_SLOT, 0, 1, 1, 0, 0, IP_RESET};
        performAsyncEvent(retiredEmul.coreState, IP_RESET, retiredEmul.coreState.target);
    endtask

    task automatic execInterrupt();
        $display(">> Interrupt !!!");
        lateEventInfoWaiting <= '{EMPTY_SLOT, 1, 0, 1, 0, 0, IP_INT};
        retiredEmul.interrupt();
    endtask

    
    task automatic completeOp(input OpSlot op);            
        if (!op.active) return;

        putMilestone(op.id, InstructionMap::Complete); 

            coreDB.lastCompleted = op;
            coreDB.nCompleted++;
    endtask


    function automatic Word getSysReg(input Word adr);
        return sysRegs[adr];
    endfunction

    function automatic void setSysReg(input Word adr, input Word val);
        sysRegs[adr] = val;
    endfunction

    task automatic writeResult(input OpSlot op, input Word value);
        if (!op.active) return;

        putMilestone(op.id, InstructionMap::WriteResult);

        if (writesIntReg(op)) begin
            registerTracker.setReadyInt(op.id);
            registerTracker.writeValueInt(op, value);
        end
        if (writesFloatReg(op)) begin
            registerTracker.setReadyFloat(op.id);
            registerTracker.writeValueFloat(op, value);
        end
    endtask


    // General
    
    function automatic AbstractInstruction decAbs(input OpSlot op);
        if (!op.active || op.id == -1) return DEFAULT_ABS_INS;     
        return insMap.get(op.id).dec;
    endfunction

    function automatic void putMilestone(input int id, input InstructionMap::Milestone kind);
        insMap.putMilestone(id, kind, cycleCtr);
    endfunction

    function automatic OpSlot tick(input OpSlot op);
        if (lateEventInfo.redirect || (branchEventInfo.redirect && op.id > branchEventInfo.op.id)) begin
            putMilestone(op.id, InstructionMap::FlushExec);
            return EMPTY_SLOT;
        end
        return op;
    endfunction

    function automatic OpSlot eff(input OpSlot op);
        if (lateEventInfo.redirect || (branchEventInfo.redirect && op.id > branchEventInfo.op.id))
            return EMPTY_SLOT;
        return op;
    endfunction


    // Exec/(Issue) - arg handling

    function automatic logic3 checkArgsReady(input InsDependencies deps);
        logic3 res;
        
        foreach (deps.types[i])
            case (deps.types[i])
                SRC_ZERO:  res[i] = 1;
                SRC_CONST: res[i] = 1;
                SRC_INT:   res[i] = intRegsReadyV[deps.sources[i]];
                SRC_FLOAT: res[i] = floatRegsReadyV[deps.sources[i]];
            endcase      
        return res;
    endfunction

    function automatic logic3 checkForwardsReady(input InsDependencies deps, input int stage);
        logic3 res;
        foreach (deps.types[i])
            case (deps.types[i])
                SRC_ZERO:  res[i] = 0;
                SRC_CONST: res[i] = 0;
                SRC_INT:   res[i] = checkForwardInt(deps.producers[i], deps.sources[i], theExecBlock.intImagesTr[stage], theExecBlock.memImagesTr[stage]);
                SRC_FLOAT: res[i] = checkForwardVec(deps.producers[i], deps.sources[i], theExecBlock.floatImagesTr[stage]);
            endcase      
        return res;
    endfunction

    function automatic Word3 getForwardedValues(input InsDependencies deps, input int stage);
        Word3 res;
        foreach (deps.types[i])
            case (deps.types[i])
                SRC_ZERO:  res[i] = 0;
                SRC_CONST: res[i] = 0;
                SRC_INT:   res[i] = getForwardValueInt(deps.producers[i], deps.sources[i], theExecBlock.intImagesTr[stage], theExecBlock.memImagesTr[stage]);
                SRC_FLOAT: res[i] = getForwardValueVec(deps.producers[i], deps.sources[i], theExecBlock.floatImagesTr[stage]);
            endcase      
        return res;
    endfunction


    function automatic logic matchProducer(input ForwardingElement fe, input InsId producer);
        return !(fe.id == -1) && fe.id === producer;
    endfunction

    function automatic Word useForwardedValue(input ForwardingElement fe, input int source, input InsId producer);
        InstructionInfo ii = insMap.get(fe.id);
        assert (ii.physDest === source) else $fatal(2, "Not correct match, should be %p:", producer);
        return ii.actualResult;
    endfunction

    function automatic logic useForwardingMatch(input ForwardingElement fe, input int source, input InsId producer);
        InstructionInfo ii = insMap.get(fe.id);
        assert (ii.physDest === source) else $fatal(2, "Not correct match, should be %p:", producer);
        return 1;
    endfunction


    function automatic Word getForwardValueVec(input InsId producer, input int source, input ForwardingElement feVec[N_VEC_PORTS]);
        foreach (feVec[p]) begin
            if (matchProducer(feVec[p], producer)) return useForwardedValue(feVec[p], source, producer);
        end
        return 'x;
    endfunction;

    function automatic Word getForwardValueInt(input InsId producer, input int source, input ForwardingElement feInt[N_INT_PORTS], input ForwardingElement feMem[N_MEM_PORTS]);
        foreach (feInt[p]) begin
            if (matchProducer(feInt[p], producer)) return useForwardedValue(feInt[p], source, producer);
        end
        
        foreach (feMem[p]) begin
            if (matchProducer(feMem[p], producer)) return useForwardedValue(feMem[p], source, producer);
        end

        return 'x;
    endfunction;


    function automatic logic checkForwardVec(input InsId producer, input int source, input ForwardingElement feVec[N_VEC_PORTS]);
        foreach (feVec[p]) begin
            if (matchProducer(feVec[p], producer)) return useForwardingMatch(feVec[p], source, producer);
        end
        return 0;
    endfunction;

    function automatic logic checkForwardInt(input InsId producer, input int source, input ForwardingElement feInt[N_INT_PORTS], input ForwardingElement feMem[N_MEM_PORTS]);
        foreach (feInt[p]) begin
            if (matchProducer(feInt[p], producer)) return useForwardingMatch(feInt[p], source, producer);
        end
        
        foreach (feMem[p]) begin
            if (matchProducer(feMem[p], producer)) return useForwardingMatch(feMem[p], source, producer);
        end

        return 0;
    endfunction;

endmodule
