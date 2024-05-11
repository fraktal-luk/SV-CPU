
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;




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


    InstructionMap insMap = new();
    Emulator renamedEmul = new(), retiredEmul = new();

    int cycleCtr = 0;

    always @(posedge clk) cycleCtr++;


    // Overall
    int nFreeRegsInt = 0, nFreeRegsFloat = 0, bcqSize = 0;
    int insMapSize = 0, trSize = 0, nCompleted = 0, nRetired = 0;

    logic fetchAllow, renameAllow, buffersAccepting, csqEmpty = 0;

    AbstractInstruction eventIns;
    EventInfo branchEventInfo = EMPTY_EVENT_INFO,
              lateEventInfo = EMPTY_EVENT_INFO, lateEventInfoWaiting = EMPTY_EVENT_INFO;
    BranchCheckpoint branchCP;

    RegisterTracker #(N_REGS_INT, N_REGS_FLOAT) registerTracker = new();
    MemTracker memTracker = new();


    Events evts;
    BufferLevels oooLevels, oooLevels_N, oooLevels_N2, oooAccepts;


    // OOO
    IndexSet renameInds = '{default: 0}, commitInds = '{default: 0};
        int currentSlot;

    BranchTargetEntry branchTargetQueue[$:BC_QUEUE_SIZE];
    BranchCheckpoint branchCheckpointQueue[$:BC_QUEUE_SIZE];

    OpStatus oooQueue[$:OOO_QUEUE_SIZE];

    RobEntry rob[$:ROB_SIZE];
    LoadQueueEntry loadQueue[$:LQ_SIZE];
    StoreQueueEntry storeQueue[$:SQ_SIZE];

    logic intRegsReadyV[N_REGS_INT] = '{default: 'x};
    logic floatRegsReadyV[N_REGS_FLOAT] = '{default: 'x};

    // Committed
    StoreQueueEntry csq_N[$] = '{'{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}};
    StoreQueueEntry storeHead = '{EMPTY_SLOT, 'x, 'x};

    MemWriteInfo writeInfo, // Committed
                 readInfo = EMPTY_WRITE_INFO; // Exec

    // Control
    Word sysRegs_N[32];  
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


    // DB
    OpSlot lastRenamed = EMPTY_SLOT, lastCompleted = EMPTY_SLOT, lastRetired = EMPTY_SLOT;
    string lastRenamedStr, lastCompletedStr, lastRetiredStr, oooqStr;

        IssueGroup issued_T0, issued_T1;
        
        assign issued_T0 = theExecBlock.issuedSt0;
        assign issued_T1 = theIssueQueues.ig;

    logic cmp0, cmp1;
    Word cmpw0, cmpw1, cmpw2, cmpw3;
        string iqRegularStr;
        string iqRegularStrA[OP_QUEUE_SIZE];

            assign cmp0 = theExecBlock.doneOpsRegular[0] === theExecBlock.regular0.doneOp;

    always @(posedge clk) begin
                cmp1 = cmp0;
    
        activateEvent();

        drainWriteQueue();
        advanceOOOQ();        
        putWrite();

        if (reset) execReset();
        else if (interrupt) execInterrupt();


        if (lateEventInfo.redirect || branchEventInfo.redirect)
            redirectRest();
        else
            runInOrderPartRe();


        // Complete + write regs
        begin
            foreach (theExecBlock.doneOpsRegular_E[i]) begin
                completeOp(theExecBlock.doneOpsRegular_E[i]);
                writeResult(theExecBlock.doneOpsRegular_E[i], theExecBlock.execResultsRegular[i]);
            end
            
            completeOp(theExecBlock.doneOpBranch_E);
            writeResult(theExecBlock.doneOpBranch_E, theExecBlock.execResultLink);
    
            completeOp(theExecBlock.doneOpMem_E);
            writeResult(theExecBlock.doneOpMem_E, theExecBlock.execResultMem);
    
            completeOp(theExecBlock.doneOpSys_E);
        end
        
        updateBookkeeping();
    end


    assign insAdr = theFrontend.ipStage[0].adr;

    
    task automatic updateBookkeeping();
        bcqSize <= branchCheckpointQueue.size();
        oooLevels <= getBufferLevels();
        
        nFreeRegsInt <= registerTracker.getNumFreeInt();
        nFreeRegsFloat <= registerTracker.getNumFreeFloat();
        
        intRegsReadyV <= registerTracker.intReady;
        floatRegsReadyV <= registerTracker.floatReady;

        // Overall DB
            insMapSize = insMap.size();
            trSize = memTracker.transactions.size();
    endtask


    function automatic LateEvent getLateEvt(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word sr2 = getSysReg(2);
        Word sr3 = getSysReg(3);
        return getLateEvent(op, abs, sr2, sr3);
    endfunction

    function automatic logic getLateRedirect(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word sr2 = getSysReg(2);
        Word sr3 = getSysReg(3);
        return getLateEvent(op, abs, sr2, sr3).redirect;
    endfunction

    function automatic Word getLateTarget(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word sr2 = getSysReg(2);
        Word sr3 = getSysReg(3);
        return getLateEvent(op, abs, sr2, sr3).target;
    endfunction



    task automatic activateEvent();
        lateEventInfo <= EMPTY_EVENT_INFO;
    
        if (!csqEmpty) return;    

        lateEventInfoWaiting <= EMPTY_EVENT_INFO;

        if (lateEventInfoWaiting.op.active) begin
            modifyStateSync(sysRegs_N, lateEventInfoWaiting.op.adr, decAbs(lateEventInfoWaiting.op));               
            retiredTarget <= getLateTarget(lateEventInfoWaiting.op);
            lateEventInfo <= '{lateEventInfoWaiting.op, 0, 0, getLateRedirect(lateEventInfoWaiting.op), getLateTarget(lateEventInfoWaiting.op)};
        end
        else if (lateEventInfoWaiting.reset) begin
            saveStateAsync(sysRegs_N, retiredTarget);
            retiredTarget <= IP_RESET;
            lateEventInfo <= '{EMPTY_SLOT, 0, 1, 1, IP_RESET};
        end
        else if (lateEventInfoWaiting.interrupt) begin
            saveStateAsync(sysRegs_N, retiredTarget);
            retiredTarget <= IP_INT;
            lateEventInfo <= '{EMPTY_SLOT, 1, 0, 1, IP_INT};
        end
    endtask


    task automatic drainWriteQueue();
        StoreQueueEntry sqe;
       if (storeHead.op.active && isStoreSysOp(storeHead.op)) setSysReg(storeHead.adr, storeHead.val);
       sqe = csq_N.pop_front();
       putMilestone(sqe.op.id, InstructionMap::Drain);
    endtask


    task automatic advanceOOOQ();
        // Don't commit anything more if event is being handled
        if (interrupt || reset || lateEventInfoWaiting.redirect || lateEventInfo.redirect) return;

        while (oooQueue.size() > 0 //&& oooQueue[0].done == 1
                    && oooQueue[0].id <= theRob.lastOut
                ) begin
            OpSlot op = takeFrontOp();
            commitOp(op);
            putMilestone(op.id, InstructionMap::Retire);
            insMap.setRetired(op.id);
                insMap.verifyMilestones(op.id);
            
            if (isSysIns(decAbs(op)) && !isStoreSysIns(decAbs(op))) break;
        end
    endtask

    task automatic putWrite();            
        if (csq_N.size() < 4) begin
            csq_N.push_back('{EMPTY_SLOT, 'x, 'x});
            csqEmpty <= 1;
        end
        else csqEmpty <= 0;
        
        storeHead <= csq_N[3];
    endtask



    task automatic renameGroup(input OpSlotA ops);
        
        
        if (anyActive(ops))
            renameInds.renameG = (renameInds.renameG + 1) % (2*theRob.DEPTH);
    
        currentSlot = 0;
        foreach (ops[i]) begin
            if (ops[i].active) begin
                renameOp(ops[i]);
                putMilestone(ops[i].id, InstructionMap::Rename);
            end
            currentSlot++;
        end
    endtask

    task automatic addToQueues(input OpSlot op);
        oooQueue.push_back('{op.id, 0});   
    
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
            if (op.active)
                addToQueues(op);
        end 
    endtask
    
    
    assign oooAccepts = getBufferAccepts(oooLevels, oooLevels_N);
    assign buffersAccepting = buffersAccept(oooAccepts);

    assign fetchAllow = fetchQueueAccepts(theFrontend.fqSize) && bcQueueAccepts(bcqSize);
    assign renameAllow = buffersAccepting && regsAccept(nFreeRegsInt, nFreeRegsFloat)
                                                && theRob.allow && theSq.allow && theLq.allow;;

    assign writeInfo = '{storeHead.op.active && isStoreMemIns(decAbs(storeHead.op)), storeHead.adr, storeHead.val};

    assign writeReq = writeInfo.req;
    assign writeAdr = writeInfo.adr;
    assign writeOut = writeInfo.value;

    assign eventIns = decAbs(lateEventInfo.op);
    assign sig = lateEventInfo.op.active && (eventIns.def.o == O_send);
    assign wrong = lateEventInfo.op.active && (eventIns.def.o == O_undef);
    
    assign readReq[0] = readInfo.req;
    assign readAdr[0] = readInfo.adr;



    function logic fetchQueueAccepts(input int k);
        return k <= FETCH_QUEUE_SIZE - 3; // 2 stages between IP stage and FQ
    endfunction
    
    function logic bcQueueAccepts(input int k);
        return k <= BC_QUEUE_SIZE - 3*FETCH_WIDTH - FETCH_QUEUE_SIZE*FETCH_WIDTH; // 2 stages + FETCH_QUEUE entries, FETCH_WIDTH each
    endfunction


    function automatic BufferLevels getBufferLevels();
        BufferLevels res;
        res.oooq = oooQueue.size();
        //res.bq = branchCheckpointQueue.size();
        res.rob = rob.size();
        res.lq = loadQueue.size();
        res.sq = storeQueue.size();
        //res.csq = committedStoreQueue.size();
        return res;
    endfunction

    function automatic BufferLevels getBufferAccepts(input BufferLevels levels, input BufferLevels levels_N);
        BufferLevels res;
        
        res.oq = levels_N.oq <= OP_QUEUE_SIZE - 3*FETCH_WIDTH;
            res.iqRegular = levels_N.iqRegular <= OP_QUEUE_SIZE - 3*FETCH_WIDTH;
            res.iqBranch = levels_N.iqBranch <= OP_QUEUE_SIZE - 3*FETCH_WIDTH;
            res.iqMem = levels_N.iqMem <= OP_QUEUE_SIZE - 3*FETCH_WIDTH;
            res.iqSys = levels_N.iqSys <= OP_QUEUE_SIZE - 3*FETCH_WIDTH;
        
        res.oooq = levels.oooq <= OOO_QUEUE_SIZE - 3*FETCH_WIDTH;
        //res.bq = levels.bq <= BC_QUEUE_SIZE - 3*FETCH_WIDTH - FETCH_QUEUE_SIZE*FETCH_WIDTH; // 2 stages + FETCH_QUEUE entries, FETCH_WIDTH each
        res.rob = levels.rob <= ROB_SIZE - 3*FETCH_WIDTH;
        res.lq = levels.lq <= LQ_SIZE - 3*FETCH_WIDTH;
        res.sq = levels.sq <= SQ_SIZE - 3*FETCH_WIDTH;
        res.csq = 1;//committedStoreQueue.size();
        return res;
    endfunction

    function automatic logic buffersAccept(input BufferLevels acc);
        return 1 //acc.oq
                && acc.iqRegular
                && acc.iqBranch
                && acc.iqMem
                && acc.iqSys
                     && acc.oooq //&& acc.bq 
                                  && acc.rob && acc.lq && acc.sq && acc.csq;
    endfunction
  
    function logic regsAccept(input int nI, input int nF);
        return nI > FETCH_WIDTH && nF > FETCH_WIDTH;
    endfunction
    
    
    // $$Bufs
    // write queue is not flushed!
    task automatic flushOooBuffersAll();        
        flushOooQueueAll();
        flushBranchCheckpointQueueAll();
        flushBranchTargetQueueAll();
        flushRobAll();
        flushStoreQueueAll();
        flushLoadQueueAll();
    endtask


    task automatic flushOooQueueAll();
        while (oooQueue.size() > 0) void'(oooQueue.pop_back());
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


    task automatic flushOooQueuePartial(input OpSlot op);
        while (oooQueue.size() > 0 && oooQueue[$].id > op.id) void'(oooQueue.pop_back());
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
        flushOooQueuePartial(op);
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
        markKilledFrontStage(stageRename1);

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
                sysRegs_N = SYS_REGS_INITIAL;
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
    
    
    task automatic markKilledFrontStage(ref Stage_N stage);
        foreach (stage[i]) begin
            if (!stage[i].active) continue;
            putMilestone(stage[i].id, InstructionMap::FlushFront);
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
    
    
    task automatic setupOnRename(input OpSlot op);
        AbstractInstruction ins = decAbs(op);
        Word result, target;
        InsDependencies deps;
        Word argVals[3];
        
        // For insMap and mem queues
        argVals = getArgs(renamedEmul.coreState.intRegs, renamedEmul.coreState.floatRegs, ins.sources, parsingMap[ins.fmt].typeSpec);
        result = computeResult(renamedEmul.coreState, op.adr, ins, renamedEmul.tmpDataMem); // Must be before modifying state. For ins map
        deps = getPhysicalArgs(op, registerTracker.intMapR, registerTracker.floatMapR); // For insMap

        runInEmulator(renamedEmul, op);
        renamedEmul.drain();
        target = renamedEmul.coreState.target; // For insMap

        updateInds(renameInds, op); // Crucial state

        registerTracker.reserve(op);
        if (isMemOp(op)) addToMemTracker(op, ins, argVals); // DB

        if (isBranchIns(decAbs(op))) begin
//            branchTargetQueue.push_back('{op.id, 'z});
            saveCP(op); // Crucial state
        end

        insMap.setResult(op.id, result);
        insMap.setTarget(op.id, target);
        insMap.setDeps(op.id, deps);
        insMap.setArgValues(op.id, argVals);
        
        insMap.setInds(op.id, renameInds);
            insMap.setSlot(op.id, currentSlot);
        
    endtask

        task automatic addToMemTracker(input OpSlot op, input AbstractInstruction ins, input Word argVals[3]);
            Word effAdr = calculateEffectiveAddress(ins, argVals);

            if (isStoreMemIns(ins)) begin 
                Word value = argVals[2];
                memTracker.addStore(op, effAdr, value);
            end
            if (isLoadMemIns(ins)) begin
                memTracker.addLoad(op, effAdr, 'x);
            end
        endtask
        

    task automatic renameOp(input OpSlot op);
        setupOnRename(op);
       
        lastRenamed = op;
    endtask



    function automatic OpSlot takeFrontOp();
        OpStatus opSt = oooQueue.pop_front(); // OOO buffer entry release
        InstructionInfo insInfo = insMap.get(opSt.id);
        OpSlot op = '{1, insInfo.id, insInfo.adr, insInfo.bits};
        assert (op.id == opSt.id) else $error("wrong retirement: %p / %p", opSt, op);
        return op;
    endfunction


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
    

    task automatic commitOp(input OpSlot op);
        verifyOnCommit(op);

        updateInds(commitInds, op); // Crucial
            commitInds.renameG = insMap.get(op.id).inds.renameG;

        registerTracker.commit(op);
        
        if (isMemOp(op)) memTracker.remove(op); // DB?
        
        // Crucial state
        if (isBranchIns(decAbs(op)))
            retiredTarget <= branchTargetQueue[0].target;
        else if (isSysIns(decAbs(op)))
            retiredTarget <= 'x;
        else
            retiredTarget <= retiredTarget + 4;
        
        if (isStoreIns(decAbs(op))) csq_N.push_back(storeQueue[0]); // Crucial state
        if (isSysIns(decAbs(op))) setLateEvent(op); // Crucial state

        releaseQueues(op); // Crucial state

            lastRetired = op;
            nRetired++;
    endtask

    task automatic setLateEvent(input OpSlot op);    
        LateEvent evt = getLateEvt(op);
        AbstractInstruction abs = decAbs(op);
        if (abs.def.o == O_halt) $error("halt not implemented");
        
        lateEventInfoWaiting <= '{op, 0, 0, evt.redirect, evt.target};
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


    function automatic void updateInds(ref IndexSet inds, input OpSlot op);
        inds.rename = (inds.rename + 1) % (2*ROB_SIZE);
        if (isBranchIns(decAbs(op))) inds.bq = (inds.bq + 1) % (2*BC_QUEUE_SIZE);
        if (isLoadIns(decAbs(op))) inds.lq = (inds.lq + 1) % (2*LQ_SIZE);
        if (isStoreIns(decAbs(op))) inds.sq = (inds.sq + 1) % (2*SQ_SIZE);
    endfunction


    task automatic execReset();
            insMap.cleanDescs();
    
        lateEventInfoWaiting <= '{EMPTY_SLOT, 0, 1, 1, IP_RESET};
        performAsyncEvent(retiredEmul.coreState, IP_RESET, retiredEmul.coreState.target);
    endtask

    task automatic execInterrupt();
        $display(">> Interrupt !!!");
        lateEventInfoWaiting <= '{EMPTY_SLOT, 1, 0, 1, IP_INT};
        retiredEmul.interrupt();
    endtask


    task automatic updateOOOQ(input OpSlot op);
        const int ind[$] = oooQueue.find_index with (item.id == op.id);
        //assert (ind.size() > 0) oooQueue[ind[0]].done = 1; else $error("No such id in OOOQ: %d", op.id);
        putMilestone(op.id, InstructionMap::Complete); 
    endtask
    
    task automatic completeOp(input OpSlot op);            
        if (!op.active) return;
        
        updateOOOQ(op);
            lastCompleted = op;
            nCompleted++;
    endtask


    task automatic writeResult(input OpSlot op, input Word value);
        if (!op.active) return;
        insMap.setActualResult(op.id, value);

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


    function automatic Word getSysReg(input Word adr);
        return sysRegs_N[adr];
    endfunction

    function automatic void setSysReg(input Word adr, input Word val);
        sysRegs_N[adr] = val;
    endfunction


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

//        function automatic OpSlot2 tickA(input OpSlot opA[2]);
//            OpSlot res[2];
//            foreach (opA[i]) res[i] = opA[i];
//            return res;
//        endfunction

        function automatic OpSlot eff(input OpSlot op);
            if (lateEventInfo.redirect || (branchEventInfo.redirect && op.id > branchEventInfo.op.id))
                return EMPTY_SLOT;
            return op;
        endfunction

        function automatic IssueGroup effIG(input IssueGroup ig);
            IssueGroup res;
            
            foreach (ig.regular[i])
                res.regular[i] = eff(ig.regular[i]);
            res.float = eff(ig.float);
            res.branch = eff(ig.branch);
            res.mem = eff(ig.mem);
            res.sys = eff(ig.sys);
            res.num = ig.num;
            
            return res;
        endfunction

        function automatic IssueGroup tickIG(input IssueGroup ig);
            IssueGroup res;
            
            res.regular[0] = tick(ig.regular[0]);
            res.regular[1] = tick(ig.regular[1]);
            res.float = tick(ig.float);
            res.branch = tick(ig.branch);
            res.mem = tick(ig.mem);
            res.sys = tick(ig.sys);
            res.num = ig.num;
            
            return res;
        endfunction
                

//        function automatic OpSlot2 effA(input OpSlot ops[2]);
//            OpSlot res[2];
//            foreach (ops[i]) res[i] = eff(ops[i]);
//            return res;
//        endfunction


    assign lastRenamedStr = disasm(lastRenamed.bits);
    assign lastCompletedStr = disasm(lastCompleted.bits);
    assign lastRetiredStr = disasm(lastRetired.bits);
    
        string bqStr;
        always @(posedge clk) begin
            automatic int ids[$];
            foreach (branchCheckpointQueue[i]) ids.push_back(branchCheckpointQueue[i].op.id);
            $swrite(bqStr, "%p", ids);
        end


    function automatic void checkStoreValue(input InsId id, input Word adr, input Word value);
        Transaction tr[$] = memTracker.stores.find with (item.owner == id);
        assert (tr[0].adr === adr && tr[0].val === value) else $error("Wrong store: op %d, %d@%d", id, value, adr);
    endfunction

endmodule

