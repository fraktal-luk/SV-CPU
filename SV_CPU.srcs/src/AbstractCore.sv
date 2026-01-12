
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import EmulationDefs::*;

import UopList::*;
import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;
import ControlHandling::*;

import CacheDefs::*;

import Queues::*;

import Testing::GlobalParams;


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
    logic dummy = 'z;

    GlobalParams globalParams;

    // DB        
    InstructionMap insMap = new();
    Emulator renamedEmul = new(), retiredEmul = new();
    PageBasedProgramMemory programMem;

    RegisterTracker #(N_REGS_INT, N_REGS_FLOAT) registerTracker = new();
    MemTracker memTracker = new();

    BranchCheckpoint branchCheckpointQueue[$:BC_QUEUE_SIZE];

    Mword insAdr;       // DB?
    logic fetchEnable;  // DB?

    InsId lastRetired;

    int cycleCtr = 0;

    always @(posedge clk) cycleCtr++;

    //..............................
    struct {
        logic enableMmu = 0;
        logic dbStep = 0;
        logic enArithExc = 0;
    } CurrentConfig;

    // Overall
    logic renameAllow, iqsAccepting, csqEmpty = 0, wqFree;
    IqLevels oooLevels, oooAccepts;
    int nFreeRegsInt = 0, nFreeRegsFloat = 0, bcqSize = 0;

    // OOO
    IndexSet renameInds = '{default: 0}, commitInds = '{default: 0};
    MarkerSet renameMarkers = '{default: -1}, commitMarkers = '{default: -1};

    // Exec   FUTURE: encapsulate in backend?
    logic intRegsReadyV[N_REGS_INT] = '{default: 'x};
    logic floatRegsReadyV[N_REGS_FLOAT] = '{default: 'x};

    EventInfo branchEventInfo = EMPTY_EVENT_INFO;
    EventInfo lateEventInfo = EMPTY_EVENT_INFO;
    EventInfo lateEventInfoWaiting = EMPTY_EVENT_INFO;

    // Store interface
    // Committed
    SqEntry csq[$] = '{StoreQueueHelper::EMPTY_QENTRY, StoreQueueHelper::EMPTY_QENTRY};
    SqEntry drainHead = StoreQueueHelper::EMPTY_QENTRY;
    MemWriteInfo writeInfo = EMPTY_WRITE_INFO, sysWriteInfo = EMPTY_WRITE_INFO;

    MemWriteInfo dcacheWriteInfos[2];
    MemWriteInfo sysWriteInfos[1];


    SystemRegisterUnit sysUnit(theExecBlock.sysOuts_E1, sysWriteInfos);

    // Event control
    Mword retiredTarget = 0;

    logic barrierUnlocking;
    InsId barrierUnlockingMid;
    InsId latestUnlockingMid = -1;

    ///////////////////////////

    DataL1        dataCache(clk, dcacheWriteInfos, theExecBlock.dcacheTranslations_EE0, theExecBlock.dcacheOuts_E1, theExecBlock.uncachedOuts_E1);

    Frontend theFrontend(insMap, clk, branchEventInfo, lateEventInfo);

    // Rename
    OpSlotAB stageRename1 = '{default: EMPTY_SLOT_B};

    ReorderBuffer theRob(insMap, branchEventInfo, lateEventInfo, stageRename1);
    StoreQueue#(.SIZE(SQ_SIZE), .HELPER(StoreQueueHelper))
        theSq(insMap, memTracker, branchEventInfo, lateEventInfo, stageRename1);
    StoreQueue#(.IS_LOAD_QUEUE(1), .SIZE(LQ_SIZE), .HELPER(LoadQueueHelper))
        theLq(insMap, memTracker, branchEventInfo, lateEventInfo, stageRename1);
    StoreQueue#(.IS_BRANCH_QUEUE(1), .SIZE(BQ_SIZE), .HELPER(BranchQueueHelper))
        theBq(insMap, memTracker, branchEventInfo, lateEventInfo, stageRename1);

    bind StoreQueue: theSq TmpSubSq submod();
    bind StoreQueue: theLq TmpSubLq submod();
    bind StoreQueue: theBq TmpSubBr submod();

    IssueQueueComplex theIssueQueues(insMap, branchEventInfo, lateEventInfo, stageRename1);

    ExecBlock theExecBlock(insMap, branchEventInfo, lateEventInfo);

    //////////////////////////////////////////
    assign barrierUnlocking = (drainHead.barrierFw === 1);
    assign barrierUnlockingMid = barrierUnlocking ? (drainHead.mid) : -1;

    assign wqFree = csqEmpty && !dataCache.uncachedSubsystem.uncachedBusy;
    assign dcacheWriteInfos[0] = writeInfo;
    assign dcacheWriteInfos[1] = EMPTY_WRITE_INFO;
    assign sysWriteInfos[0] = sysWriteInfo;

    assign oooLevels = '{
        iqRegular:   theIssueQueues.regularQueue.num,
        iqFloat:     theIssueQueues.floatQueue.num,
        iqBranch:    theIssueQueues.branchQueue.num,
        iqMem:       theIssueQueues.memQueue.num,
        iqStoreData: theIssueQueues.storeDataQueue.num
    };

    assign oooAccepts = getBufferAccepts(oooLevels);
    assign iqsAccepting = iqsAccept(oooAccepts);
    assign renameAllow = bcQueueAccepts(bcqSize) && iqsAccepting && regsAccept(nFreeRegsInt, nFreeRegsFloat) && theRob.allow && theSq.allow && theLq.allow;;

    assign fetchEnable = theFrontend.fetchEnable;
    assign insAdr = theFrontend.fetchAdr;

    assign sig = lateEventInfo.cOp == CO_send;
    assign wrong = lateEventInfo.cOp inside {CO_error, CO_undef};


    always @(posedge clk) begin
        insMap.endCycle();

        sysUnit.handleReads();

        advanceCommit(); // commitInds,    lateEventInfoWaiting, retiredTarget, csq, registerTracker, memTracker, retiredEmul, branchCheckpointQueue
        activateEvent(); // lateEventInfo, lateEventInfoWaiting, retiredtarget, sysRegs, retiredEmul

        begin // CAREFUL: putting this before advanceCommit() + activateEvent() has an effect on cycles 
            putWrite(); // csq, csqEmpty, drainHead
            sysUnit.handleWrite();
        end

        if (lateEventInfo.redirect || branchEventInfo.redirect)
            redirectRest();     // stageRename1, renameInds, renamedEmul, registerTracker, memTracker, branchCheckpointQueue
        else
            runInOrderPartRe(); // stageRename1, renameInds, renamedEmul, registerTracker, memTracker, branchCheckpointQueue

        releaseMarkers(renameMarkers, barrierUnlocking, barrierUnlockingMid);
        if (barrierUnlocking) latestUnlockingMid <= barrierUnlockingMid;

        handleWrites(); // registerTracker

        updateBookkeeping();

        syncCurrentConfigFromRegs();

        insMap.commitCheck( csqEmpty ||  insMap.insBase.retired < oldestCsq() ); // Don't remove ops form base if csq still contains something that would be deleted
    end


    task automatic handleWrites();
        writeResult(theExecBlock.doneRegular0_E);
        writeResult(theExecBlock.doneRegular1_E);

        writeResult(theExecBlock.doneBranch_E);
        writeResult(theExecBlock.doneDivider_E);

        writeResult(theExecBlock.doneMultiplier0_E);
        writeResult(theExecBlock.doneMultiplier1_E);

        writeResult(theExecBlock.doneFloat0_E);
        writeResult(theExecBlock.doneFloat1_E);
        writeResult(theExecBlock.doneFloatDiv_E);

        writeResult(theExecBlock.doneMem0_E);
        writeResult(theExecBlock.doneMem2_E);
        writeResult(theExecBlock.doneStoreData_E);
    endtask

    task automatic updateBookkeeping();
        bcqSize <= branchCheckpointQueue.size();
        
        nFreeRegsInt <= registerTracker.getNumFreeInt();
        nFreeRegsFloat <= registerTracker.getNumFreeFloat();
        
        intRegsReadyV <= registerTracker.ints.ready;
        floatRegsReadyV <= registerTracker.floats.ready;
    endtask


    ////////////////

    task automatic putWrite();
        // This block is not related to CSQ itself 
        if (drainHead.mid != -1) begin
            memTracker.drain(drainHead.mid);
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
    endtask


    // Helper (inline it?)
    function logic regsAccept(input int nI, input int nF);
        return nI > RENAME_WIDTH && nF > RENAME_WIDTH;
    endfunction

    function logic bcQueueAccepts(input int k);
        return k <= BC_QUEUE_SIZE - 2*FETCH_WIDTH;// - FETCH_QUEUE_SIZE*FETCH_WIDTH; // 2 stages + FETCH_QUEUE entries, FETCH_WIDTH each
    endfunction


    // Frontend, rename and everything before getting to OOO queues
    task automatic runInOrderPartRe();
        OpSlotAF opsF = theFrontend.stageRename0;
        OpSlotAB ops = TMP_front2rename(opsF);

        // ops: .active, .mid, .adr, .bits,

        if (anyActiveB(ops))
            renameInds.renameG = (renameInds.renameG + 1) % (2*theRob.DEPTH);

        foreach (ops[i]) begin            
            if (ops[i].active !== 1) continue;

            ops[i].mid = insMap.insBase.lastM + 1;
            renameOp(ops[i].mid, i, ops[i].adr, ops[i].bits, opsF[i].takenBranch, opsF[i].predictedTarget);
        end

        stageRename1 <= ops;
    endtask


    task automatic redirectRest();
        stageRename1 <= '{default: EMPTY_SLOT_B};
        markKilledRenameStage(stageRename1);

        if (lateEventInfo.redirect) begin
            renamedEmul.setLike(retiredEmul);
            
            flushBranchCheckpointQueueAll();
                          
            registerTracker.restoreStable();
            registerTracker.flushAll();
            memTracker.flushAll();
            
            renameInds = commitInds;
            renameMarkers = commitMarkers;
        end
        else if (branchEventInfo.redirect) begin
            BranchCheckpoint foundCP[$] = AbstractCore.branchCheckpointQueue.find with (item.id == branchEventInfo.eventMid);
            BranchCheckpoint causingCP = foundCP[0];

            renamedEmul.setLike(causingCP.emul);

            flushBranchCheckpointQueuePartial(branchEventInfo.eventMid);

            registerTracker.restoreCP(causingCP.intMapR, causingCP.floatMapR, causingCP.intWriters, causingCP.floatWriters);
            registerTracker.flush(branchEventInfo.eventMid);
            memTracker.flush(branchEventInfo.eventMid);
            
            renameInds = causingCP.inds;
            renameMarkers = causingCP.markers;
            releaseMarkers(renameMarkers, 1, latestUnlockingMid); // Don't allow already resolved barriers to come back
        end

    endtask


    task automatic flushBranchCheckpointQueueAll();
        branchCheckpointQueue = '{};
    endtask    

    task automatic flushBranchCheckpointQueuePartial(input InsId id);
        while (branchCheckpointQueue.size() > 0 && branchCheckpointQueue[$].id > id) void'(branchCheckpointQueue.pop_back());
    endtask    


    // Frontend/Rename

    task automatic markKilledRenameStage(ref OpSlotAB stage);
        foreach (stage[i]) begin
            if (stage[i].active) putMilestoneM(stage[i].mid, InstructionMap::FlushOOO);
        end
    endtask

    task automatic saveCP(input InsId id);
        BranchCheckpoint cp = new(id,
                                    registerTracker.ints.writersR, registerTracker.floats.writersR,
                                    registerTracker.ints.MapR, registerTracker.floats.MapR,
                                    renameInds, renameMarkers,
                                    renamedEmul);
        branchCheckpointQueue.push_back(cp);
    endtask


    task automatic renameOp(input InsId id, input int currentSlot, input Mword adr, input Word bits, input logic predictedDir, input Mword predictedTrg /*UNUSED so far*/);
        AbstractInstruction ins = decodeWithAddress(bits, adr);
        UopInfo mainUinfo;
        UopInfo uInfos[$];
        Mword target;

        UopName uopName = decodeUop(ins);
        InstructionInfo ii = initInsInfo(id, adr, bits, ins);
        InsDependencies deps = registerTracker.getArgDeps(ins);

        Mword argVals[3] = getArgs(renamedEmul.coreState.intRegs, renamedEmul.coreState.floatRegs, ins.sources, parsingMap[ins.def.f].typeSpec);
        Mword result = renamedEmul.computeResult(adr, ins); // Must be before modifying state. For ins map

        runInEmulator(renamedEmul, adr, bits);
        renamedEmul.drain();

        target = renamedEmul.coreState.target; // For insMap

        renamedEmul.catchDbTrap();

        // Main op info
        ii.mainUop = uopName;
        ii.inds = renameInds;
        ii.basicData.target = target;

        ii.firstUop = insMap.insBase.lastU + 1;
        ii.nUops = -1;

        if (isBranchIns(ins)) ii.frontBranch = predictedDir;

        // Generate info for uops
        mainUinfo.id = '{id, -1};
        mainUinfo.name = uopName;
        mainUinfo.vDest = ins.dest;
        mainUinfo.physDest = -1;
        mainUinfo.deps = deps;

        // If unlocking now and latest barrier is being unlocked (or should have been), ignore the barrier
        if (!barrierUnlocking || barrierUnlockingMid < renameMarkers.mbF) begin
            mainUinfo.barrier = isMemIns(ins) ? renameMarkers.mbF : -1;
        end

        mainUinfo.argsE = argVals;
        mainUinfo.resultE = result;
        mainUinfo.argError = 'x;

        uInfos = splitUop(mainUinfo);
        ii.nUops = uInfos.size(); 

        for (int u = 0; u < ii.nUops; u++) begin
            UopInfo uInfo = uInfos[u];
            uInfos[u].physDest = registerTracker.reserve(uInfo.name, uInfo.vDest, '{id, u});
            
            if (uopHasIntDest(uInfo.name) && uInfo.vDest == -1) $error(" reserve -1!  %d, %s", id, disasm(ii.basicData.bits));
        end

        insMap.allocate(id, ii, uInfos);  // 

        if (isStoreIns(ins) || isLoadIns(ins) || isMemBarrierIns(ins)) begin
            Mword effAdr = calculateEffectiveAddress(ins, argVals);
            Translation tr = renamedEmul.translateDataAddress(effAdr);
            memTracker.add(id, uopName, ins, argVals, tr.padr); // DB
        end

        if (isBranchIns(ins)) saveCP(id); // Crucial state

        updateInds(renameInds, id); // Crucial state
        updateMarkers(renameMarkers, id); // Crucial state

        putMilestoneM(id, InstructionMap::Rename);
    endtask


    function automatic logic breaksCommitId(input InsId id);
        InstructionInfo insInfo = insMap.get(id);
        return isControlUop(insInfo.mainUop) || insInfo.refetch || insInfo.exception || CurrentConfig.dbStep;
    endfunction


    task automatic fireLateEvent();
        if (lateEventInfoWaiting.active !== 1) return;

        if (lateEventInfoWaiting.cOp == CO_reset) begin
            sysUnit.saveStateAsync(retiredTarget);
            retiredTarget <= IP_RESET;
            lateEventInfo <= RESET_EVENT;
        end
        else if (lateEventInfoWaiting.cOp == CO_int) begin
            sysUnit.saveStateAsync(retiredTarget);
            retiredTarget <= IP_INT;
            lateEventInfo <= INT_EVENT;
        end
        else if (lateEventInfoWaiting.cOp == CO_break) begin
            sysUnit.saveStateAsync(retiredTarget);
            retiredTarget <= IP_DB_BREAK;
            lateEventInfo <= DB_EVENT;
        end
        else begin
            Mword sr2 = sysUnit.sysRegs[2];
            Mword sr3 = sysUnit.sysRegs[3];
            EventInfo lateEvt = getLateEvent(lateEventInfoWaiting, lateEventInfoWaiting.adr, sr2, sr3, lateEventInfoWaiting.target);
           
            sysUnit.modifyStateSync(lateEventInfoWaiting.cOp, lateEventInfoWaiting.adr);
            retiredTarget <= lateEvt.target;
            lateEventInfo <= lateEvt;
        end

        lateEventInfoWaiting <= EMPTY_EVENT_INFO;
    endtask


    task automatic activateEvent();
        if (reset) begin
            lateEventInfoWaiting <= RESET_EVENT;
            retiredEmul.resetSignal();
        end
        else if (interrupt) begin
            lateEventInfoWaiting <= INT_EVENT;
            $display(">> Interrupt !!!");
            retiredEmul.interrupt();
        end

        lateEventInfo <= EMPTY_EVENT_INFO;

        if (wqFree) fireLateEvent();
    endtask


    task automatic advanceCommit();
        logic cancelRest = 0;

        foreach (theRob.retirementGroup[i]) begin
            InsId theId = theRob.retirementGroup[i].mid;

            if (theRob.retirementGroup[i].active !== 1 || theId == -1) continue;
            if (cancelRest) $fatal(2, "Committing after break");

            commitOp(theRob.retirementGroup[i]);

            if (theId == U2M(theExecBlock.fpInvReg.TMP_oid)) begin
                sysUnit.setFpInv();
            end
            if (theId == U2M(theExecBlock.fpOvReg.TMP_oid)) begin
                sysUnit.setFpOv();
            end
            
            syncCurrentConfigFromRegs();

            lastRetired <= theId;

            // RET: generate late event
            if (breaksCommitId(theId)) begin
                InstructionInfo ii = insMap.get(theId);
                lateEventInfoWaiting <= eventFromOp(theId, ii.mainUop, ii.basicData.adr, ii.refetch, ii.exception, ii.eventType, CurrentConfig.dbStep);
                cancelRest = 1; // Don't commit anything more if event is being handled
            end  
        end

        releaseMarkers(commitMarkers, barrierUnlocking, barrierUnlockingMid);
    endtask


    function automatic void checkUops(input InsId id);
        InstructionInfo info = insMap.get(id);

        for (int u = 0; u < info.nUops; u++) begin
            UopInfo uinfo = insMap.getU('{id, u});    
            if (uopHasIntDest(uinfo.name) || uopHasFloatDest(uinfo.name)) begin // DB
                assert (uinfo.resultA === uinfo.resultE && uinfo.argError === 0)
                     else $error(" not matching result. %s; %d but should be %d", disasm(info.basicData.bits), uinfo.resultA, uinfo.resultE);
            end
        end
    endfunction


    task automatic verifyOnCommit(input RetirementInfo retInfo);
        InsId id = retInfo.mid;
        InstructionInfo info = insMap.get(id);

        Mword trg = retiredEmul.coreState.target; // DB
        Mword nextTrg;
        checkUnimplementedInstruction(info.basicData.dec); // All types of commit?

        assert (trg === info.basicData.adr) else $fatal(2, "Commit: mm adr %h / %h", trg, info.basicData.adr);
        assert (retInfo.refetch === info.refetch) else $error("Not seen refetch: %d\n%p\n%p", id, info, retInfo);   
 
        // TODO: incorporate arith exc into ROB output to bring back this check?
          //  Or better: maybe storing exc/refech in SQ/LQ is not needed because they are in First Event unit?
          //  assert (retInfo.exception === info.exception) else $error("Not seen exc: %d\n%p\n%p", id, info, retInfo);

        if (info.refetch) return;

        // Only Normal commit
        if (!info.exception) checkUops(id);

        // Normal or Exceptional
        runInEmulator(retiredEmul, info.basicData.adr, info.basicData.bits);
        retiredEmul.drain();

        nextTrg = retiredEmul.coreState.target; // DB

        retiredEmul.catchDbTrap();

        // Normal (branches don't cause exceptions so far, check for exc can be omitted)
        if (!info.exception && isBranchUop(decMainUop(id))) begin // DB
            if (retInfo.takenBranch === 1) begin
                assert (retInfo.target === nextTrg) else $fatal(2, "Mismatch of trg: %d, %d", retInfo.target, nextTrg);
            end
        end
    endtask


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
    task automatic commitOp(RetirementInfo retInfo);
        InsId id = retInfo.mid;
        InstructionInfo insInfo = insMap.get(id);

        InstructionMap::Milestone retireType = retInfo.exception ? InstructionMap::RetireException : (retInfo.refetch ? InstructionMap::RetireRefetch : InstructionMap::Retire);

        assert ((theExecBlock.currentEventReg == id) === (retInfo.refetch || retInfo.exception ||
                            isStaticEventIns(insInfo.basicData.dec) || (insInfo.eventType == PE_ARITH_EXCEPTION)))
            else $error("Mismatch at op %d: %d , %p, %p ", id, theExecBlock.currentEventReg, 
                        retInfo.refetch, retInfo.exception);
                            
        verifyOnCommit(retInfo);

        // RET: update regs
        for (int u = 0; u < insInfo.nUops; u++) begin
            UidT uid = '{id, u};
            registerTracker.commit(decUname(uid), insMap.getU(uid).vDest, uid, retInfo.refetch || retInfo.exception); // Need to modify to handle Exceptional and Hidden
        end

        // RET: update WQ
        if (isStoreUop(decMainUop(id)) || isMemBarrierUop(decMainUop(id))) putToWq(id, retInfo.exception, retInfo.refetch);

        // RET: free DB queues
        if (isStoreUop(decMainUop(id)) || isLoadUop(decMainUop(id)) || isMemBarrierUop(decMainUop(id))) memTracker.remove(id); // All?
        if (isBranchUop(decMainUop(id))) begin // Br queue entry release
            BranchCheckpoint bce = branchCheckpointQueue.pop_front();
            assert (bce.id === id) else $error("Not matching op: %p / %p", bce, id);
        end

        // Need to modify to serve all types of commit            
        putMilestoneM(id, retireType);
        insMap.setRetired(id);

        // Elements related to crucial signals:
        // RET: update inds
        updateMarkers(commitMarkers, id);

        updateInds(commitInds, id); // All types?
        commitInds.renameG = insMap.get(id).inds.renameG; // Part of above

        // RET: update target
        retiredTarget <= getCommitTarget(decMainUop(id), retInfo.takenBranch, retiredTarget, retInfo.target, retInfo.refetch, retInfo.exception);
    endtask


    task automatic putToWq(input InsId id, input logic exception, input logic refetch);        
        SqEntry found[$] = theSq.content.find_first with (item.mid == id);
        SqEntry foundElem = found[0];

        if (exception || refetch) foundElem.valReady = 0; // Make sure it's inactive

        csq.push_back(foundElem); // Normal
        putMilestoneM(id, InstructionMap::WqEnter); // Normal 
    endtask


    function automatic void updateMarkers(ref MarkerSet markers, input InsId id);
        UopName mainUop = decMainUop(id);
        if (mainUop inside {UOP_mem_mb_ld_f, UOP_mem_mb_ld_bf}) markers.mbLoadF = id;
        if (mainUop inside {UOP_mem_mb_st_f, UOP_mem_mb_st_bf}) markers.mbStoreF = id;
        if (mainUop inside {UOP_mem_mb_ld_f, UOP_mem_mb_ld_bf, UOP_mem_mb_st_f, UOP_mem_mb_st_bf , UOP_mem_lda}) markers.mbF = id;

        if (isLoadMemUop(mainUop)) markers.load = id;
        if (isStoreMemUop(mainUop)) markers.store = id;
        if (isLoadAqUop(mainUop)) markers.loadAq = id;
        if (isStoreRelUop(mainUop)) markers.storeRel = id;
    endfunction


    function automatic void releaseMarkers(ref MarkerSet markers, input logic unlocking, input InsId unlockingId);
        if (!unlocking) return;

        if (markers.load <= unlockingId) markers.load = -1;
        if (markers.store <= unlockingId) markers.store = -1;

        if (markers.mbLoadF <= unlockingId) markers.mbLoadF = -1;
        if (markers.mbStoreF <= unlockingId) markers.mbStoreF = -1;
        if (markers.mbF <= unlockingId) markers.mbF = -1;

        if (markers.loadAq <= unlockingId) markers.loadAq = -1;
        if (markers.storeRel <= unlockingId) markers.storeRel = -1;
    endfunction


    function automatic void updateInds(ref IndexSet inds, input InsId id);
        UopName mainUop = decMainUop(id);
        inds.rename = (inds.rename + 1) % (2*ROB_SIZE);
        if (isBranchUop(mainUop)) inds.bq = (inds.bq + 1) % (2*BC_QUEUE_SIZE);
        if (isLoadUop(mainUop)) inds.lq = (inds.lq + 1) % (2*LQ_SIZE);
        if (isStoreUop(mainUop)) inds.sq = (inds.sq + 1) % (2*SQ_SIZE);
    endfunction

    task automatic writeResult(input UopPacket p);
        if (!p.active) return;
        putMilestone(p.TMP_oid, InstructionMap::WriteResult);
        registerTracker.writeValue(decUname(p.TMP_oid), decId(U2M(p.TMP_oid)).dest, p.TMP_oid, p.result);
    endtask


    // General

    function automatic UopName decUname(input UidT uid);
        return (uid == UIDT_NONE) ? UOP_none : insMap.getU(uid).name;
    endfunction

    function automatic UopName decMainUop(input InsId id);
        return (id == -1) ? UOP_none : insMap.get(id).mainUop;
    endfunction
        
    //  decId - 1
    //  getAdr - 2
    function automatic AbstractInstruction decId(input InsId id);
        return (id == -1) ? DEFAULT_ABS_INS : insMap.get(id).basicData.dec;
    endfunction

    function automatic Mword getAdr(input InsId id);
        return (id == -1) ? 'x : insMap.get(id).basicData.adr;
    endfunction



    function automatic void putMilestoneF(input InsId id, input InstructionMap::Milestone kind);
        insMap.putMilestoneF(id, kind, cycleCtr);
    endfunction

    function automatic void putMilestoneM(input InsId id, input InstructionMap::Milestone kind);
        insMap.putMilestoneM(id, kind, cycleCtr);
    endfunction

    function automatic void putMilestoneC(input InsId id, input InstructionMap::Milestone kind);
        insMap.putMilestoneC(id, kind, cycleCtr);
    endfunction

    function automatic void putMilestone(input UidT uid, input InstructionMap::Milestone kind);
        insMap.putMilestone(uid, kind, cycleCtr);
    endfunction


    function automatic UopPacket tickP(input UopPacket op);        
        if (shouldFlushPoison(op.poison)) begin
            putMilestone(op.TMP_oid, InstructionMap::FlushPoison);
            return EMPTY_UOP_PACKET;
        end

        if (shouldFlushEvent(op.TMP_oid)) begin 
            putMilestone(op.TMP_oid, InstructionMap::FlushExec);
            return EMPTY_UOP_PACKET;
        end
        return op;
    endfunction

    function automatic UopPacket effP(input UopPacket op);
        if (shouldFlushPoison(op.poison)) return EMPTY_UOP_PACKET;            
        if (shouldFlushEvent(op.TMP_oid)) return EMPTY_UOP_PACKET;
        return op;
    endfunction

    
    function automatic logic shouldFlushId(input InsId id);
        if (id == -1) return 0;
        return lateEventInfo.redirect || (branchEventInfo.redirect && id > branchEventInfo.eventMid);
    endfunction 


    function automatic logic shouldFlushEventId(input InsId id);
        InsId lastRet = lastRetired;
        if (id == -1) return 0;
        return lateEventInfo.redirect || (branchEventInfo.redirect && id > branchEventInfo.eventMid) || (lastRet != -1 && lastRet >= id);
    endfunction


    function automatic logic shouldFlushEvent(input UidT uid);
        return shouldFlushId(U2M(uid));
    endfunction

    function automatic logic shouldFlushPoison(input Poison poison);
        ForwardingElement memStage0[N_MEM_PORTS] = theExecBlock.memImagesTr[0];
        foreach (memStage0[p])
            if (needsReplay(memStage0[p].status) && checkMemDep(poison, memStage0[p])) return 1;
        return 0;
    endfunction


    // Puts architectural state in a conevient starting point
    // - sys registers and other control info: initialize
    // - regular registers: zero
    // - data cache: initial state for tests
    // - trackers: reinitialized
    task automatic resetForTest();
        // No need to clear insMap

        GlobalParams gp;
        globalParams = gp;

        renamedEmul = new();
        retiredEmul = new();

        renamedEmul.resetCore();
        retiredEmul.resetCore();

        registerTracker = new();
        memTracker = new();

        programMem = null;
        
        dataCache.reset();
        theFrontend.instructionCache.reset();

        theFrontend.stageUnc_IP.active <= 0;
        theFrontend.stage_IP.active <= 0;

        branchCheckpointQueue.delete();
        
        sysUnit.reset();
        
        syncRegsFromRetiredCregs();
        syncCurrentConfigFromRegs();
        
        retiredTarget <= IP_RESET;
        lateEventInfo <= RESET_EVENT;
            
        csq = '{StoreQueueHelper::EMPTY_QENTRY, StoreQueueHelper::EMPTY_QENTRY};
    endtask


    task automatic preloadForTest();
        retiredEmul.initStatus(globalParams.initialCregs);
        renamedEmul.initStatus(globalParams.initialCregs);

        syncRegsFromRetiredCregs();
        syncCurrentConfigFromRegs();

        renamedEmul.programMappings = globalParams.preloadedInsTlbL2;
        retiredEmul.programMappings = globalParams.preloadedInsTlbL2;
        
        renamedEmul.dataMappings = globalParams.preloadedDataTlbL2;
        retiredEmul.dataMappings = globalParams.preloadedDataTlbL2;
        
        theFrontend.instructionCache.preloadForTest();
        dataCache.preloadForTest();
    endtask


    function automatic void syncRegsFromRetiredCregs();
        syncArrayFromCregs(sysUnit.sysRegs, retiredEmul.cregs);
    endfunction

    // Call every time sys regs are set
    function automatic void syncCurrentConfigFromRegs();
        CurrentConfig.enableMmu <= sysUnit.sysRegs[10][0];
        CurrentConfig.dbStep <= sysUnit.sysRegs[1][20];
        CurrentConfig.enArithExc <= sysUnit.sysRegs[1][17];
    endfunction


    function automatic logic pipesEmpty();
        return theRob.isEmpty && !lateEventInfoWaiting.active && stageEmptyAB(stageRename1);
    endfunction

    function automatic logic hasStaticEvent(InsId id);
        AbstractInstruction abs = insMap.get(id).basicData.dec;
        return isStaticEventIns(abs);
    endfunction

    function automatic InsId oldestCsq();
        SqEntry entry[$] = csq.min with (item.mid);
        return entry[0].mid;
    endfunction

endmodule
