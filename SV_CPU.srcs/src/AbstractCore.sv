
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


    Mword insAdr;
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
    //    Events evts;

    BranchCheckpoint branchCP;


    // Store interface
        // Committed
        StoreQueueEntry csq[$] = '{EMPTY_SQE, EMPTY_SQE};// '{'{0, -1, 'x, 'x, 'x}, '{0, -1, 'x, 'x, 'x} };
        string csqStr, csqIdStr;

        StoreQueueEntry storeHead = EMPTY_SQE,// '{0, -1, 'x, 'x, 'x}, 
                        drainHead = EMPTY_SQE;//'{0, -1, 'x, 'x, 'x};
        MemWriteInfo writeInfo; // Committed
    
    // Event control
        Mword sysRegs[32];
        Mword retiredTarget = 0;


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
    always_comb writeInfo = '{storeHead.active && isStoreMemIns(decId(storeHead.id)) && !storeHead.cancel, storeHead.adr, storeHead.val};


    always @(posedge clk) begin
        insMap.endCycle();

        advanceCommit(); // commitInds,    lateEventInfoWaiting, retiredTarget, csq, registerTracker, memTracker, retiredEmul, branchCheckpointQueue, branchTargetQueue
        activateEvent(); // lateEventInfo, lateEventInfoWaiting, retiredtarget, sysRegs, retiredEmul

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
            foreach (csq[i]) csqIds.push_back(csq[i].id);
            $swrite(csqIdStr, "%p", csqIds);
            $swrite(csqStr, "%p", csq);
        end
    end


    task automatic handleCompletion();
        writeResult(theExecBlock.doneRegular0_E);
        writeResult(theExecBlock.doneRegular1_E);
        writeResult(theExecBlock.doneFloat0_E);
        writeResult(theExecBlock.doneFloat1_E);
        writeResult(theExecBlock.doneBranch_E);
        writeResult(theExecBlock.doneMem0_E);
        writeResult(theExecBlock.doneMem2_E);
        writeResult(theExecBlock.doneSys_E);
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


    ////////////////

    task automatic putWrite();
        StoreQueueEntry sqe = drainHead;
        
        if (sqe.id != -1) begin
            memTracker.drain(sqe.id);
            putMilestone(sqe.id, InstructionMap::WqExit);
        end
        void'(csq.pop_front());

        assert (csq.size() > 0) else $fatal(2, "csq must never become physically empty");
 
        if (csq.size() < 2) begin // slot [0] doesn't count, it is already written and serves to signal to drain SQ 
            csq.push_back(//'{0, -1, 'x, 'x, 'x});
                          EMPTY_SQE);
            csqEmpty <= 1;
        end
        else begin
            csqEmpty <= 0;
        end
        
        drainHead <= csq[0];
        storeHead <= csq[1];
    endtask

    task automatic performSysStore();
        if (storeHead.active && isStoreSysIns(decId(storeHead.id)) && !storeHead.cancel) setSysReg(storeHead.adr, storeHead.val);
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
                
                insMap.alloc();
                insMap.renamedM++;
                
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
            
            if (lateEventInfo.cOp == CO_reset) registerTracker.restoreReset(); // TODO: try remove and handle with restoreStable
            else registerTracker.restoreStable();
            registerTracker.flushAll();
            
            memTracker.flushAll();
            
            renameInds = commitInds;
        end
        else if (branchEventInfo.redirect) begin
            BranchCheckpoint foundCP[$] = AbstractCore.branchCheckpointQueue.find with (item.id == branchEventInfo.id);
            BranchCheckpoint causingCP = foundCP[0];

            renamedEmul.coreState = causingCP.state;
            renamedEmul.tmpDataMem.copyFrom(causingCP.mem);

            flushBranchCheckpointQueuePartial(branchEventInfo.id);
            flushBranchTargetQueuePartial(branchEventInfo.id);

            registerTracker.restoreCP(causingCP.intMapR, causingCP.floatMapR, causingCP.intWriters, causingCP.floatWriters);
            registerTracker.flush(branchEventInfo.id);
            
            memTracker.flush(branchEventInfo.id);
            
            renameInds = causingCP.inds;
        end
        
    endtask


    task automatic flushBranchCheckpointQueueAll();
        while (branchCheckpointQueue.size() > 0) void'(branchCheckpointQueue.pop_back());
    endtask    

    task automatic flushBranchTargetQueueAll();
        while (branchTargetQueue.size() > 0) void'(branchTargetQueue.pop_back());
    endtask
 
    task automatic flushBranchCheckpointQueuePartial(input InsId id);
        while (branchCheckpointQueue.size() > 0 && branchCheckpointQueue[$].id > id) void'(branchCheckpointQueue.pop_back());
    endtask    

    task automatic flushBranchTargetQueuePartial(input InsId id);
        while (branchTargetQueue.size() > 0 && branchTargetQueue[$].id > id) void'(branchTargetQueue.pop_back());
    endtask


    // Frontend/Rename

    task automatic markKilledRenameStage(ref OpSlotA stage);
        foreach (stage[i]) begin
            if (!stage[i].active) continue;
            putMilestone(stage[i].id, InstructionMap::FlushOOO);
        end
    endtask

    task automatic saveCP(input InsId id);
        BranchCheckpoint cp = new(id, renamedEmul.coreState, renamedEmul.tmpDataMem,
                                    registerTracker.ints.writersR, registerTracker.floats.writersR,
                                    registerTracker.ints.MapR, registerTracker.floats.MapR,
                                    renameInds);
        branchCheckpointQueue.push_back(cp);
    endtask

    task automatic addToBtq(input InsId id);    
        branchTargetQueue.push_back('{id, 'z});
    endtask


    task automatic renameOp(input OpSlot op, input int currentSlot);
        AbstractInstruction ins = decId(op.id);
        Mword result, target;
        InsDependencies deps;
        Mword argVals[3];
        int physDest = -1;
        
        // For insMap and mem queues
        argVals = getArgs(renamedEmul.coreState.intRegs, renamedEmul.coreState.floatRegs, ins.sources, parsingMap[ins.fmt].typeSpec);
        result = computeResult(renamedEmul.coreState, op.adr, ins, renamedEmul.tmpDataMem); // Must be before modifying state. For ins map
        deps = registerTracker.getArgDeps(ins); // For insMap
                
        runInEmulator(renamedEmul, op.adr, op.bits);
        renamedEmul.drain();
        target = renamedEmul.coreState.target; // For insMap


        physDest = registerTracker.reserve(ins, op.id);
        
        if (isStoreIns(ins) || isLoadIns(ins)) memTracker.add(op.id, ins, argVals); // DB
        
        if (isBranchIns(decId(op.id))) begin
            addToBtq(op.id);
            saveCP(op.id); // Crucial state
        end

        insMap.setResult(op.id, result);
        insMap.setTarget(op.id, target);
        insMap.setDeps(op.id, deps);
        insMap.setPhysDest(op.id, physDest);
        insMap.setArgValues(op.id, argVals);
        
        insMap.setInds(op.id, renameInds);
        insMap.setSlot(op.id, currentSlot);

            coreDB.lastRenamed = TMP_properOp(op.id);

        updateInds(renameInds, op.id); // Crucial state

    endtask


    function automatic logic breaksCommitId(input InsId id);
        InstructionInfo insInfo = insMap.get(id);
        return (isSysIns(insInfo.dec) && !isStoreSysIns(insInfo.dec) || insInfo.refetch || insInfo.exception);
    endfunction


    task automatic fireLateEvent();
        if (lateEventInfoWaiting.active !== 1) return;

        if (lateEventInfoWaiting.cOp == CO_reset) begin        
            sysRegs = SYS_REGS_INITIAL;
            
            retiredTarget <= IP_RESET;
            lateEventInfo <= RESET_EVENT;
            lateEventInfoWaiting <= EMPTY_EVENT_INFO;
        end
        else if (lateEventInfoWaiting.cOp == CO_int) begin
            saveStateAsync(sysRegs, retiredTarget);
            
            retiredTarget <= IP_INT;
            lateEventInfo <= INT_EVENT;
            lateEventInfoWaiting <= EMPTY_EVENT_INFO;
        end  
        else begin
            Mword sr2 = getSysReg(2);
            Mword sr3 = getSysReg(3);
            Mword waitingAdr = getAdr(lateEventInfoWaiting.id);
            EventInfo lateEvt = getLateEvent(lateEventInfoWaiting, waitingAdr, sr2, sr3);

            modifyStateSync(lateEventInfoWaiting.cOp, sysRegs, waitingAdr);            
                         
            retiredTarget <= lateEvt.target;
            lateEventInfo <= lateEvt;
            lateEventInfoWaiting <= EMPTY_EVENT_INFO;
        end

    endtask


    task automatic activateEvent();
        if (reset) begin
            lateEventInfoWaiting <= RESET_EVENT;
                retiredEmul.reset();
        end
        else if (interrupt) begin
            lateEventInfoWaiting <= INT_EVENT;
                $display(">> Interrupt !!!");
                retiredEmul.interrupt();
        end

        lateEventInfo <= EMPTY_EVENT_INFO;
    
        if (csqEmpty) fireLateEvent();
    endtask


    task automatic advanceCommit();
        logic cancelRest = 0;
        // Don't commit anything more if event is being handled

        foreach (robOut[i]) begin
            OpSlot opP;
            logic refetch, exception;
           
            if (robOut[i].active !== 1) continue;
            if (cancelRest) $fatal(2, "Committing after break");
            
            opP = TMP_properOp(robOut[i].id);
            refetch = insMap.get(opP.id).refetch;
            exception = insMap.get(opP.id).exception;

            commitOp(opP);
                
                insMap.dealloc();
                insMap.committedM++;
            
            if (breaksCommitId(opP.id)) begin
                lateEventInfoWaiting <= eventFromOp(opP.id, decId(opP.id), refetch, exception);
                cancelRest = 1;
            end
        end
        
        insMap.commitCheck();
    endtask


    task automatic verifyOnCommit(input OpSlot op);
        InstructionInfo info = insMap.get(op.id);

        Mword trg = retiredEmul.coreState.target; // DB
        Mword nextTrg;
        Word bits = fetchInstruction(dbProgMem, trg); // DB

        // TODO: don't use op content for comparison
        assert (trg === info.adr) else $fatal(2, "Commit: mm adr %h / %h", trg, op.adr);
        assert (bits === info.bits) else $fatal(2, "Commit: mm enc %h / %h", bits, op.bits); // TODO: check at Frontend?
        assert (info.argError === 0) else $fatal(2, "Arg error on op %d", op.id);

        if (info.refetch) return;
        
        // Only Normal commit
        if (!info.exception)
            if (hasIntDest(decId(op.id)) || hasFloatDest(decId(op.id))) // DB
                assert (info.actualResult === info.result) else $error(" not matching result. %p, %s; %d but should be %d", op, disasm(op.bits), info.actualResult, info.result);
            
        // Normal or Exceptional
        runInEmulator(retiredEmul, op.adr, op.bits);
        retiredEmul.drain();
    
        nextTrg = retiredEmul.coreState.target; // DB
    
        // Normal (branches don't cause exceptions so far, check for exc can be omitted)
        if (!info.exception && isBranchIns(decId(op.id))) // DB
            assert (branchTargetQueue[0].target === nextTrg) else $error("Mismatch in BQ id = %d, target: %h / %h", op.id, branchTargetQueue[0].target, nextTrg);
    endtask


    function automatic OpSlot TMP_properOp(input InsId id);
        InstructionInfo insInfo = insMap.get(id);
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

        checkUnimplementedInstruction(decId(op.id)); // All types of commit?

        registerTracker.commit(insInfo.dec, op.id, refetch || exception); // Need to modify to handle Exceptional and Hidden
            
            // TODO: extract task
        if (isStoreIns(decId(op.id))) begin
            Transaction tr = memTracker.findStore(op.id);
            StoreQueueEntry sqe = '{1, op.id, exception || refetch, tr.adrAny, tr.val};       
            csq.push_back(sqe); // Normal
            putMilestone(op.id, InstructionMap::WqEnter); // Normal
        end
            
        if (isStoreIns(decId(op.id)) || isLoadIns(decId(op.id))) memTracker.remove(op.id); // All?

        releaseQueues(op.id); // All
            
        if (refetch) begin
            coreDB.lastRefetched = TMP_properOp(op.id);
        end
        else begin
            coreDB.lastRetired = TMP_properOp(op.id); // Normal, not Hidden, what about Exc?
            coreDB.nRetired++;
        end
        
        // Need to modify to serve all types of commit            
        putMilestone(op.id, retireType);
        insMap.setRetired(op.id);
        
        // Elements related to crucial signals:
        updateInds(commitInds, op.id); // All types?
        commitInds.renameG = insMap.get(op.id).inds.renameG; // Part of above

        retiredTarget <= getCommitTarget(decId(op.id), retiredTarget, branchTargetQueue[0].target, refetch, exception);
    endtask


    function automatic void updateInds(ref IndexSet inds, input InsId id);
        inds.rename = (inds.rename + 1) % (2*ROB_SIZE);
        if (isBranchIns(decId(id))) inds.bq = (inds.bq + 1) % (2*BC_QUEUE_SIZE);
        if (isLoadIns(decId(id))) inds.lq = (inds.lq + 1) % (2*LQ_SIZE);
        if (isStoreIns(decId(id))) inds.sq = (inds.sq + 1) % (2*SQ_SIZE);
    endfunction

    task automatic releaseQueues(input InsId id);
        if (isBranchIns(decId(id))) begin // Br queue entry release
            BranchCheckpoint bce = branchCheckpointQueue.pop_front();
            BranchTargetEntry bte = branchTargetQueue.pop_front();
            assert (bce.id === id) else $error("Not matching op: %p / %p", bce, id);
            assert (bte.id === id) else $error("Not matching op id: %p / %d", bte, id);
        end
    endtask


    function automatic Mword getSysReg(input Mword adr);
        return sysRegs[adr];
    endfunction

    function automatic void setSysReg(input Mword adr, input Mword val);
        assert (adr >= 0 && adr <= 31) else $fatal("Writing incorrect sys reg: adr = %d, val = %d", adr, val);
        sysRegs[adr] = val;
    endfunction

    task automatic writeResult(input OpPacket p);
        if (!p.active) return;
        putMilestone(p.id, InstructionMap::WriteResult);
        registerTracker.writeValue(decId(p.id), p.id, p.result);
    endtask


    // General

    function automatic AbstractInstruction decId(input InsId id);
        if (id == -1) return DEFAULT_ABS_INS;     
        return insMap.get(id).dec;
    endfunction

    function automatic Mword getAdr(input InsId id);
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
        return lateEventInfo.redirect || (branchEventInfo.redirect && id > branchEventInfo.id);
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
