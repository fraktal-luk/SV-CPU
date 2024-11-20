
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import UopList::*;
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

    // Exec   FUTURE: encapsulate in backend?
    logic intRegsReadyV[N_REGS_INT] = '{default: 'x};
    logic floatRegsReadyV[N_REGS_FLOAT] = '{default: 'x};

    EventInfo branchEventInfo = EMPTY_EVENT_INFO;
    EventInfo lateEventInfo = EMPTY_EVENT_INFO;
    EventInfo lateEventInfoWaiting = EMPTY_EVENT_INFO;
    //    Events evts;

    BranchCheckpoint branchCP;


    // Store interface
        // Committed
        StoreQueueEntry csq[$] = '{EMPTY_SQE, EMPTY_SQE};

        StoreQueueEntry storeHead = EMPTY_SQE, drainHead = EMPTY_SQE;
        MemWriteInfo writeInfo = EMPTY_WRITE_INFO;
    
    // Event control
        Mword sysRegs[32];
        Mword retiredTarget = 0;


    OpSlotAB robOut;

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
    OpSlotAB stageRename1 = '{default: EMPTY_SLOT_B};
    OpSlotAB sqOut, lqOut, bqOut;

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

            insMap.commitCheck();

        insMap.insBase.setDbStr();
        insMap.dbStr = insMap.insBase.dbStr;
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

    function automatic MemWriteInfo makeWriteInfo(input StoreQueueEntry sqe);
        logic isSys = sqe.sys;
        MemWriteInfo res = '{sqe.active && !isSys && !sqe.cancel, sqe.adr, sqe.val};
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


    // Frontend, rename and everything before getting to OOO queues
    task automatic runInOrderPartRe();
        OpSlotAB ops = TMP_front2rename(theFrontend.stageRename0);

        if (anyActiveB(ops))
            renameInds.renameG = (renameInds.renameG + 1) % (2*theRob.DEPTH);

        foreach (ops[i]) begin            
            if (ops[i].active !== 1) continue;
            
            ops[i].mid = insMap.insBase.lastM + 1;
            renameOp(ops[i].mid, i, ops[i].adr, ops[i].bits);   
        end

        stageRename1 <= ops;
    endtask

    task automatic redirectRest();
        stageRename1 <= '{default: EMPTY_SLOT_B};
        markKilledRenameStage(stageRename1);

        if (lateEventInfo.redirect) begin
            renamedEmul.setLike(retiredEmul);
            
            flushBranchCheckpointQueueAll();
            flushBranchTargetQueueAll();
            
            if (lateEventInfo.cOp == CO_reset) registerTracker.restoreReset();
            else registerTracker.restoreStable();
            registerTracker.flushAll();
            
            memTracker.flushAll();
            
            renameInds = commitInds;
        end
        else if (branchEventInfo.redirect) begin
            BranchCheckpoint foundCP[$] = AbstractCore.branchCheckpointQueue.find with (item.id == branchEventInfo.eventMid);
            BranchCheckpoint causingCP = foundCP[0];

            renamedEmul.coreState = causingCP.state;
            renamedEmul.tmpDataMem.copyFrom(causingCP.mem);

            flushBranchCheckpointQueuePartial(branchEventInfo.eventMid);
            flushBranchTargetQueuePartial(branchEventInfo.eventMid);

            registerTracker.restoreCP(causingCP.intMapR, causingCP.floatMapR, causingCP.intWriters, causingCP.floatWriters);
            registerTracker.flush(branchEventInfo.eventMid);
            
            memTracker.flush(branchEventInfo.eventMid);
            
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

    task automatic markKilledRenameStage(ref OpSlotAB stage);
        foreach (stage[i]) begin
            if (!stage[i].active) continue;
            putMilestoneM(stage[i].mid, InstructionMap::FlushOOO);
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


    task automatic renameOp(input InsId id, input int currentSlot, input Mword adr, input Word bits);
        AbstractInstruction ins = decodeAbstract(bits);
        InstructionInfo ii;
        UopInfo mainUinfo;
        UopInfo uInfos[$];
        Mword result, target;
        InsDependencies deps;
        Mword argVals[3];
        UopName uopName = OP_DECODING_TABLE[ins.mnemonic];

        // For insMap and mem queues
        argVals = getArgs(renamedEmul.coreState.intRegs, renamedEmul.coreState.floatRegs, ins.sources, parsingMap[ins.fmt].typeSpec);
        result = computeResult(renamedEmul.coreState, adr, ins, renamedEmul.tmpDataMem); // Must be before modifying state. For ins map
        runInEmulator(renamedEmul, adr, bits);
        renamedEmul.drain();
        target = renamedEmul.coreState.target; // For insMap

        // General, per ins
        deps = registerTracker.getArgDeps(ins); // For insMap


        ii = initInsInfo(id, adr, bits);
        ii.mainUop = uopName;
        ii.inds = renameInds;
        ii.slot = currentSlot;
        ii.basicData.target = target;

        ii.firstUop = insMap.insBase.lastU + 1;
        ii.nUops = -1;


        mainUinfo.id = '{id, -1};
        mainUinfo.name = uopName;
        mainUinfo.vDest = ins.dest;
        mainUinfo.physDest = -1;
        mainUinfo.deps = deps;
        mainUinfo.argsE = argVals;
        mainUinfo.resultE = result;
        mainUinfo.argError = 'x;

              //  if (id >= 1839) $display("__ %p", mainUinfo);
                

        uInfos = splitUop(mainUinfo);
            ii.nUops = uInfos.size();
            
            //if (uInfos.size() > 1) $error(" Mid %d", id);
            
        for (int u = 0; u < ii.nUops; u++) begin
            UopInfo uInfo = uInfos[u];
            int thisPhysDest = registerTracker.reserve(uInfo.name, uInfo.vDest, '{id, u});

                if (uopHasIntDest(uInfo.name) && uInfo.vDest == -1) $error(" reserve -1!  %d, %s", id, disasm(ii.basicData.bits));

            uInfos[u].physDest = thisPhysDest;
        end


        insMap.TMP_func(id, ii, uInfos);           


        if (isStoreIns(ins) || isLoadIns(ins)) memTracker.add(id, ins, argVals); // DB

        if (isBranchIns(ins)) begin
            addToBtq(id);
            saveCP(id); // Crucial state
        end


        updateInds(renameInds, id); // Crucial state

            coreDB.lastRenamed = TMP_properOp(id);


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
        // Don't commit anything more if event is being handled

        foreach (robOut[i]) begin
            InsId theId = robOut[i].mid;
            logic refetch, exception;
           
            if (robOut[i].active !== 1 || theId == -1) continue;
            if (cancelRest) $fatal(2, "Committing after break");
            
            refetch = insMap.get(theId).refetch;
            exception = insMap.get(theId).exception;

            commitOp(theId);
                
                insMap.dealloc();
                insMap.committedM++;
            
            if (breaksCommitId(theId)) begin
                lateEventInfoWaiting <= eventFromOp(theId, decMainUop(theId), getAdr(theId), refetch, exception);
                cancelRest = 1;
            end
        end
        
    endtask


    
    
    function automatic void checkUops(input InsId id);
        InstructionInfo info = insMap.get(id);
        
        for (int u = 0; u < info.nUops; u++) begin
            UopInfo uinfo = insMap.getU('{id, u});
            UopName uname = uinfo.name;
    
            if (uopHasIntDest(uname) || uopHasFloatDest(uname)) // DB
                assert (uinfo.resultA === uinfo.resultE) else
                    $error(" not matching result. %p, %s; %d but should be %d", TMP_properOp(id), disasm(info.basicData.bits), uinfo.resultA, uinfo.resultE);
            assert (uinfo.argError === 0) else $fatal(2, "Arg error on op %p\n%p", id, uinfo);
        end
    endfunction



    task automatic verifyOnCommit(input InsId id);
        InstructionInfo info = insMap.get(id);

        Mword trg = retiredEmul.coreState.target; // DB
        Mword nextTrg;
        Word bits = fetchInstruction(dbProgMem, trg); // DB

        assert (trg === info.basicData.adr) else $fatal(2, "Commit: mm adr %h / %h", trg, info.basicData.adr);
        assert (bits === info.basicData.bits) else $fatal(2, "Commit: mm enc %h / %h", bits, info.basicData.bits); // TODO: check at Frontend?
        
        if (info.refetch) return;
        
        // Only Normal commit
        if (!info.exception) checkUops(id);

        // Normal or Exceptional
        runInEmulator(retiredEmul, info.basicData.adr, info.basicData.bits);
        retiredEmul.drain();
    
        nextTrg = retiredEmul.coreState.target; // DB
    
        // Normal (branches don't cause exceptions so far, check for exc can be omitted)
        if (!info.exception && isBranchUop(decMainUop(id))) begin // DB
            assert (branchTargetQueue[0].target === nextTrg) else $error("Mismatch in BQ id = %d, target: %h / %h", id, branchTargetQueue[0].target, nextTrg);
        end
    endtask


        function automatic OpSlotB TMP_properOp(input InsId id);
            InstructionInfo insInfo = insMap.get(id);
            OpSlotB op = '{1, insInfo.id, insInfo.basicData.adr, insInfo.basicData.bits};
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
    task automatic commitOp(input InsId id);
        InstructionInfo insInfo = insMap.get(id);

        logic refetch = insInfo.refetch;
        logic exception = insInfo.exception;
        InstructionMap::Milestone retireType = exception ? InstructionMap::RetireException : (refetch ? InstructionMap::RetireRefetch : InstructionMap::Retire);

            coreDB.lastII = insInfo;
            if (insInfo.nUops > 0) coreDB.lastUI = insMap.getU('{id, insInfo.nUops-1});

        verifyOnCommit(id);

        checkUnimplementedInstruction(decodeId(id)); // All types of commit?


        for (int u = 0; u < insInfo.nUops; u++) begin
            UidT uid = '{id, u};
            UopInfo uInfo = insMap.getU(uid);
            registerTracker.commit(decUname(uid), uInfo.vDest, uid, refetch || exception); // Need to modify to handle Exceptional and Hidden
        end

        if (isStoreUop(decMainUop(id))) putToWq(id, exception, refetch);

        if (isStoreUop(decMainUop(id)) || isLoadUop(decMainUop(id))) memTracker.remove(id); // All?

        releaseQueues(id); // All
  
        if (refetch) begin
            coreDB.lastRefetched = TMP_properOp(id);
        end
        else begin
            coreDB.lastRetired = TMP_properOp(id); // Normal, not Hidden, what about Exc?
            coreDB.nRetired++;
        end

        // Need to modify to serve all types of commit            
        putMilestoneM(id, retireType);
        insMap.setRetired(id);

        // Elements related to crucial signals:
        updateInds(commitInds, id); // All types?
        commitInds.renameG = insMap.get(id).inds.renameG; // Part of above

        retiredTarget <= getCommitTarget(decMainUop(id), retiredTarget, branchTargetQueue[0].target, refetch, exception);
    endtask


    task automatic putToWq(input InsId id, input logic exception, input logic refetch);
        Transaction tr = memTracker.findStore(id);
        StoreQueueEntry sqe = '{1, id, exception || refetch, isStoreSysUop(decMainUop(id)), tr.adrAny, tr.val};       
        csq.push_back(sqe); // Normal
        putMilestoneM(id, InstructionMap::WqEnter); // Normal 
    endtask


    function automatic void updateInds(ref IndexSet inds, input InsId id);
        inds.rename = (inds.rename + 1) % (2*ROB_SIZE);
        if (isBranchUop(decMainUop(id))) inds.bq = (inds.bq + 1) % (2*BC_QUEUE_SIZE);
        if (isLoadUop(decMainUop(id))) inds.lq = (inds.lq + 1) % (2*LQ_SIZE);
        if (isStoreUop(decMainUop(id))) inds.sq = (inds.sq + 1) % (2*SQ_SIZE);
    endfunction

    task automatic releaseQueues(input InsId id);
        if (isBranchUop(decMainUop(id))) begin // Br queue entry release
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

    task automatic writeResult(input UopPacket p);
        if (!p.active) return;
        putMilestone(p.TMP_oid, InstructionMap::WriteResult);
        registerTracker.writeValue(decUname(p.TMP_oid), decId(U2M(p.TMP_oid)).dest, p.TMP_oid, p.result);
    endtask


    // General

    function automatic AbstractInstruction decId(input InsId id);
        if (id == -1) return DEFAULT_ABS_INS;     
        return insMap.get(id).basicData.dec;
    endfunction

    function automatic UopName decUname(input UidT uid);
        if (uid == UIDT_NONE) return UOP_none;     
        return insMap.getU(uid).name;
    endfunction

    function automatic UopName decMainUop(input InsId id);
        if (id == -1) return UOP_none;     
        return insMap.get(id).mainUop;
    endfunction

        // TEMP: to use where it's not just to determine uop name 
        function automatic AbstractInstruction decodeId(input InsId id);
            if (id == -1) return DEFAULT_ABS_INS;     
            return insMap.get(id).basicData.dec;
        endfunction

    function automatic Mword getAdr(input InsId id);
        if (id == -1) return 'x;     
        return insMap.get(id).basicData.adr;
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
//                string str = disasm(
//                            insMap.get(U2M(op.TMP_oid)).basicData.bits);
//                $error("%m  this flushed %p; %s\nbecause %p", decUname(op.TMP_oid), str, theExecBlock.memImagesTr[0][0].TMP_oid);
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
            if (checkMemDep(poison, memStage0[p]) && !(memStage0[p].status inside {ES_OK, ES_REDO, ES_INVALID})) begin
                return 1;
            end
        return 0;
    endfunction

 
    assign insAdr = theFrontend.ipStage[0].adr;

    assign sig = lateEventInfo.cOp == CO_send;
    assign wrong = lateEventInfo.cOp == CO_undef;

endmodule
