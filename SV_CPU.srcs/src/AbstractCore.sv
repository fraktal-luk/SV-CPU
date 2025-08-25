
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

    //..............................
    int cycleCtr = 0;

    always @(posedge clk) cycleCtr++;


    struct {
        logic enableMmu = 0;
        logic dbStep = 0;
    } CurrentConfig;



    Mword insAdr;
    logic fetchEnable;
    InstructionCacheOutput icacheOut;
    DataCacheOutput dcacheOuts[N_MEM_PORTS];
    DataCacheOutput sysReadOuts[N_MEM_PORTS];

    // Overall
    logic fetchAllow, renameAllow, iqsAccepting, csqEmpty = 0, wqFree;
    IqLevels oooLevels, oooAccepts;
    int nFreeRegsInt = 0, nFreeRegsFloat = 0, bcqSize = 0;

    // OOO
    IndexSet renameInds = '{default: 0}, commitInds = '{default: 0};

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

    SystemRegisterUnit sysUnit();

    // Event control
        Mword retiredTarget = 0;


    MemWriteInfo TMP_writeInfos[2];

    ///////////////////////////

    DataL1        dataCache(clk, TMP_writeInfos, theExecBlock.dcacheTranslations, dcacheOuts);

    Frontend theFrontend(insMap, clk, branchEventInfo, lateEventInfo);

    // Rename
    OpSlotAB stageRename1 = '{default: EMPTY_SLOT_B};
    OpSlotAB sqOut, lqOut, bqOut; // UNUSED so far

    ReorderBuffer theRob(insMap, branchEventInfo, lateEventInfo, stageRename1);
    StoreQueue#(.SIZE(SQ_SIZE), .HELPER(StoreQueueHelper))
        theSq(insMap, memTracker, branchEventInfo, lateEventInfo, stageRename1, sqOut);
    StoreQueue#(.IS_LOAD_QUEUE(1), .SIZE(LQ_SIZE), .HELPER(LoadQueueHelper))
        theLq(insMap, memTracker, branchEventInfo, lateEventInfo, stageRename1, lqOut);
    StoreQueue#(.IS_BRANCH_QUEUE(1), .SIZE(BQ_SIZE), .HELPER(BranchQueueHelper))
        theBq(insMap, memTracker, branchEventInfo, lateEventInfo, stageRename1, bqOut);

    bind StoreQueue: theSq TmpSubSq submod();
    bind StoreQueue: theLq TmpSubLq submod();
    bind StoreQueue: theBq TmpSubBr submod();

    IssueQueueComplex theIssueQueues(insMap, branchEventInfo, lateEventInfo, stageRename1);

    ExecBlock theExecBlock(insMap, branchEventInfo, lateEventInfo);

    //////////////////////////////////////////

    assign fetchEnable = theFrontend.fetchEnable;
    assign insAdr = theFrontend.fetchAdr;

    assign wqFree = csqEmpty && !dataCache.uncachedSubsystem.uncachedBusy;

    assign theExecBlock.dcacheOuts = dcacheOuts;
    assign theExecBlock.sysOuts = sysReadOuts;

    assign TMP_writeInfos[0] = writeInfo;
    assign TMP_writeInfos[1] = EMPTY_WRITE_INFO;


    function automatic InsId oldestCsq();
        SqEntry entry[$] = csq.min with (item.mid);
        return entry[0].mid;
    endfunction


    always @(posedge clk) begin
        insMap.endCycle();

        readSysReg();

        advanceCommit(); // commitInds,    lateEventInfoWaiting, retiredTarget, csq, registerTracker, memTracker, retiredEmul, branchCheckpointQueue
        activateEvent(); // lateEventInfo, lateEventInfoWaiting, retiredtarget, sysRegs, retiredEmul

        begin // CAREFUL: putting this before advanceCommit() + activateEvent() has an effect on cycles 
            putWrite(); // csq, csqEmpty, drainHead
            performSysStore();  // sysRegs
        end

        if (lateEventInfo.redirect || branchEventInfo.redirect)
            redirectRest();     // stageRename1, renameInds, renamedEmul, registerTracker, memTracker, branchCheckpointQueue
        else
            runInOrderPartRe(); // stageRename1, renameInds, renamedEmul, registerTracker, memTracker, branchCheckpointQueue

        handleWrites(); // registerTracker

        updateBookkeeping();

        
        syncGlobalParamsFromRegs();

        insMap.commitCheck( csqEmpty ||  insMap.insBase.retired < oldestCsq() ); // Don't remove ops form base if csq still contains something that would be deleted
    end


    task automatic handleWrites();
        writeResult(theExecBlock.doneRegular0_E);
        writeResult(theExecBlock.doneRegular1_E);
        writeResult(theExecBlock.doneFloat0_E);
        writeResult(theExecBlock.doneFloat1_E);
        writeResult(theExecBlock.doneBranch_E);
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

    function automatic MemWriteInfo makeWriteInfo(input SqEntry sqe);
        return '{sqe.mid != -1 && sqe.valReady && !sqe.accessDesc.sys && !sqe.error && !sqe.refetch,
                sqe.accessDesc.vadr, sqe.translation.padr, sqe.val, sqe.accessDesc.size, sqe.accessDesc.uncachedStore};
    endfunction

    function automatic MemWriteInfo makeSysWriteInfo(input SqEntry sqe);
        return '{sqe.mid != -1 && sqe.valReady && sqe.accessDesc.sys && !sqe.error && !sqe.refetch,
                sqe.accessDesc.vadr, 'x, sqe.val, sqe.accessDesc.size, 'x};
    endfunction

    task automatic putWrite();        
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


    task automatic performSysStore();
        if (sysWriteInfo.req) sysUnit.setSysReg(sysWriteInfo.adr, sysWriteInfo.value);
    endtask

    task automatic readSysReg();
        foreach (sysReadOuts[p])
            sysReadOuts[p] <= sysUnit.getSysReadResponse(theExecBlock.accessDescs[p]);
    endtask


    assign oooLevels = '{
        iqRegular:   theIssueQueues.regularQueue.num,
        iqFloat:     theIssueQueues.floatQueue.num,
        iqBranch:    theIssueQueues.branchQueue.num,
        iqMem:       theIssueQueues.memQueue.num,
        iqStoreData: theIssueQueues.storeDataQueue.num
    };

    assign oooAccepts = getBufferAccepts(oooLevels);
    assign iqsAccepting = iqsAccept(oooAccepts);

    assign fetchAllow = fetchQueueAccepts(theFrontend.fqSize) && bcQueueAccepts(bcqSize);
    assign renameAllow = iqsAccepting && regsAccept(nFreeRegsInt, nFreeRegsFloat) && theRob.allow && theSq.allow && theLq.allow;;


    // Helper (inline it?)
    function logic regsAccept(input int nI, input int nF);
        return nI > RENAME_WIDTH && nF > RENAME_WIDTH;
    endfunction

    // Helper (inline it?)
    function logic fetchQueueAccepts(input int k);
        // TODO: careful about numbers accounting for pipe lengths! 
        return k <= FETCH_QUEUE_SIZE - 3; // 2 stages between IP stage and FQ
    endfunction

    function logic bcQueueAccepts(input int k);
        return k <= BC_QUEUE_SIZE - 3*FETCH_WIDTH - FETCH_QUEUE_SIZE*FETCH_WIDTH; // 2 stages + FETCH_QUEUE entries, FETCH_WIDTH each
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
                                    renameInds, renamedEmul);
        branchCheckpointQueue.push_back(cp);
    endtask


    function automatic UopName decodeUop(input AbstractInstruction ins);
        assert (OP_DECODING_TABLE.exists(ins.mnemonic)) else $fatal(2, "what instruction is this?? %p", ins.mnemonic);
        return OP_DECODING_TABLE[ins.mnemonic];
    endfunction


    task automatic renameOp(input InsId id, input int currentSlot, input Mword adr, input Word bits, input logic predictedDir, input Mword predictedTrg /*UNUSED so far*/);
        AbstractInstruction ins = decodeAbstract(bits);
        UopInfo mainUinfo;
        UopInfo uInfos[$];
        Mword target;

        UopName uopName = decodeUop(ins);

        InstructionInfo ii = initInsInfo(id, adr, bits, ins);

        // General, per ins
        InsDependencies deps = registerTracker.getArgDeps(ins); // For insMap

        // For insMap and mem queues
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

        if (isStoreIns(ins) || isLoadIns(ins)) begin
            Mword effAdr = calculateEffectiveAddress(ins, argVals);
            Translation tr = renamedEmul.translateDataAddress(effAdr);
            
            memTracker.add(id, uopName, ins, argVals, tr.padr); // DB
        end

        if (isBranchIns(ins)) saveCP(id); // Crucial state

        updateInds(renameInds, id); // Crucial state

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
            Mword sr2 = getSysReg(2);
            Mword sr3 = getSysReg(3);
            EventInfo lateEvt = getLateEvent(lateEventInfoWaiting, lateEventInfoWaiting.adr, sr2, sr3);
           
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

            // RET: generate late event
            if (breaksCommitId(theId)) begin
                InstructionInfo ii = insMap.get(theId);
                lateEventInfoWaiting <= eventFromOp(theId, ii.mainUop, ii.basicData.adr, ii.refetch, ii.exception, CurrentConfig.dbStep);
                cancelRest = 1; // Don't commit anything more if event is being handled
            end  
        end
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
        assert (retInfo.exception === info.exception) else $error("Not seen exc: %d\n%p\n%p", id, info, retInfo);

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

        verifyOnCommit(retInfo);

        // RET: update regs
        for (int u = 0; u < insInfo.nUops; u++) begin
            UidT uid = '{id, u};
            registerTracker.commit(decUname(uid), insMap.getU(uid).vDest, uid, retInfo.refetch || retInfo.exception); // Need to modify to handle Exceptional and Hidden
        end

        // RET: update WQ
        if (isStoreUop(decMainUop(id))) putToWq(id, retInfo.exception, retInfo.refetch);

        // RET: free DB queues
        if (isStoreUop(decMainUop(id)) || isLoadUop(decMainUop(id))) memTracker.remove(id); // All?
        if (isBranchUop(decMainUop(id))) begin // Br queue entry release
            BranchCheckpoint bce = branchCheckpointQueue.pop_front();
            assert (bce.id === id) else $error("Not matching op: %p / %p", bce, id);
        end

        // Need to modify to serve all types of commit            
        putMilestoneM(id, retireType);
        insMap.setRetired(id);

        // Elements related to crucial signals:
        // RET: update inds
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


    // MOVE?
    function automatic void updateInds(ref IndexSet inds, input InsId id);
        inds.rename = (inds.rename + 1) % (2*ROB_SIZE);
        if (isBranchUop(decMainUop(id))) inds.bq = (inds.bq + 1) % (2*BC_QUEUE_SIZE);
        if (isLoadUop(decMainUop(id))) inds.lq = (inds.lq + 1) % (2*LQ_SIZE);
        if (isStoreUop(decMainUop(id))) inds.sq = (inds.sq + 1) % (2*SQ_SIZE);
    endfunction


    function automatic Mword getSysReg(input Mword adr);
        return sysUnit.sysRegs[adr];
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


    function automatic logic shouldFlushEvent(input UidT uid);
        return lateEventInfo.redirect || (branchEventInfo.redirect && U2M(uid) > branchEventInfo.eventMid);
    endfunction

    function automatic logic shouldFlushPoison(input Poison poison);
        ForwardingElement memStage0[N_MEM_PORTS] = theExecBlock.memImagesTr[0];
        foreach (memStage0[p])
            if (needsReplay(memStage0[p].status) && checkMemDep(poison, memStage0[p])) return 1;
        return 0;
    endfunction


    assign sig = lateEventInfo.cOp == CO_send;
    assign wrong = lateEventInfo.cOp inside {CO_error, CO_undef};


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

        branchCheckpointQueue.delete();
        
        sysUnit.reset();
        
        syncRegsFromStatus();
        syncGlobalParamsFromRegs();
        
        retiredTarget <= IP_RESET;
        lateEventInfo <= RESET_EVENT;
            
        csq = '{StoreQueueHelper::EMPTY_QENTRY, StoreQueueHelper::EMPTY_QENTRY};
        
    endtask


    task automatic preloadForTest();
        
        // TODO: function in Emulator to do the 3 things below
        retiredEmul.status = globalParams.initialCoreStatus;
        retiredEmul.syncRegsFromStatus();
        retiredEmul.syncCregsFromSysRegs();
        
        renamedEmul.status = globalParams.initialCoreStatus;
        renamedEmul.syncRegsFromStatus();
        renamedEmul.syncCregsFromSysRegs();


        syncRegsFromStatus();
        syncGlobalParamsFromRegs();

        renamedEmul.programMappings = globalParams.preloadedInsTlbL2;
        retiredEmul.programMappings = globalParams.preloadedInsTlbL2;
        
        renamedEmul.dataMappings = globalParams.preloadedDataTlbL2;
        retiredEmul.dataMappings = globalParams.preloadedDataTlbL2;
        
        theFrontend.instructionCache.preloadForTest();
        dataCache.preloadForTest();
    endtask


        function automatic void syncRegsFromStatus();
            syncArrayFromCregs(sysUnit.sysRegs, retiredEmul.cregs);
        endfunction


        // Call every time sys regs are set
        function automatic void syncGlobalParamsFromRegs();
            CoreStatus tmpStatus;
            setStatusFromRegs(tmpStatus, sysUnit.sysRegs);

            CurrentConfig.enableMmu <= tmpStatus.enableMmu;
            CurrentConfig.dbStep <= sysUnit.sysRegs[1][20];
        endfunction

endmodule
