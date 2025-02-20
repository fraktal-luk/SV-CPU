
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import UopList::*;
import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;
import ControlHandling::*;

import CacheDefs::*;

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
        
    InstructionMap insMap = new();
    Emulator renamedEmul = new(), retiredEmul = new();

    RegisterTracker #(N_REGS_INT, N_REGS_FLOAT) registerTracker = new();
    MemTracker memTracker = new();
    
    BranchCheckpoint branchCheckpointQueue[$:BC_QUEUE_SIZE];

    //..............................
    int cycleCtr = 0;

    always @(posedge clk) cycleCtr++;


    Mword insAdr;
    //Word instructionCacheOut[FETCH_WIDTH];
    InstructionCacheOutput icacheOut;
    DataCacheOutput dcacheOuts[N_MEM_PORTS];

    // Overall
    logic fetchAllow, renameAllow, iqsAccepting, csqEmpty = 0;
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
    //    Events evts;


    // Store interface
        // Committed
        StoreQueueEntry csq[$] = '{EMPTY_SQE, EMPTY_SQE};

        StoreQueueEntry storeHead = EMPTY_SQE, drainHead = EMPTY_SQE;
        MemWriteInfo writeInfo = EMPTY_WRITE_INFO;
    
    // Event control
        Mword sysRegs[32];
        Mword retiredTarget = 0;


    DataReadReq TMP_readReqs[N_MEM_PORTS];
    MemWriteInfo TMP_writeInfos[2];

    ///////////////////////////

    InstructionL1 instructionCache(clk, insAdr, /*instructionCacheOut,*/ icacheOut);
    DataL1        dataCache(clk, TMP_readReqs, TMP_writeInfos, dcacheOuts);

    Frontend theFrontend(insMap, branchEventInfo, lateEventInfo);

    // Rename
    OpSlotAB stageRename1 = '{default: EMPTY_SLOT_B};
    OpSlotAB sqOut, lqOut, bqOut; // UNUSED so far

    ReorderBuffer theRob(insMap, branchEventInfo, lateEventInfo, stageRename1);
    StoreQueue#(.SIZE(SQ_SIZE), .HELPER(StoreQueueHelper))
        theSq(insMap, memTracker, branchEventInfo, lateEventInfo, stageRename1, sqOut, theExecBlock.toSq, theExecBlock.toSqE2);
    StoreQueue#(.IS_LOAD_QUEUE(1), .SIZE(LQ_SIZE), .HELPER(LoadQueueHelper))
        theLq(insMap, memTracker, branchEventInfo, lateEventInfo, stageRename1, lqOut, theExecBlock.toLq, theExecBlock.toLqE2);
    StoreQueue#(.IS_BRANCH_QUEUE(1), .SIZE(BQ_SIZE), .HELPER(BranchQueueHelper))
        theBq(insMap, memTracker, branchEventInfo, lateEventInfo, stageRename1, bqOut, theExecBlock.toBq, '{default: EMPTY_UOP_PACKET});

    IssueQueueComplex theIssueQueues(insMap, branchEventInfo, lateEventInfo, stageRename1);

    ExecBlock theExecBlock(insMap, branchEventInfo, lateEventInfo);

    //////////////////////////////////////////

    assign TMP_readReqs = theExecBlock.readReqs;
    assign theExecBlock.dcacheOuts = dcacheOuts;

    assign TMP_writeInfos[0] = writeInfo;
    assign TMP_writeInfos[1] = EMPTY_WRITE_INFO;


    always @(posedge clk) begin
        insMap.endCycle();

        advanceCommit(); // commitInds,    lateEventInfoWaiting, retiredTarget, csq, registerTracker, memTracker, retiredEmul, branchCheckpointQueue
        activateEvent(); // lateEventInfo, lateEventInfoWaiting, retiredtarget, sysRegs, retiredEmul

        begin // CAREFUL: putting this before advanceCommit() + activateEvent() has an effect on cycles 
            putWrite(); // csq, csqEmpty, storeHead, drainHead
            
            // TODO: handle analogously to writeInfo in data cache?
            performSysStore();  // sysRegs
        end

        if (lateEventInfo.redirect || branchEventInfo.redirect)
            redirectRest();     // stageRename1, renameInds, renamedEmul, registerTracker, memTracker, branchCheckpointQueue
        else
            runInOrderPartRe(); // stageRename1, renameInds, renamedEmul, registerTracker, memTracker, branchCheckpointQueue

        handleWrites(); // registerTracker

        updateBookkeeping();

            insMap.commitCheck();

        insMap.insBase.setDbStr();
        insMap.dbStr = insMap.insBase.dbStr;
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

        // Overall DB
            coreDB.insMapSize = insMap.size();
            coreDB.trSize = memTracker.transactions.size();
    endtask


    ////////////////

    function automatic MemWriteInfo makeWriteInfo(input StoreQueueEntry sqe);
        MemWriteInfo res = '{sqe.active && !sqe.sys && !sqe.cancel, sqe.adr, sqe.val, sqe.size, sqe.uncached};
        return res;
    endfunction


    task automatic putWrite();
        StoreQueueEntry sqe = drainHead;
        
        if (sqe.mid != -1) begin
            memTracker.drain(sqe.mid);
            putMilestoneC(sqe.mid, InstructionMap::WqExit);
        end
        void'(csq.pop_front());

        assert (csq.size() > 0) else $fatal(2, "csq must never become physically empty");
 
        if (csq.size() < 2) begin // slot [0] doesn't count, it is already written and serves to signal to drain SQ 
            csq.push_back(EMPTY_SQE);
            csqEmpty <= 1;
        end
        else begin
            csqEmpty <= 0;
        end
        
        drainHead <= csq[0];
        storeHead <= csq[1];
        writeInfo <= makeWriteInfo(csq[1]);
    endtask


    task automatic performSysStore();
        if (storeHead.active && storeHead.sys && !storeHead.cancel)
            setSysReg(storeHead.adr, storeHead.val);
    endtask


    assign oooLevels.iqRegular = theIssueQueues.regularQueue.num;
    assign oooLevels.iqFloat = theIssueQueues.floatQueue.num;
    assign oooLevels.iqBranch = theIssueQueues.branchQueue.num;
    assign oooLevels.iqMem = theIssueQueues.memQueue.num;
    assign oooLevels.iqStoreData = theIssueQueues.storeDataQueue.num;

    assign oooAccepts = getBufferAccepts(oooLevels);
    assign iqsAccepting = iqsAccept(oooAccepts);

    assign fetchAllow = fetchQueueAccepts(theFrontend.fqSize) && bcQueueAccepts(bcqSize);
    assign renameAllow = iqsAccepting && regsAccept(nFreeRegsInt, nFreeRegsFloat) && theRob.allow && theSq.allow && theLq.allow;;
        
        
        // MOVE?
        function automatic IqLevels getBufferAccepts(input IqLevels levels);
            IqLevels res;
            res.iqRegular = levels.iqRegular <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH;
            res.iqFloat = levels.iqFloat <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH;
            res.iqBranch = levels.iqBranch <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH;
            res.iqMem = levels.iqMem <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH;
            res.iqStoreData = levels.iqStoreData <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH;
            return res;
        endfunction
    
        function automatic logic iqsAccept(input IqLevels acc);
            return 1
                    && acc.iqRegular
                    && acc.iqFloat
                    && acc.iqBranch
                    && acc.iqMem
                    && acc.iqStoreData;
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
            
            if (lateEventInfo.cOp == CO_reset) registerTracker.restoreReset();
            else                               registerTracker.restoreStable();

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

        if (isStoreIns(ins) || isLoadIns(ins)) memTracker.add(id, uopName, ins, argVals); // DB

        if (isBranchIns(ins)) saveCP(id); // Crucial state

        updateInds(renameInds, id); // Crucial state

        putMilestoneM(id, InstructionMap::Rename);
    endtask


    function automatic logic breaksCommitId(input InsId id);
        InstructionInfo insInfo = insMap.get(id);
        return (isControlUop(decMainUop(id)) || insInfo.refetch || insInfo.exception);
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
            Mword waitingAdr = lateEventInfoWaiting.adr;
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

        foreach (theRob.retirementGroup[i]) begin
            InsId theId = theRob.retirementGroup[i].mid;

            if (theRob.retirementGroup[i].active !== 1 || theId == -1) continue;
            if (cancelRest) $fatal(2, "Committing after break");

            commitOp(theRob.retirementGroup[i]);

            // RET: generate late event
            if (breaksCommitId(theId)) begin
                logic refetch = insMap.get(theId).refetch;
                logic exception = insMap.get(theId).exception;
                lateEventInfoWaiting <= eventFromOp(theId, decMainUop(theId), getAdr(theId), refetch, exception);
                cancelRest = 1; // Don't commit anything more if event is being handled
            end
            
        end
        
    endtask

    
    
    function automatic void checkUops(input InsId id);
        InstructionInfo info = insMap.get(id);
        
        for (int u = 0; u < info.nUops; u++) begin
            UopInfo uinfo = insMap.getU('{id, u});
            UopName uname = uinfo.name;
    
            if (uopHasIntDest(uname) || uopHasFloatDest(uname)) begin // DB
                assert (uinfo.resultA === uinfo.resultE && uinfo.argError === 0)
                     //else $error(" not matching result. %p, %s; %d but should be %d", TMP_properOp(id), disasm(info.basicData.bits), uinfo.resultA, uinfo.resultE);
                     else $error(" not matching result. %s; %d but should be %d", disasm(info.basicData.bits), uinfo.resultA, uinfo.resultE);
            end
        end
    endfunction



    task automatic verifyOnCommit(input RetirementInfo retInfo);
        InsId id = retInfo.mid;
        InstructionInfo info = insMap.get(id);

        Mword trg = retiredEmul.coreState.target; // DB
        Mword nextTrg;
        checkUnimplementedInstruction(decId(id)); // All types of commit?

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
    
        // Normal (branches don't cause exceptions so far, check for exc can be omitted)
        if (!info.exception && isBranchUop(decMainUop(id))) begin // DB         
            if (retInfo.takenBranch === 1) begin
                assert (retInfo.target === nextTrg) else $fatal(2, "MIsmatch of trg: %d, %d", retInfo.target, nextTrg);
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

        logic refetch = retInfo.refetch;
        logic exception = retInfo.exception;
        InstructionMap::Milestone retireType = exception ? InstructionMap::RetireException : (refetch ? InstructionMap::RetireRefetch : InstructionMap::Retire);

        verifyOnCommit(retInfo);

        // RET: update regs
        for (int u = 0; u < insInfo.nUops; u++) begin
            UidT uid = '{id, u};
            UopInfo uInfo = insMap.getU(uid);
            registerTracker.commit(decUname(uid), uInfo.vDest, uid, refetch || exception); // Need to modify to handle Exceptional and Hidden
        end

        // RET: update WQ
        if (isStoreUop(decMainUop(id))) putToWq(id, exception, refetch);

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
        retiredTarget <= getCommitTarget(decMainUop(id), retInfo.takenBranch, retiredTarget, retInfo.target, refetch, exception);
    endtask


    task automatic putToWq(input InsId id, input logic exception, input logic refetch);
        Transaction tr = memTracker.findStore(id);
        
        // Extract 'uncached' info
        int found[$] = theSq.content_N.find_index with (item.mid == id);
        logic uncached = theSq.content_N[found[0]].uncached;
        AccessSize size = //decMainUop(id) == UOP_mem_stib ? SIZE_1 : SIZE_4;
                          theSq.content_N[found[0]].size;
        
        StoreQueueEntry sqe = '{1, id, exception || refetch, isStoreSysUop(decMainUop(id)), uncached, tr.adrAny, tr.val, size};       
        csq.push_back(sqe); // Normal
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
        return sysRegs[adr];
    endfunction

    function automatic void setSysReg(input Mword adr, input Mword val);
        assert (adr >= 0 && adr <= 31) else $fatal("Writing incorrect sys reg: adr = %d, val = %d", adr, val);
        sysRegs[adr] = val;
    endfunction

    task automatic writeResult(input UopPacket p);
        if (!p.active) return;
        putMilestone(p.TMP_oid, InstructionMap::WriteResult);
        registerTracker.writeValue(decUname(p.TMP_oid), decId(U2M(p.TMP_oid)).dest, p.TMP_oid, p.result);
    endtask


    // General

    // TODO: review usage of these functions
    //  decId - 3
    //  decUname - 19
    //  decMainUop - 15
    //  getAdr - 3

    function automatic AbstractInstruction decId(input InsId id);
        return (id == -1) ? DEFAULT_ABS_INS : insMap.get(id).basicData.dec;
    endfunction

    function automatic UopName decUname(input UidT uid);
        return (uid == UIDT_NONE) ? UOP_none : insMap.getU(uid).name;
    endfunction

    function automatic UopName decMainUop(input InsId id);
        return (id == -1) ? UOP_none : insMap.get(id).mainUop;
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


    assign insAdr = theFrontend.ipStage[0].adr;

    assign sig = lateEventInfo.cOp == CO_send;
    assign wrong = lateEventInfo.cOp == CO_undef;


endmodule
