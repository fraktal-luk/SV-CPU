
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import EmulationDefs::*;

import UopList::*;
import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;
import ControlRegisters::*;
import ControlHandling::*;

import CacheDefs::*;

import Queues::*;

import Testing::GlobalParams;


typedef class InstructionMap;

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
    logic dummy ; //= 'z;

    GlobalParams globalParams;

    // DB        
    InstructionMap insMap = new();
    Emulator renamedEmul = new(), retiredEmul = new();
    PageBasedProgramMemory programMem;
    SparseDataMemory dataMem;

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
            logic enArithExc = 0; // Remove?
        logic enableFP = 0;
        RoundingMode rm = RM_Even;
        logic enTrapInv = 0;
        logic enTrapDiv0 = 0;
        logic enTrapOv = 0;
        logic enTrapUnd = 0;
        logic enTrapInex = 0; 
    } CurrentConfig;

    // Overall
    logic renameAllow, iqsAccepting, csqEmpty = 0, wqFree;
    IqLevels oooLevels, oooAccepts;
    int nFreeRegsInt = 0, nFreeRegsFloat = 0, bcqSize = 0;

    // OOO
    IndexSet renameInds = '{default: 0}, commitInds = '{default: 0};
    MarkerSet renameMarkers = '{default: -1}, commitMarkers = '{default: -1};
    TMP_PredState committedPredState = DEFAULT_PRED_STATE, committedPredStatePrev = DEFAULT_PRED_STATE;

    // Exec   FUTURE: encapsulate in backend?
    logic intRegsReadyV[N_REGS_INT] = '{default: 'x};
    logic floatRegsReadyV[N_REGS_FLOAT] = '{default: 'x};

    EventInfo branchEventInfo = EMPTY_EVENT_INFO;
    EventInfo lateEventInfo = EMPTY_EVENT_INFO;
    EventInfo lateEventInfoWaiting = EMPTY_EVENT_INFO;
    EventInfo lateEventInfoWaitingDb = EMPTY_EVENT_INFO;
    EventInfo lateEventInfoWaitingReset = EMPTY_EVENT_INFO;
    EventInfo lateEventInfoWaitingInt = EMPTY_EVENT_INFO;

    // Store interface
    // Committed
    SqEntry csq[$] = '{StoreQueueHelper::EMPTY_QENTRY, StoreQueueHelper::EMPTY_QENTRY};
    SqEntry drainHead = StoreQueueHelper::EMPTY_QENTRY;
    MemWriteInfo writeInfo = EMPTY_WRITE_INFO, sysWriteInfo = EMPTY_WRITE_INFO;

    MemWriteInfo dcacheWriteInfos[2];
    MemWriteInfo sysWriteInfos[1];


    SystemRegisterUnit sysUnit(theExecBlock.sysOuts_E1, sysWriteInfos);

    logic barrierUnlocking;
    InsId barrierUnlockingMid;
    InsId latestUnlockingMid = -1;

    ///////////////////////////

    DataL1   dataCache(clk, dcacheWriteInfos, theExecBlock.dcacheTranslationsE0d, theExecBlock.dcacheOuts_E1, theExecBlock.uncachedOuts_E1);

    Frontend theFrontend(insMap, clk, branchEventInfo, lateEventInfo);

    // Rename
    FrontStage stageRename1 = DEFAULT_FRONT_STAGE;

    EventUnit eventUnit(clk);

    ReorderBuffer theRob(insMap, branchEventInfo, lateEventInfo, stageRename1.arr);

    StoreQueue#(.SIZE(SQ_SIZE), .HELPER(StoreQueueHelper))
        theSq(insMap, memTracker, branchEventInfo, lateEventInfo, stageRename1.arr);
    StoreQueue#(.IS_LOAD_QUEUE(1), .SIZE(LQ_SIZE), .HELPER(LoadQueueHelper))
        theLq(insMap, memTracker, branchEventInfo, lateEventInfo, stageRename1.arr);
    StoreQueue#(.IS_BRANCH_QUEUE(1), .SIZE(BQ_SIZE), .HELPER(BranchQueueHelper))
        theBq(insMap, memTracker, branchEventInfo, lateEventInfo, stageRename1.arr);

    bind StoreQueue: theSq TmpSubSq submod();
    bind StoreQueue: theLq TmpSubLq submod();
    bind StoreQueue: theBq TmpSubBr submod();

    IssueQueueComplex theIssueQueues(insMap, branchEventInfo, lateEventInfo, stageRename1.arr);

    ExecBlock theExecBlock(insMap, branchEventInfo, lateEventInfo);

    MemoryNetwork mn();


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

    assign sig = lateEventInfo.etype == PE_HW_SEND;


    always @(posedge clk) begin
        insMap.endCycle();

        sysUnit.handleReads();

        advanceCommit(); // commitInds, lateEventInfoWaiting, retiredTarget, csq, registerTracker, memTracker, retiredEmul, branchCheckpointQueue

        prepareLateEvents();


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

        insMap.commitCheck( csqEmpty ||  insMap.insBase.retired < oldestCsq() ); // Don't remove ops from base if csq still contains something that would be deleted
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
        writeResult(theExecBlock.doneMem1_E);
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


    // Frontend, rename and everything before getting to OOO queues
    task automatic runInOrderPartRe();
        OpSlotAF ops = theFrontend.stageRename0.arr;
        TMP_PredState predState = theFrontend.stageRename0.predState;
        int bi = 0;

        if (anyActiveB(ops))
            renameInds.renameG = (renameInds.renameG + 1) % (2*theRob.DEPTH);

        foreach (ops[i]) begin
            if (ops[i].active !== 1) continue;

            ops[i].mid = insMap.insBase.lastM + 1;
            renameOp(ops[i].mid, ops[i], i, bi, theFrontend.stageRename0.evt, theFrontend.stageRename0.vadr, predState);

            if (ops[i].branch) bi++;
        end

        stageRename1 <= theFrontend.stageRename0;
        stageRename1.arr <= ops;
    endtask


    task automatic redirectRest();
        markKilledRenameStage(stageRename1.arr);
        stageRename1 <= DEFAULT_FRONT_STAGE;

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

    task automatic saveCP(input InsId id, input int branchInd, input TMP_PredState predState);
        BranchCheckpoint cp = new(id,
                                    registerTracker.ints.writersR, registerTracker.floats.writersR,
                                    registerTracker.ints.MapR, registerTracker.floats.MapR,
                                    renameInds, renameMarkers,
                                    branchInd,
                                    renamedEmul,
                                    predState);
        branchCheckpointQueue.push_back(cp);
    endtask


    task automatic renameOp(input InsId id,
                            input OpSlotF opSlot,
                            input int currentSlot, // including unused slots before beginning
                            input int currentBranch, // index of branch within used part of block
                            input ProgramEvent evt, input Mword vadr, input TMP_PredState predState);

        AbstractInstruction insPre = evt == PE_NONE ? decodeAbstract(opSlot.bits) : FETCH_ERROR_INS;

        // Based on CurrentConfig, Convert disabled instructions to static exceptions
        AbstractInstruction ins = suppressDisabledInstruction(insPre, CurrentConfig.enableFP); // ins converted to static event if applicable

        Mword adr = (evt == PE_FETCH_UNALIGNED_ADDRESS) ? vadr : opSlot.adr;
        Mword target;

        UopInfo mainUinfo;
        UopInfo uInfos[$];

        UopName uopName = decodeUop(ins);
        InstructionInfo ii = initInsInfo(id, adr, opSlot.bits, ins, opSlot.first);
        InsDependencies deps = registerTracker.getArgDeps(ins);

        Mword argVals[3] = getArgs(renamedEmul.coreState.intRegs, renamedEmul.coreState.floatRegs, ins.sources, parsingMap[ins.def.f].typeSpec);
        Mword result = renamedEmul.computeResult(adr, ins); // Must be before modifying state. For ins map

        runInEmulator(renamedEmul, adr, opSlot.bits);

        if (evt != PE_NONE) begin
            ii.exception = 1;
            ii.staticEvt = 1;
            ii.hwEventType = evt;
        end
        else if (isStaticEventIns(ins)) begin
            if (isSilentEventIns(ins)) ii.silentEvt = 1;
            else ii.staticEvt = 1;

            ii.exception = 1;
            ii.hwEventType = eventFromUop(uopName);
        end
        else if (CurrentConfig.dbStep) begin 
            ii.hwEventType = PE_EXT_DEBUG;
        end

        if (renamedEmul.status.exceptionRaised) begin
            ii.hwEventType = renamedEmul.status.eventType;
        end

        // May be known by now to simulated core (fetch errors etc., sets .staticEvt) or not yet (will set .dynamicEvt)
        ii.emulException = renamedEmul.status.exceptionRaised;

        renamedEmul.drain();

        target = renamedEmul.coreState.target; // For insMap

        renamedEmul.catchDbTrap();

        // Main op info
        ii.mainUop = uopName;
        ii.inds = renameInds;
        ii.basicData.target = target;
        ii.firstUop = insMap.insBase.lastU + 1;
        ii.nUops = -1;

        if (isBranchIns(ins)) ii.frontBranch = opSlot.takenBranch;

        // Generate info for uops
        mainUinfo.id = '{id, -1};
        mainUinfo.name = uopName;
        mainUinfo.vDest = ins.dest;
        mainUinfo.physDest = -1;
        mainUinfo.deps = deps;

        mainUinfo.argsE = argVals;
        mainUinfo.resultE = result;
        mainUinfo.argError = 'x;


        // If unlocking now and latest barrier is being unlocked (or should have been), ignore the barrier
        if (!barrierUnlocking || barrierUnlockingMid < renameMarkers.mbF) begin
            mainUinfo.barrier = isMemIns(ins) ? renameMarkers.mbF : -1;
        end

        uInfos = splitUop(mainUinfo);
        ii.nUops = uInfos.size(); 

        for (int u = 0; u < ii.nUops; u++) begin
            UopInfo uInfo = uInfos[u];
            uInfos[u].physDest = registerTracker.reserve(uInfo.name, uInfo.vDest, '{id, u});
            
            if (uopHasIntDest(uInfo.name) && uInfo.vDest == -1) $error(" reserve -1!  %d, %s", id, disasm(ii.basicData.bits));
        end

        insMap.allocate(id, ii, uInfos);

        if (isStoreIns(ins) || isLoadIns(ins) || isMemBarrierIns(ins)) begin
            Mword effAdr = calculateEffectiveAddress(ins, argVals);
            Translation tr = renamedEmul.translateDataAddress(effAdr);
            memTracker.add(id, uopName, ins, argVals, tr.padr); // DB
        end

        if (isBranchIns(ins)) saveCP(id, currentBranch, predState); // Crucial state

        updateInds(renameInds, id); // Crucial state
        updateMarkers(renameMarkers, id); // Crucial state

        putMilestoneM(id, InstructionMap::Rename);
    endtask


    function automatic void TMP_checkCtrl(input InsId theId, input InstructionInfo ii);
        // TODO: DB is not included in general, so it needs new else if'?
        if (eventUnit.general.id == theId) begin
            assert (ii.refetch || ii.exception || isStaticEventUop(ii.mainUop) || CurrentConfig.dbStep) else $fatal(2, "Event not noted in map\n%p", ii);
        end
        else begin
            assert (!ii.refetch && !ii.exception && !isStaticEventUop(ii.mainUop) && !ii.emulException)
            else $fatal(2, "Event in map not registered in HW\n%p", ii);
        end
    endfunction


    task automatic advanceCommit();
        logic foundEvent = 0;

        foreach (theRob.prevRow[i]) begin
            InsId theId = theRob.prevRow[i].mid;
            InstructionInfo ii;

            if (theRob.prevRow[i].used !== 1 || theId == -1) continue;
            if (foundEvent) $fatal(2, "Committing after breaking op");

            ii = insMap.get(theId);

            commitOp(theId);

            if (theId == (eventUnit.fpInv.id))  sysUnit.setFpInv();
            if (theId == (eventUnit.fpDiv0.id)) sysUnit.setFpDiv0();
            if (theId == (eventUnit.fpOv.id))   sysUnit.setFpOv();
            if (theId == (eventUnit.fpUnd.id))  sysUnit.setFpUnd();
            if (theId == (eventUnit.fpInex.id)) sysUnit.setFpInex();

            syncCurrentConfigFromRegs();

            lastRetired <= theId;

            if (isControlUop(ii.mainUop) || ii.refetch || ii.exception
                || CurrentConfig.dbStep
            ) begin
                assert (theRob.prevRowEvent) else $fatal(2, "Event {%d} detected but not known in ROB", theId);

                foundEvent = 1;

                TMP_checkCtrl(theId, ii);
            end
        end

        releaseMarkers(commitMarkers, barrierUnlocking, barrierUnlockingMid);
    endtask


    task automatic prepareLateEvents();
        if (theRob.prevRowEvent) begin
            if (eventUnit.general.id != -1 && (eventUnit.dbEvt.id == -1 || eventUnit.general.id <= eventUnit.dbEvt.id)) begin
                Mword adr = insMap.get(eventUnit.general.id).basicData.adr;
                lateEventInfoWaiting <= eventFromOp(adr,  eventUnit.general);
            end
            else if (eventUnit.dbEvt.id != -1) begin
                lateEventInfoWaitingDb <= DB_EVENT;
            end
            else
                $fatal(2, "Wrong event detection in ROB");
        end

        if (eventUnit.resetEvt.active           && noWaitingEvents()
        ) begin
            lateEventInfoWaitingReset <= RESET_EVENT;
            retiredEmul.resetSignal();  // TODO: check whether this and interrupt can be done in fireLateEvent
        end
        else if (eventUnit.interruptEvt.active  && noWaitingEvents()
        ) begin
            lateEventInfoWaitingInt <= INT_EVENT;
            $display(">> Interrupt !!!");
                $display("Pre target: %X", retiredEmul.coreState.target);
            retiredEmul.interrupt();
                $display("After:      %X", retiredEmul.coreState.target);
        end

        lateEventInfo <= EMPTY_EVENT_INFO;

        if (wqFree) fireLateEvent();
    endtask


    task automatic fireLateEvent();
        if (lateEventInfoWaitingReset.active) begin
            sysUnit.saveStateAsync(theRob.trg, lateEventInfoWaitingReset.etype);
            lateEventInfo <= lateEventInfoWaitingReset;          
        end
        else if (lateEventInfoWaitingInt.active) begin
            sysUnit.saveStateAsync(theRob.trg, lateEventInfoWaitingInt.etype);
            lateEventInfo <= lateEventInfoWaitingInt;        
        end
        else if (lateEventInfoWaitingDb.active) begin
            sysUnit.saveStateAsync(theRob.trg, lateEventInfoWaitingDb.etype);
            lateEventInfo <= lateEventInfoWaitingDb;            
        end
        else if (lateEventInfoWaiting.active) begin
            Mword sr2 = sysUnit.sysRegs[2], sr3 = sysUnit.sysRegs[3];
            sysUnit.modifyStateSync(lateEventInfoWaiting.adr, eventUnit.lastEvtAD, eventUnit.lastEvtTr, eventUnit.general.etype);
            lateEventInfo <= getLateEvent(lateEventInfoWaiting, sr2, sr3);;
        end
        else
            return;

        lateEventInfoWaiting <= EMPTY_EVENT_INFO;
        lateEventInfoWaitingDb <= EMPTY_EVENT_INFO;
        lateEventInfoWaitingReset <= EMPTY_EVENT_INFO;
        lateEventInfoWaitingInt <= EMPTY_EVENT_INFO;
    endtask



    function automatic logic noWaitingEvents();
        return
                   eventUnit.backendState != BS_HANDLING
                && theRob.isEmpty;
    endfunction


    function automatic void checkUops(input InsId id);
        InstructionInfo info = insMap.get(id);

        for (int u = 0; u < info.nUops; u++) begin
            UopInfo uinfo = insMap.getU('{id, u});    
            if (uopHasIntDest(uinfo.name) || uopHasFloatDest(uinfo.name)) begin // DB
                assert (uinfo.resultA === uinfo.resultE && uinfo.argError === 0) else begin
                    retiredEmul.getBasicDbView();
                    $fatal(2, " not matching result. %s; %X but should be %X", disasm(info.basicData.bits), uinfo.resultA, uinfo.resultE);
                end
            end
        end
    endfunction

        // needs InstructionInfo  -> ControlHandling ?
        function automatic void checkEventStatus(input InstructionInfo info, input EventDesc general, input EventDesc dbEvt);
            logic generalEvent = (general.id == info.id);
            logic debugEvent = (dbEvt.id == info.id);

            logic eventPresent = (
                CurrentConfig.dbStep ||
                info.refetch || info.dynamicEvt || info.staticEvt || info.silentEvt
            );

            assert ((generalEvent || debugEvent) === eventPresent) else $fatal(2, "Mismatch at op\n%p:\n%p\n dbs %d ", info, general, CurrentConfig.dbStep);

            if (eventPresent) begin
                assert ((general.etype == info.hwEventType) || (dbEvt.etype == PE_EXT_DEBUG && info.hwEventType == PE_EXT_DEBUG))
                    else $error("wrong: %p / %p / %p", general.etype, info.hwEventType, dbEvt);
            end

            // .emulException implies .exception
            assert (!info.emulException || info.exception) else $error("Not seen exc: %d\n%p", info.id, info);
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

    task automatic verifyOnCommit(input InsId id);
        InstructionInfo info = insMap.get(id);

        InstructionMap::Milestone retireType =
            info.dynamicEvt ? InstructionMap::RetireException : (info.refetch ? InstructionMap::RetireRefetch : InstructionMap::Retire);

        checkUnimplementedInstruction(info.basicData.dec); // All types of commit?

        checkEventStatus(info, eventUnit.general, eventUnit.dbEvt);

        assert (retiredEmul.coreState.target === info.basicData.adr) else begin
            retiredEmul.getBasicDbView();
            $fatal(2, "Commit: mm adr %h / %h", retiredEmul.coreState.target, info.basicData.adr);
        end

        if (info.refetch) return;

        // Only Normal commit
        if (!info.exception) checkUops(id);

        // Normal or Exceptional
        runInEmulator(retiredEmul, info.basicData.adr, info.basicData.bits);
        retiredEmul.drain();
        retiredEmul.catchDbTrap();

        putMilestoneM(id, retireType);
        insMap.setRetired(id);
    endtask



    task automatic commitOp(input InsId id);
        InstructionInfo insInfo = insMap.get(id);
        logic abnormal = insInfo.refetch || insInfo.dynamicEvt;

        verifyOnCommit(id);

        // RET: update regs
        for (int u = 0; u < insInfo.nUops; u++) begin
            UidT uid = '{id, u};
            registerTracker.commit(decUname(uid), insMap.getU(uid).vDest, uid, abnormal); // Need to modify to handle Exceptional and Hidden
        end

        // RET: update WQ
        if (isStoreUop(decMainUop(id)) || isMemBarrierUop(decMainUop(id))) putToWq(id, abnormal);

        // RET: free DB queues
        if (isStoreUop(decMainUop(id)) || isLoadUop(decMainUop(id)) || isMemBarrierUop(decMainUop(id))) memTracker.remove(id); // All?

        // Start new block for predictor
        if (CurrentConfig.enableMmu) begin
            if (insInfo.firstInGroup) begin
                committedPredStatePrev = committedPredState;
                committedPredState = updatePred(committedPredState, 'z);
            end
        end

        if (isBranchUop(decMainUop(id))) begin // Br queue entry release
            BranchCheckpoint bce = branchCheckpointQueue.pop_front();
            assert (bce.id === id) else $error("Not matching op: %p / %p", bce, id);
            assert (bce.predState === committedPredStatePrev)
                else $error("Diffr, op %d\n%d: %s\nprev pred state:\n%p\n%p", id, insInfo.basicData.adr, disasm(insInfo.basicData.bits), bce.predState, committedPredStatePrev);

            if (CurrentConfig.enableMmu) begin
                if (insInfo.takenBranch)
                    committedPredState = replacePred(committedPredState, TMP_bpEncode({0, insInfo.basicData.adr[3:2]}));
                else
                    committedPredState = replacePred(committedPredState, 0);
            end
        end

        // Elements related to crucial signals:
        // RET: update inds
        updateMarkers(commitMarkers, id);

        updateInds(commitInds, id); // All types?
        commitInds.renameG = insMap.get(id).inds.renameG; // Part of above
    endtask


    task automatic putToWq(input InsId id, input logic cancel);
        SqEntry found[$] = theSq.content.find_first with (item.mid == id);
        SqEntry foundElem = found[0];

        if (cancel) foundElem.valReady = 0; // Make sure it's inactive

        csq.push_back(foundElem); // Normal
        putMilestoneM(id, InstructionMap::WqEnter); // Normal 
    endtask


    function automatic void updateMarkers(ref MarkerSet markers, input InsId id);
        UopName mainUop = decMainUop(id);
        if (mainUop inside {UOP_mem_mb_ld_f, UOP_mem_mb_ld_bf}) markers.mbLoadF = id;
        if (mainUop inside {UOP_mem_mb_st_f, UOP_mem_mb_st_bf}) markers.mbStoreF = id;
        if (mainUop inside {UOP_mem_mb_ld_f, UOP_mem_mb_ld_bf, UOP_mem_mb_st_f, UOP_mem_mb_st_bf , UOP_mem_lda}) markers.mbF = id;

        if (isLoadMemUop(mainUop))  markers.load = id;
        if (isStoreMemUop(mainUop)) markers.store = id;
        if (isLoadAqUop(mainUop))   markers.loadAq = id;
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
        if (!op.active) return EMPTY_UOP_PACKET;

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
        if (!op.active) return EMPTY_UOP_PACKET;
        if (shouldFlushPoison(op.poison)) return EMPTY_UOP_PACKET;            
        if (shouldFlushEvent(op.TMP_oid)) return EMPTY_UOP_PACKET;
        return op;
    endfunction

    function automatic logic shouldFlushEvent(input UidT uid);
        return shouldFlushId(U2M(uid));
    endfunction

    function automatic logic shouldFlushId(input InsId id);
        if (id == -1) return 0;
        return lateEventInfo.redirect || (branchEventInfo.redirect && id > branchEventInfo.eventMid);
    endfunction 

    function automatic logic shouldFlushPoison(input Poison poison);
        ForwardingElement memStage0[N_MEM_PORTS] = theExecBlock.memImagesTr[0];
        foreach (memStage0[p])
            if (memStage0[p].active && needsReplay(memStage0[p].status) && checkMemDep(poison, memStage0[p])) return 1;
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

        programMem = new();
        dataMem = new();

        dataCache.reset();
        theFrontend.instructionCache.reset();
        theFrontend.reset();

        branchCheckpointQueue.delete();

        sysUnit.reset();
        
        syncRegsFromRetiredCregs();
        syncCurrentConfigFromRegs();

        theRob.trg <= IP_RESET;
        lateEventInfo <= RESET_EVENT;
            
        csq = '{StoreQueueHelper::EMPTY_QENTRY, StoreQueueHelper::EMPTY_QENTRY};
    endtask


    task automatic preloadForTest();
        renamedEmul.initCore(globalParams.initialCregs, globalParams.preloadedInsTlbL2, globalParams.preloadedDataTlbL2);
        retiredEmul.initCore(globalParams.initialCregs, globalParams.preloadedInsTlbL2, globalParams.preloadedDataTlbL2);

        syncRegsFromRetiredCregs();
        syncCurrentConfigFromRegs();

        renamedEmul.progMem.setLike(programMem);
        renamedEmul.dataMem.setLike(dataMem);

        retiredEmul.progMem.setLike(programMem);
        retiredEmul.dataMem.setLike(dataMem);

        theFrontend.instructionCache.preloadForTest();
        dataCache.preloadForTest();

        if (!sysUnit.sysRegs[10][0]) begin // If MMU off
            theFrontend.instructionCache.reset();
            dataCache.reset();
        end
    endtask


    function automatic void syncRegsFromRetiredCregs();
        syncArrayFromCregs(sysUnit.sysRegs, retiredEmul.cregs);
    endfunction

    // Call every time sys regs are set
    function automatic void syncCurrentConfigFromRegs();
        CurrentConfig.enableMmu <= sysUnit.sysRegs[10][0];
        CurrentConfig.dbStep <= sysUnit.sysRegs[1][20];
        CurrentConfig.enableFP = sysUnit.sysRegs[8][15];
        CurrentConfig.rm = RoundingMode'(sysUnit.sysRegs[8][13:12]);
        CurrentConfig.enTrapInv = sysUnit.sysRegs[8][10];
        CurrentConfig.enTrapDiv0 = sysUnit.sysRegs[8][9];
        CurrentConfig.enTrapOv = sysUnit.sysRegs[8][8];
        CurrentConfig.enTrapUnd = sysUnit.sysRegs[8][7];
        CurrentConfig.enTrapInex = sysUnit.sysRegs[8][6];
    endfunction


    function automatic logic pipesEmpty();
        return theRob.isEmpty && !lateEventInfoWaiting.active && !stageRename1.active;
    endfunction

    function automatic logic hasStaticEvent(InsId id);
        AbstractInstruction abs = insMap.get(id).basicData.dec;
        return isStaticEventIns(abs);
    endfunction

    function automatic InsId oldestCsq();
        SqEntry entry[$] = csq.min with (item.mid);
        return entry[0].mid;
    endfunction

    function automatic Mword findTarget(input UopName uname, input Mword adr, input BqEntry entries[$]);
        Mword executed = 'x;
        logic taken = 'x;

        if (isBranchUop(uname)) begin
            assert (entries.size() == 1) else $fatal(2, "Branch not in BQ");
            executed = isBranchRegUop(uname) ? entries[0].regTarget : entries[0].immTarget;
            taken = entries[0].taken;
        end

        if (isBranchUop(uname) && taken) return executed;
        else return adr + 4;
    endfunction


        logic ch0, ch1, ch2;
        // assign ch0 = stageEmptyAB(stageRename1);
        // assign ch1 = stageRename1.active;
        // assign ch2 = stageEmptyAB(stageRename1) === !stageRename1.active;

endmodule
