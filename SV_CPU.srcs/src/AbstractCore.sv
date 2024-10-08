
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;
import ControlHandling::*;

import Queues::*;


module AbstractCore
#(
)
(
    input logic clk,
    
    input logic interrupt,
    input logic reset,
    output logic sig,
    output logic wrong
);
    logic dummy = '1;

    // DB
    CoreDB coreDB();
    Word dbProgMem[4096];

    InstructionMap insMap = new();
    Emulator renamedEmul = new(), retiredEmul = new();

    RegisterTracker #(N_REGS_INT, N_REGS_FLOAT) registerTracker = new();
    MemTracker memTracker = new();
    
    BranchTargetEntry branchTargetQueue[$:BC_QUEUE_SIZE];
    BranchCheckpoint branchCheckpointQueue[$:BC_QUEUE_SIZE];

    //..............................
    int cycleCtr = 0;

    always @(posedge clk) cycleCtr++;


    Word insAdr;
    Word instructionCacheOut[FETCH_WIDTH];

    // Overall
    logic fetchAllow, renameAllow, iqsAccepting, csqEmpty = 0;
    IqLevels oooLevels, oooAccepts;
    int nFreeRegsInt = 0, nFreeRegsFloat = 0, bcqSize = 0;

    // OOO
    IndexSet renameInds = '{default: 0}, commitInds = '{default: 0};

    // Exec TODO: encapsulate in backend?
    logic intRegsReadyV[N_REGS_INT] = '{default: 'x};
    logic floatRegsReadyV[N_REGS_FLOAT] = '{default: 'x};

    EventInfo branchEventInfo = EMPTY_EVENT_INFO;
    EventInfo lateEventInfo = EMPTY_EVENT_INFO;
    EventInfo lateEventInfoWaiting = EMPTY_EVENT_INFO;
        Events evts;

    BranchCheckpoint branchCP;


    // Store interface
        // Committed
        StoreQueueEntry csq[$] = '{'{EMPTY_SLOT, 'x, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x, 'x} };
        string csqStr, csqIdStr;

        StoreQueueEntry storeHead = '{EMPTY_SLOT, 'x, 'x, 'x}, drainHead = '{EMPTY_SLOT, 'x, 'x, 'x};
        MemWriteInfo writeInfo; // Committed
    
    // Event control
        Word sysRegs[32];
        Word retiredTarget = 0;


    OpSlotA robOut;

    DataReadReq TMP_readReqs[N_MEM_PORTS];
    DataReadResp TMP_readResps[N_MEM_PORTS];
    
    MemWriteInfo TMP_writeInfos[2];

    ///////////////////////////

    InstructionL1 instructionCache(clk, insAdr, instructionCacheOut);
    DataL1        dataCache(clk, 
                            TMP_readReqs, TMP_readResps,
                            TMP_writeInfos);

    Frontend theFrontend(insMap, branchEventInfo, lateEventInfo);

    // Rename
    OpSlotA stageRename1 = '{default: EMPTY_SLOT};
    OpSlotA sqOut, lqOut, bqOut;

    ReorderBuffer theRob(insMap, branchEventInfo, lateEventInfo, stageRename1, robOut);
    StoreQueue#(.SIZE(SQ_SIZE), .HELPER(StoreQueueHelper))
        theSq(insMap, branchEventInfo, lateEventInfo, stageRename1, sqOut, theExecBlock.toSq);
    StoreQueue#(.IS_LOAD_QUEUE(1), .SIZE(LQ_SIZE), .HELPER(LoadQueueHelper))
        theLq(insMap, branchEventInfo, lateEventInfo, stageRename1, lqOut, theExecBlock.toLq);
    StoreQueue#(.IS_BRANCH_QUEUE(1), .SIZE(BQ_SIZE), .HELPER(BranchQueueHelper))
        theBq(insMap, branchEventInfo, lateEventInfo, stageRename1, bqOut, theExecBlock.toBq);

    IssueQueueComplex theIssueQueues(insMap, branchEventInfo, lateEventInfo, stageRename1);

    ExecBlock theExecBlock(insMap, branchEventInfo, lateEventInfo);

    //////////////////////////////////////////


    assign TMP_readReqs = theExecBlock.readReqs;
    assign theExecBlock.readResps = TMP_readResps;

    assign TMP_writeInfos[0] = writeInfo;
    assign TMP_writeInfos[1] = EMPTY_WRITE_INFO;

    // TODO: make function to assign this together with storeHead 
    always_comb writeInfo = '{storeHead.op.active && isStoreMemIns(decAbs(storeHead.op)) && !storeHead.cancel, storeHead.adr, storeHead.val};



    always @(posedge clk) begin
        insMap.endCycle();

        advanceCommit(); // commitInds,    lateEventInfoWaiting, retiredTarget, csq, registerTracker, memTracker, retiredEmul, branchCheckpointQueue, branchTargetQueue
        activateEvent(); // lateEventInfo, lateEventInfoWaiting, retiredtarget, sysRegs  

        begin // CAREFUL: putting this before advanceCommit() + activateEvent() has an effect on cycles 
            putWrite(); // csq, csqEmpty, storeHead, drainHead
            performSysStore();  // sysRegs
        end


        if (lateEventInfo.redirect || branchEventInfo.redirect)
            redirectRest();     // stageRename1, renameInds, renamedEmul, registerTracker, memTracker,   branchTargetQueue, branchCheckpointQueue
        else
            runInOrderPartRe(); // stageRename1, renameInds, renamedEmul, registerTracker, memTracker,   branchTargetQueue, branchCheckpointQueue

        handleCompletion(); // registerTracker

        updateBookkeeping();

            begin
                automatic int csqIds[$];
                foreach (csq[i]) csqIds.push_back(csq[i].op.id);
                $swrite(csqIdStr, "%p", csqIds);
                $swrite(csqStr, "%p", csq);
            end
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



    task automatic activateEvent();
        if (reset) lateEventInfoWaiting <= RESET_EVENT;
        else if (interrupt) lateEventInfoWaiting <= INT_EVENT;

        lateEventInfo <= EMPTY_EVENT_INFO;
    
        if (csqEmpty) fireLateEvent();
    endtask

    task automatic fireLateEvent();
        if (lateEventInfoWaiting.op.active) begin
            EventInfo lateEvt;
            Word sr2 = getSysReg(2);
            Word sr3 = getSysReg(3);
            OpSlot waitingOp = lateEventInfoWaiting.op;
            logic refetch = insMap.get(waitingOp.id).refetch;
            logic exception = insMap.get(waitingOp.id).exception;
            
            AbstractInstruction abs = decAbs(waitingOp);
            
            if (refetch) abs.def.o = O_replay;

            lateEvt = exception ? 
                        getLateEventExc(waitingOp, abs, waitingOp.adr, sr2, sr3) :
                        getLateEvent(waitingOp, abs, waitingOp.adr, sr2, sr3);
            
            if (exception) modifyStateSyncExc(sysRegs, waitingOp.adr, abs);
            else modifyStateSync(sysRegs, waitingOp.adr, abs);
                         
            retiredTarget <= lateEvt.target;
            lateEventInfo <= lateEvt;
            lateEventInfoWaiting <= EMPTY_EVENT_INFO;
        end
        else if (lateEventInfoWaiting.reset) begin
               // saveStateAsync(sysRegs, retiredTarget); // TODO: check if should be removed 
            sysRegs = SYS_REGS_INITIAL;
            
            retiredTarget <= IP_RESET;
            lateEventInfo <= RESET_EVENT;
            lateEventInfoWaiting <= EMPTY_EVENT_INFO;
            
            // TODO: maybe this should be at the moment of setting lateEventInfoWaiting because it is this way for synchronous events (performing op in commitOp)  
               // performAsyncEvent(retiredEmul.coreState, IP_RESET, retiredEmul.coreState.target); // TODO: remove?
            retiredEmul.reset();
        end
        else if (lateEventInfoWaiting.interrupt) begin
            saveStateAsync(sysRegs, retiredTarget);
            
            retiredTarget <= IP_INT;
            lateEventInfo <= INT_EVENT;
            lateEventInfoWaiting <= EMPTY_EVENT_INFO;
            
            // TODO: [same as the reset case] 
            $display(">> Interrupt !!!");
            retiredEmul.interrupt();
        end
    endtask


    ////////////////

    task automatic putWrite();
        StoreQueueEntry sqe = drainHead;
        
        if (sqe.op.id != -1) begin
            memTracker.drain(sqe.op);
            putMilestone(sqe.op.id, InstructionMap::WqExit);
        end
        void'(csq.pop_front());

        assert (csq.size() > 0) else $fatal(2, "csq must never become physically empty");
 
        if (csq.size() < 2) begin // slot [0] doesn't count, it is already written and serves to signal to drain SQ 
            csq.push_back('{EMPTY_SLOT, 'x, 'x, 'x});
            csqEmpty <= 1;
        end
        else begin
            csqEmpty <= 0;
        end
        
        drainHead <= csq[0];
        storeHead <= csq[1];
    endtask

    task automatic performSysStore();
        if (storeHead.op.active && isStoreSysIns(decAbs(storeHead.op)) && !storeHead.cancel) setSysReg(storeHead.adr, storeHead.val);
    endtask


    assign oooLevels.iqRegular = theIssueQueues.regularQueue.num;
    assign oooLevels.iqFloat = theIssueQueues.floatQueue.num;
    assign oooLevels.iqBranch = theIssueQueues.branchQueue.num;
    assign oooLevels.iqMem = theIssueQueues.memQueue.num;
    assign oooLevels.iqSys = theIssueQueues.sysQueue.num;

    assign oooAccepts = getBufferAccepts(oooLevels);
    assign iqsAccepting = iqsAccept(oooAccepts);

    assign fetchAllow = fetchQueueAccepts(theFrontend.fqSize) && bcQueueAccepts(bcqSize);
    assign renameAllow = iqsAccepting && regsAccept(nFreeRegsInt, nFreeRegsFloat) && theRob.allow && theSq.allow && theLq.allow;;

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
        return nI > RENAME_WIDTH && nF > RENAME_WIDTH;
    endfunction

    // Helper (inline it?)
    function logic fetchQueueAccepts(input int k);
        return k <= FETCH_QUEUE_SIZE - 3; // 2 stages between IP stage and FQ
    endfunction

    function logic bcQueueAccepts(input int k);
        return k <= BC_QUEUE_SIZE - 3*FETCH_WIDTH - FETCH_QUEUE_SIZE*FETCH_WIDTH; // 2 stages + FETCH_QUEUE entries, FETCH_WIDTH each
    endfunction



    task automatic renameGroup(input OpSlotA ops);
        if (anyActive(ops))
            renameInds.renameG = (renameInds.renameG + 1) % (2*theRob.DEPTH);
    
        foreach (ops[i]) begin
            if (ops[i].active !== 1) continue;
            renameOp(ops[i], i);
            putMilestone(ops[i].id, InstructionMap::Rename);
        end
    endtask

    // Frontend, rename and everything before getting to OOO queues
    task automatic runInOrderPartRe();
        renameGroup(theFrontend.stageRename0);
      
        stageRename1 <= theFrontend.stageRename0;
    endtask

    task automatic redirectRest();
        stageRename1 <= '{default: EMPTY_SLOT};
        markKilledRenameStage(stageRename1);

        if (lateEventInfo.redirect) begin
            renamedEmul.setLike(retiredEmul);
            
            flushBranchCheckpointQueueAll();
            flushBranchTargetQueueAll();
            
            if (lateEventInfo.reset) registerTracker.restoreReset();
            else registerTracker.restoreStable();
            registerTracker.flushAll();
            
            memTracker.flushAll();
            
            renameInds = commitInds;
        end
        else if (branchEventInfo.redirect) begin
            BranchCheckpoint foundCP[$] = AbstractCore.branchCheckpointQueue.find with (item.op.id == branchEventInfo.op.id);
            BranchCheckpoint causingCP = foundCP[0];

            renamedEmul.coreState = causingCP.state;
            renamedEmul.tmpDataMem.copyFrom(causingCP.mem);

            flushBranchCheckpointQueuePartial(branchEventInfo.op);
            flushBranchTargetQueuePartial(branchEventInfo.op);

            registerTracker.restoreCP(causingCP.intMapR, causingCP.floatMapR, causingCP.intWriters, causingCP.floatWriters);
            registerTracker.flush(branchEventInfo.op);
            
            memTracker.flush(branchEventInfo.op);
            
            renameInds = causingCP.inds;
        end
        
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


    // Frontend/Rename

    task automatic markKilledRenameStage(ref OpSlotA stage);
        foreach (stage[i]) begin
            if (!stage[i].active) continue;
            putMilestone(stage[i].id, InstructionMap::FlushOOO);
        end
    endtask

    task automatic saveCP(input OpSlot op);
        BranchCheckpoint cp = new(op, renamedEmul.coreState, renamedEmul.tmpDataMem,
                                    registerTracker.ints.writersR, registerTracker.floats.writersR,
                                    registerTracker.ints.MapR, registerTracker.floats.MapR,
                                    renameInds);
        branchCheckpointQueue.push_back(cp);
    endtask

    task automatic addToBtq(input OpSlot op);    
        branchTargetQueue.push_back('{op.id, 'z});
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


        physDest = registerTracker.reserve(ins, op.id);
        
        if (isStoreIns(ins) || isLoadIns(ins)) memTracker.add(op, ins, argVals); // DB
        
        if (isBranchIns(decAbs(op))) begin
            addToBtq(op);
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

        updateInds(renameInds, op); // Crucial state

    endtask


    function automatic logic breaksCommit(input OpSlot op);
        return breaksCommitId(op.id);
    endfunction

    function automatic logic breaksCommitId(input InsId id);
        InstructionInfo insInfo = insMap.get(id);
        return (isSysIns(insInfo.dec) && !isStoreSysIns(insInfo.dec) || insInfo.refetch || insInfo.exception);
    endfunction


    task automatic advanceCommit();
        logic cancelRest = 0;
        // Don't commit anything more if event is being handled

        foreach (robOut[i]) begin
            OpSlot opP;
           
            if (robOut[i].active !== 1) continue;
            if (cancelRest) $fatal(2, "Committing after break");
            
            opP = TMP_properOp(robOut[i]);

            commitOp(opP);
            
            if (breaksCommit(opP)) begin
                lateEventInfoWaiting <= eventFromOp(opP);
                cancelRest = 1;
            end
        end
        
        insMap.commitCheck();
    endtask


    task automatic verifyOnCommit(input OpSlot op);
        InstructionInfo info = insMap.get(op.id);

        Word trg = retiredEmul.coreState.target; // DB
        Word nextTrg;
        Word bits = fetchInstruction(dbProgMem, trg); // DB

        assert (trg === op.adr) else $fatal(2, "Commit: mm adr %h / %h", trg, op.adr);
        assert (bits === op.bits) else $fatal(2, "Commit: mm enc %h / %h", bits, op.bits); // TODO: check at Frontend?
        assert (info.argError === 0) else $fatal(2, "Arg error on op %d", op.id);

        if (insMap.get(op.id).refetch) return;
        
        // Only Normal commit
        if (!insMap.get(op.id).exception)
            if (hasIntDest(decAbs(op)) || hasFloatDest(decAbs(op))) // DB
                assert (info.actualResult === info.result) else $error(" not matching result. %p, %s; %d but should be %d", op, disasm(op.bits), info.actualResult, info.result);
            
        // Normal or Exceptional
        runInEmulator(retiredEmul, op.adr, op.bits);
        retiredEmul.drain();
        nextTrg = retiredEmul.coreState.target; // DB
        
        // Normal (branches don't cause exceptions so far, check for exc can be omitted)
        if (isBranchIns(decAbs(op))) // DB
            assert (branchTargetQueue[0].target === nextTrg) else $error("Mismatch in BQ id = %d, target: %h / %h", op.id, branchTargetQueue[0].target, nextTrg);
    endtask


    function automatic OpSlot TMP_properOp(input OpSlot opC);
        InstructionInfo insInfo = insMap.get(opC.id);
        OpSlot op = '{1, insInfo.id, insInfo.adr, insInfo.bits};
        return op;
    endfunction


    // Finish types:
    // CommitNormal     - normal effects take place, resources are freed
    // CommitException  - exceptional effects take place, resources are freed
    // CommitHidden     - replay takes place, reources are freed
    //
    // Normal effects:      register tables, updated target
    // Exceptional effects: fire event (update target, handle sys regs, redirect)
    // Hidden effects:      like above but event is Refetch 
    //
    // Registers:
    //     regular commit - write to tables, free previous table content
    //     exc/hidden     -     free own mapping instead of writing it
    //
    // Store ops: if Exc or Hidden, SQ entry must be marked invalid on commit or not committed (ptr not moved, then flushed by event)
    // 
    task automatic commitOp(input OpSlot op);
        InstructionInfo insInfo = insMap.get(op.id);

        logic refetch = insInfo.refetch;
        logic exception = insInfo.exception;
        InstructionMap::Milestone retireType = exception ? InstructionMap::RetireException : (refetch ? InstructionMap::RetireRefetch : InstructionMap::Retire);

        verifyOnCommit(op);

        checkUnimplementedInstruction(decAbs(op)); // All types of commit?

        registerTracker.commit(insInfo.dec, op.id, refetch || exception); // Need to modify to handle Exceptional and Hidden
            
        if (isStoreIns(decAbs(op))) begin
            Transaction tr = memTracker.findStore(op.id);
            StoreQueueEntry sqe = '{op, exception || refetch, tr.adrAny, tr.val};       
            csq.push_back(sqe); // Normal
            putMilestone(op.id, InstructionMap::WqEnter); // Normal
        end
            
        if (isStoreIns(decAbs(op)) || isLoadIns(decAbs(op))) memTracker.remove(op); // All?

        releaseQueues(op); // All
            
        if (refetch) begin
            coreDB.lastRefetched = op;
        end
        else begin
            coreDB.lastRetired = op; // Normal, not Hidden, what about Exc?
            coreDB.nRetired++;
        end
        
        // Need to modify to serve all types of commit            
        putMilestone(op.id, retireType);
        insMap.setRetired(op.id);
        
        // Elements related to crucial signals: 

        updateInds(commitInds, op); // All types?
        commitInds.renameG = insMap.get(op.id).inds.renameG; // Part of above

        retiredTarget <= getCommitTarget(decAbs(op), retiredTarget, branchTargetQueue[0].target, refetch, exception); // All types?
    endtask


    function automatic void updateInds(ref IndexSet inds, input OpSlot op);
        inds.rename = (inds.rename + 1) % (2*ROB_SIZE);
        if (isBranchIns(decAbs(op))) inds.bq = (inds.bq + 1) % (2*BC_QUEUE_SIZE);
        if (isLoadIns(decAbs(op))) inds.lq = (inds.lq + 1) % (2*LQ_SIZE);
        if (isStoreIns(decAbs(op))) inds.sq = (inds.sq + 1) % (2*SQ_SIZE);
    endfunction

    task automatic releaseQueues(input OpSlot op);
        if (isBranchIns(decAbs(op))) begin // Br queue entry release
            BranchCheckpoint bce = branchCheckpointQueue.pop_front();
            BranchTargetEntry bte = branchTargetQueue.pop_front();
            assert (bce.op === op) else $error("Not matching op: %p / %p", bce.op, op);
            assert (bte.id === op.id) else $error("Not matching op id: %p / %d", bte, op.id);
        end
    endtask


    task automatic completePacket(input OpPacket p);
        if (!p.active) return;
        else begin
            OpSlot os = getOpSlotFromPacket(p);
            writeResult(os, p.result);
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
        assert (adr >= 0 && adr <= 31) else $fatal("Writing incorrect sys reg: adr = %d, val = %d", adr, val);
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
        if (shouldFlushPoison(op.poison)) begin
            putMilestone(op.id, InstructionMap::FlushPoison);
            return EMPTY_OP_PACKET;
        end
    
        if (shouldFlushEvent(op.id)) begin 
            putMilestone(op.id, InstructionMap::FlushExec);
            return EMPTY_OP_PACKET;
        end
        return op;
    endfunction

    function automatic OpPacket effP(input OpPacket op);
        if (shouldFlushPoison(op.poison)) return EMPTY_OP_PACKET;            
        if (shouldFlushEvent(op.id)) return EMPTY_OP_PACKET;
        return op;
    endfunction


    function automatic logic shouldFlushEvent(input InsId id);
        return lateEventInfo.redirect || (branchEventInfo.redirect && id > branchEventInfo.op.id);
    endfunction
        

    function automatic logic shouldFlushPoison(input Poison poison);
        ForwardingElement memStage0[N_MEM_PORTS] = theExecBlock.memImagesTr[0];
        foreach (memStage0[p])
            if (checkMemDep(poison, memStage0[p]) && memStage0[p].status != ES_OK) return 1;
        return 0;
    endfunction


    assign insAdr = theFrontend.ipStage[0].adr;

    assign sig = lateEventInfo.sigOk;
    assign wrong = lateEventInfo.sigWrong;

endmodule
