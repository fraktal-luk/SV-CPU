
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;


module AbstractCore
#(
    parameter FETCH_WIDTH = 4,
    parameter LOAD_WIDTH = FETCH_WIDTH
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
    
    logic dummy = 'x;

        logic cmpR, cmpC, cmpR_r, cmpC_r;

    localparam int FETCH_QUEUE_SIZE = 8;
    localparam int BC_QUEUE_SIZE = 64;

    localparam int N_REGS_INT = 128;
    localparam int N_REGS_FLOAT = 128;

    localparam int OP_QUEUE_SIZE = 24;
    localparam int OOO_QUEUE_SIZE = 120;

    localparam int ROB_SIZE = 128;
    
    localparam int LQ_SIZE = 80;
    localparam int SQ_SIZE = 80;
    
    
    const logic SYS_STORE_AS_MEM = 1;
    
    typedef struct {
        OpSlot op;
    } RobEntry;
    
    typedef struct {
        OpSlot op;
    } LoadQueueEntry;
    
    typedef struct {
        OpSlot op;
        Word adr;
        Word val;
    } StoreQueueEntry;

    typedef logic logic3[3];

    typedef OpSlot OpSlotA[FETCH_WIDTH];

    typedef struct {
        logic active;
        int ctr;
        Word baseAdr;
        logic mask[FETCH_WIDTH];
        Word words[FETCH_WIDTH];
    } Stage;

    const Stage EMPTY_STAGE = '{'0, -1, 'x, '{default: 0}, '{default: 'x}};

    typedef struct {
        int id;
        logic done;
    }
    OpStatus;

    typedef struct {
        int num;
        OpSlot regular[4];
        OpSlot branch;
        OpSlot mem;
        OpSlot sys;
    } IssueGroup;
    
    const IssueGroup DEFAULT_ISSUE_GROUP = '{num: 0, regular: '{default: EMPTY_SLOT}, branch: EMPTY_SLOT, mem: EMPTY_SLOT, sys: EMPTY_SLOT};

    typedef Word FetchGroup[FETCH_WIDTH];


    InstructionMap insMap = new();

    RegisterTracker #(N_REGS_INT, N_REGS_FLOAT) registerTracker = new();
    
    InsId intWritersR[32] = '{default: -1}, floatWritersR[32] = '{default: -1};
    InsId intWritersC[32] = '{default: -1}, floatWritersC[32] = '{default: -1};

    int cycleCtr = 0, fetchCtr = 0;
    int fqSize = 0, oqSize = 0, oooqSize = 0, bcqSize = 0, nFreeRegsInt = 0, nSpecRegsInt = 0, nStabRegsInt = 0, nFreeRegsFloat = 0, robSize = 0, lqSize = 0, sqSize = 0, csqSize = 0;
    int insMapSize = 0, renamedDivergence = 0, nRenamed = 0, nCompleted = 0, nRetired = 0, oooqCompletedNum = 0, frontCompleted = 0;

    logic fetchAllow, renameAllow;
    logic resetPrev = 0, intPrev = 0, lateEventWaiting = 0;

    BranchCheckpoint branchCP;
    
    Stage ipStage = EMPTY_STAGE, fetchStage0 = EMPTY_STAGE, fetchStage1 = EMPTY_STAGE;
    Stage fetchQueue[$:FETCH_QUEUE_SIZE];

    OpSlotA nextStageA = '{default: EMPTY_SLOT};
    OpSlot opQueue[$:OP_QUEUE_SIZE];
        typedef logic ReadyVec[OP_QUEUE_SIZE];
        ReadyVec opsReady, opsReadyRegular, opsReadyBranch, opsReadyMem, opsReadySys;

    OpSlot T_iqRegular[$:OP_QUEUE_SIZE];
    OpSlot T_iqBranch[$:OP_QUEUE_SIZE];
    OpSlot T_iqMem[$:OP_QUEUE_SIZE];
    OpSlot T_iqSys[$:OP_QUEUE_SIZE];


        typedef struct {
            OpSlot late;
            OpSlot exec;
        } Events;

        function automatic OpSlot tick(input OpSlot op, input Events evts);
            return op;
        endfunction

    Events evts;

    OpSlot memOp = EMPTY_SLOT, memOpPrev = EMPTY_SLOT;
    IssueGroup issuedSt0 = DEFAULT_ISSUE_GROUP, issuedSt1 = DEFAULT_ISSUE_GROUP;

    OpStatus oooQueue[$:OOO_QUEUE_SIZE];

    RobEntry rob[$:ROB_SIZE];
    LoadQueueEntry loadQueue[$:LQ_SIZE];
    StoreQueueEntry storeQueue[$:SQ_SIZE];
    StoreQueueEntry committedStoreQueue[$];
    StoreQueueEntry storeHead_C, storeHead_Q, lastCommittedSqe;

    int bqIndex = 0, lqIndex = 0, sqIndex = 0;

    IndexSet renameInds = '{default: 0}, commitInds = '{default: 0};

    BranchCheckpoint branchCheckpointQueue[$:BC_QUEUE_SIZE];
    
    CpuState execState;
    SimpleMem execMem = new();
    Emulator renamedEmul = new(), execEmul = new(), retiredEmul = new();


    EventInfo branchEventInfo = EMPTY_EVENT_INFO, lateEventInfo, lateEventInfo_Norm = EMPTY_EVENT_INFO, lateEventInfo_Alt = EMPTY_EVENT_INFO, lateEventInfoWaiting = EMPTY_EVENT_INFO;

    MemWriteInfo writeInfo_C;

    InsDependencies lastDepsRe, lastDepsEx;
    InstructionInfo latestOOO[20], committedOOO[20];
    InstructionInfo lastInsInfo;

    OpSlot lastRenamed = EMPTY_SLOT, lastCompleted = EMPTY_SLOT, lastRetired = EMPTY_SLOT;
    string lastRenamedStr, lastCompletedStr, lastRetiredStr,  lastCommittedSqeStr, oooqStr;
    logic cmp0, cmp1;
    Word cmpw0, cmpw1, cmpw2, cmpw3;



    assign lateEventInfo = lateEventInfo_Norm;

    
    task automatic putWrite();
        storeHead_C <= (committedStoreQueue.size != 0) ? committedStoreQueue[0] : '{EMPTY_SLOT, 'x, 'x};
    endtask
    
    always @(posedge clk) cycleCtr++; 

    always @(posedge clk) begin
        resetPrev <= reset;
        intPrev <= interrupt;
        
        sig <= 0;
        wrong <= 0;

        readReq[0] = 0;
        readAdr[0] = 'x;

        //writeInfo = EMPTY_WRITE_INFO;
        branchEventInfo <= EMPTY_EVENT_INFO;

        lateEventInfo_Norm <= EMPTY_EVENT_INFO;
        lateEventInfo_Alt <= EMPTY_EVENT_INFO;

        if (csqSize == 0) begin
            lateEventInfoWaiting <= EMPTY_EVENT_INFO;
            lateEventInfo_Alt <= lateEventInfoWaiting;
        end
        else begin
            
        end


        drainWriteQueue();
        advanceOOOQ();        
        putWrite();


        issuedSt0 <= DEFAULT_ISSUE_GROUP;
        issuedSt1 <= issuedSt0;

        if (resetPrev | intPrev | lateEventInfo.redirect) begin
            performRedirect();
        end
        else if (branchEventInfo.redirect) begin
            performRedirect();
        end
        else begin
            fetchAndEnqueue();

            writeToOpQ(nextStageA);
            writeToOOOQ(nextStageA);
            foreach (nextStageA[i]) begin
                if (nextStageA[i].active) addToQueues(nextStageA[i]);
            end

            memOp <= EMPTY_SLOT;
            memOpPrev <= tick(memOp, evts);

            if (reset) execReset();
            else if (interrupt) execInterrupt();
            else begin
                runExec();
            end

        end
        
        fqSize <= fetchQueue.size();
        oqSize <= opQueue.size();
        oooqSize <= oooQueue.size();
        bcqSize <= branchCheckpointQueue.size();
        robSize <= rob.size();
        lqSize <= loadQueue.size();
        sqSize <= storeQueue.size();
        csqSize <= committedStoreQueue.size();
        
        frontCompleted <= countFrontCompleted();

        nFreeRegsInt <= registerTracker.getNumFreeInt();
            nSpecRegsInt <= registerTracker.getNumSpecInt();
            nStabRegsInt <= registerTracker.getNumStabInt();
        nFreeRegsFloat <= registerTracker.getNumFreeFloat();
     
            opsReady <= getReadyVec(opQueue);
            
            opsReadyRegular <= getReadyVec(T_iqRegular);
            opsReadyBranch <= getReadyVec(T_iqBranch);
            opsReadyMem <= getReadyVec(T_iqMem);
            opsReadySys <= getReadyVec(T_iqSys);
        
        begin
            automatic OpStatus oooqDone[$] = (oooQueue.find with (item.done == 1));
            oooqCompletedNum <= oooqDone.size();
            assert (oooqDone.size() <= 4) else $error("How 5?");
        end
        
            insMapSize = insMap.size();
            $swrite(oooqStr, "%p", oooQueue);
    end

    assign insAdr = ipStage.baseAdr;

    assign fetchAllow = fetchQueueAccepts(fqSize) && bcQueueAccepts(bcqSize);
    assign renameAllow = opQueueAccepts(oqSize) && oooQueueAccepts(oooqSize) && regsAccept(nFreeRegsInt, nFreeRegsFloat)
                    && robAccepts(robSize) && lqAccepts(lqSize) && sqAccepts(sqSize);

    assign writeInfo_C = '{storeHead_C.op.active && isStoreMemOp(storeHead_C.op), storeHead_C.adr, storeHead_C.val};

    assign writeReq = writeInfo_C.req;
    assign writeAdr = writeInfo_C.adr;
    assign writeOut = writeInfo_C.value;

    function logic fetchQueueAccepts(input int k);
        return k <= FETCH_QUEUE_SIZE - 3; // 2 stages between IP stage and FQ
    endfunction
    
    function logic bcQueueAccepts(input int k);
        return k <= BC_QUEUE_SIZE - 3*FETCH_WIDTH - FETCH_QUEUE_SIZE*FETCH_WIDTH; // 2 stages + FETCH_QUEUE entries, FETCH_WIDTH each
    endfunction

    function logic oooQueueAccepts(input int k);
        return k <= OOO_QUEUE_SIZE - 2*FETCH_WIDTH;
    endfunction
    
    function logic opQueueAccepts(input int k);
        return k <= OP_QUEUE_SIZE - 2*FETCH_WIDTH;
    endfunction
    
    function logic regsAccept(input int nI, input int nF);
        return nI > FETCH_WIDTH && nF > FETCH_WIDTH;
    endfunction

    function logic robAccepts(input int k);
        return k <= ROB_SIZE - 2*FETCH_WIDTH;
    endfunction

    function logic lqAccepts(input int k);
        return k <= LQ_SIZE - 2*FETCH_WIDTH;
    endfunction
    
    function logic sqAccepts(input int k);
        return k <= SQ_SIZE - 2*FETCH_WIDTH;
    endfunction

    
    task automatic runExec();
        IssueGroup igIssue = DEFAULT_ISSUE_GROUP, igExec = DEFAULT_ISSUE_GROUP;// = issuedSt0;
    
        if (memOpPrev.active) begin // Finish executing mem operation from prev cycle
            execMemLater(memOpPrev);
        end
        else if (memOp.active || issuedSt0.mem.active || issuedSt1.mem.active
                ) begin
        end
        else begin
            igIssue = issueFromOpQ(opQueue, oqSize);
            igExec = igIssue;
        end
            
        igExec = issuedSt1;
        issuedSt0 <= igIssue;

        foreach (igExec.regular[i]) begin
            if (igExec.regular[i].active) execRegular(igExec.regular[i]);
        end
    
        if (igExec.branch.active)execBranch(igExec.branch);
        else if (igExec.mem.active) execMemFirst(igExec.mem);
        else if (igExec.sys.active) execSysFirst(igExec.sys);
    endtask
    

    function automatic Stage setActive(input Stage s, input logic on, input int ctr);
        Stage res = s;
        res.active = on;
        res.ctr = ctr;
        res.baseAdr = s.baseAdr & ~(4*FETCH_WIDTH-1);
        foreach (res.mask[i]) if ((s.baseAdr/4) % FETCH_WIDTH <= i) res.mask[i] = '1;
        return res;
    endfunction

    function automatic Stage setWords(Stage s, FetchGroup fg);
        Stage res = s;
        res.words = fg;
        return res;
    endfunction


    task automatic completeOp(input OpSlot op);
        if (writesIntReg(op)) begin
            registerTracker.setReadyInt(op.id);
            registerTracker.writeValueInt(op, insMap.get(op.id).result);
        end
        if (writesFloatReg(op)) begin
            registerTracker.setReadyFloat(op.id);
            registerTracker.writeValueFloat(op, insMap.get(op.id).result);
        end

        updateOOOQ(op);
            lastCompleted = op;
            lastDepsEx <= insMap.get(op.id).deps;
            nCompleted++;
    endtask

    task automatic flushAll();
        opQueue.delete();
            T_iqRegular.delete();
            T_iqBranch.delete();
            T_iqMem.delete();
            T_iqSys.delete();
        oooQueue.delete();
        branchCheckpointQueue.delete();
        rob.delete();
        loadQueue.delete();
        storeQueue.delete();
    endtask
    
    task automatic flushPartial(input OpSlot op);
        while (opQueue.size() > 0 && opQueue[$].id > op.id) void'(opQueue.pop_back());
        while (T_iqRegular.size() > 0 && T_iqRegular[$].id > op.id) void'(T_iqRegular.pop_back());
        while (T_iqBranch.size() > 0 && T_iqBranch[$].id > op.id) void'(T_iqBranch.pop_back());
        while (T_iqMem.size() > 0 && T_iqMem[$].id > op.id) void'(T_iqMem.pop_back());
        while (T_iqSys.size() > 0 && T_iqSys[$].id > op.id) void'(T_iqSys.pop_back());
    
        while (oooQueue.size() > 0 && oooQueue[$].id > op.id) void'(oooQueue.pop_back());
        while (branchCheckpointQueue.size() > 0 && branchCheckpointQueue[$].op.id > op.id) void'(branchCheckpointQueue.pop_back());
        while (rob.size() > 0 && rob[$].op.id > op.id) void'(rob.pop_back());
        while (loadQueue.size() > 0 && loadQueue[$].op.id > op.id) void'(loadQueue.pop_back());
        while (storeQueue.size() > 0 && storeQueue[$].op.id > op.id) void'(storeQueue.pop_back());
    endtask


    task automatic restoreMappings(input BranchCheckpoint cp);
        intWritersR = cp.intWriters;
        floatWritersR = cp.floatWriters;
        registerTracker.restore(cp.intMapR, cp.floatMapR);
    endtask


    task automatic performRedirect();
        if (lateEventInfo.redirect || intPrev || resetPrev)
            ipStage <= '{'1, -1, lateEventInfo.target, '{default: '0}, '{default: 'x}};
        else if (branchEventInfo.redirect)
            ipStage <= '{'1, -1, branchEventInfo.target, '{default: '0}, '{default: 'x}};
        else $fatal(2, "Should never get here");

        if (lateEventInfo.redirect || intPrev || resetPrev) begin
            renamedEmul.setLike(retiredEmul);
            execEmul.setLike(retiredEmul);
            
            execState = retiredEmul.coreState;
            execMem.copyFrom(retiredEmul.tmpDataMem);
            
            if (resetPrev) begin
                intWritersR = '{default: -1};
                floatWritersR = '{default: -1};
            end
            else begin 
                intWritersR = intWritersC;
                floatWritersR = floatWritersC;
            end
            registerTracker.restore(registerTracker.intMapC, registerTracker.floatMapC);
            renameInds = commitInds;
            
            renamedDivergence = 0;
        end
        else if (branchEventInfo.redirect) begin
            BranchCheckpoint single = branchCP;

            renamedEmul.coreState = single.state;
            renamedEmul.tmpDataMem.copyFrom(single.mem);
            execEmul.coreState = single.state;
            execEmul.tmpDataMem.copyFrom(single.mem);
            
            execState = single.state;
            execMem.copyFrom(single.mem);
            
            restoreMappings(single);
            renameInds = single.inds;

            renamedDivergence = insMap.get(branchEventInfo.op.id).divergence;
        end

        // Clear stages younger than activated redirection
        fetchStage0 <= EMPTY_STAGE;
        fetchStage1 <= EMPTY_STAGE;
        fetchQueue.delete();
        
        nextStageA <= '{default: EMPTY_SLOT};
        
        if (lateEventInfo.redirect || intPrev || resetPrev) begin
            flushAll();
            registerTracker.flushAll();    
        end
        else if (branchEventInfo.redirect) begin
            flushPartial(branchEventInfo.op);  
            registerTracker.flush(branchEventInfo.op);    
        end

        issuedSt0 <= DEFAULT_ISSUE_GROUP;
        issuedSt1 <= DEFAULT_ISSUE_GROUP;
    
        memOp <= EMPTY_SLOT;
        memOpPrev <= EMPTY_SLOT;


        if (resetPrev) begin
            renamedEmul.reset();
            execEmul.reset();
            retiredEmul.reset();
            
            execState = initialState(IP_RESET);
            execMem.reset();
        end
    endtask

    
    task automatic saveCP(input OpSlot op);
        int intMapR[32] = registerTracker.intMapR;
        int floatMapR[32] = registerTracker.floatMapR;
        BranchCheckpoint cp = new(op, renamedEmul.coreState, renamedEmul.tmpDataMem, intWritersR, floatWritersR, intMapR, floatMapR, renameInds);
        branchCheckpointQueue.push_back(cp);
    endtask
    
    task automatic addToQueues(input OpSlot op);
        AbstractInstruction ins = decodeAbstract(op.bits);
        addToRob(op);
        
        if (isLoadIns(ins)) addToLoadQueue(op);
        if (isStoreIns(ins)) addToStoreQueue(op);
    endtask
    
    task automatic addToRob(input OpSlot op);
        rob.push_back('{op});
    endtask

    task automatic addToLoadQueue(input OpSlot op);
        loadQueue.push_back('{op});
    endtask
    
    task automatic addToStoreQueue(input OpSlot op);
        storeQueue.push_back('{op, 'x, 'x});
    endtask

    task automatic updateSQ(input InsId id, input Word adr, input Word val);
        int ind[$] = storeQueue.find_first_index with (item.op.id == id);
        storeQueue[ind[0]].adr = adr;
        storeQueue[ind[0]].val = val;
    endtask


    task automatic renameOp(input OpSlot op);             
        AbstractInstruction ins = decodeAbstract(op.bits);
        Word result, target;
        InsDependencies deps;
        Word argVals[3];

        if (op.adr != renamedEmul.coreState.target) renamedDivergence++;
        
        argVals = getArgs(renamedEmul.coreState.intRegs, renamedEmul.coreState.floatRegs, ins.sources, parsingMap[ins.fmt].typeSpec);
        result = computeResult(renamedEmul.coreState, op.adr, ins, renamedEmul.tmpDataMem); // Must be before modifying state

        deps = getPhysicalArgs(op, registerTracker.intMapR, registerTracker.floatMapR);

        runInEmulator(renamedEmul, op);
        renamedEmul.drain();
        target = renamedEmul.coreState.target;

        updateInds(renameInds, op);

        mapOpAtRename(op);
        if (isBranchOp(op)) saveCP(op);

        insMap.setDivergence(op.id, renamedDivergence);
        insMap.setResult(op.id, result);
        insMap.setTarget(op.id, target);
        insMap.setDeps(op.id, deps);
        insMap.setInds(op.id, renameInds);
        insMap.setArgValues(op.id, argVals);
        
            lastRenamed = op;
            nRenamed++;
            lastDepsRe <= deps;
            updateLatestOOO();
    endtask


    task automatic commitOp(input OpSlot op);
        AbstractInstruction ins = decodeAbstract(op.bits);
        Word trg = retiredEmul.coreState.target;
        Word bits = fetchInstruction(TMP_getP(), trg);

        assert (trg === op.adr) else $fatal(2, "Commit: mm adr %h / %h", trg, op.adr);
        assert (bits === op.bits) else $fatal(2, "Commit: mm enc %h / %h", bits, op.bits);

        runInEmulator(retiredEmul, op);
        retiredEmul.drain();

        updateInds(commitInds, op);

        mapOpAtCommit(op);
        
        if (isStoreIns(ins)) begin
            StoreQueueEntry sqe = storeQueue[0];
            committedStoreQueue.push_back(sqe);
        end

        // Actual execution of ops which must be done after Commit
        if (isSysOp(op)) begin
            setLateEvent(execState, op);
            performSys(execState, op);
        end
        releaseQueues(op);

            lastRetired = op;
            nRetired++;
            updateCommittedOOO();
    endtask

    task automatic releaseQueues(input OpSlot op);
        AbstractInstruction ins = decodeAbstract(op.bits);

        RobEntry re = rob.pop_front();
        assert (re.op === op) else $error("Not matching op: %p / %p", re.op, op);
        
        if (isBranchOp(op)) begin // Br queue entry release
            BranchCheckpoint bce = branchCheckpointQueue.pop_front();
            assert (bce.op === op) else $error("Not matching op: %p / %p", bce.op, op);
        end
        
        if (isLoadIns(ins)) begin
            LoadQueueEntry lqe = loadQueue.pop_front();
            assert (lqe.op === op) else $error("Not matching op: %p / %p", lqe.op, op);
        end
        
        if (isStoreIns(ins)) begin // Br queue entry release
            StoreQueueEntry sqe = storeQueue.pop_front();
                lastCommittedSqe <= sqe;
            assert (sqe.op === op) else $error("Not matching op: %p / %p", sqe.op, op);
        end
    endtask


    task automatic fetchAndEnqueue();
        OpSlotA ipSlotA, fetchStage0ua;
        Stage ipStageU, fetchStage0u;
        if (fetchAllow) begin
            ipStage <= '{'1, -1, (ipStage.baseAdr & ~(4*FETCH_WIDTH-1)) + 4*FETCH_WIDTH, '{default: '0}, '{default: 'x}};
            fetchCtr <= fetchCtr + FETCH_WIDTH;
        end
        
        ipStageU = setActive(ipStage, ipStage.active & fetchAllow, fetchCtr);
        ipSlotA = makeOpA(ipStageU);

        foreach (ipSlotA[i]) if (ipSlotA[i].active) insMap.add(ipSlotA[i]);
        
        fetchStage0 <= ipStageU;
        
        fetchStage0u = setWords(fetchStage0, insIn);
        fetchStage0ua = makeOpA(fetchStage0u);
        
        foreach (fetchStage0ua[i]) if (fetchStage0ua[i].active) insMap.setEncoding(fetchStage0ua[i]);
        fetchStage1 <= fetchStage0u;

        if (fetchStage1.active) fetchQueue.push_back(fetchStage1);

        if (fqSize > 0 && renameAllow) begin
            Stage toRename = fetchQueue.pop_front();
            OpSlotA toRenameA = makeOpA(toRename);
            
            foreach (toRenameA[i])
                if (toRenameA[i].active)
                    renameOp(toRenameA[i]);

            nextStageA <= toRenameA;
        end
        else begin
            nextStageA <= '{default: EMPTY_SLOT};
        end
        
    endtask

    function automatic ReadyVec getReadyVec(input OpSlot iq[$:OP_QUEUE_SIZE]);
        ReadyVec res = '{default: 'z};
        foreach (iq[i]) begin
            InsDependencies deps = insMap.get(iq[i].id).deps;
            logic3 ra = checkArgsReady(deps, registerTracker.intReady, registerTracker.floatReady);
            res[i] = ra.and();
        end
        return res;
    endfunction

    function automatic Word3 getPhysicalArgValues(input RegisterTracker tracker, input OpSlot op);
        InsDependencies deps = insMap.get(op.id).deps;
        return getArgValues(tracker, deps);            
    endfunction


    task automatic mapOpAtRename(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        if (writesIntReg(op)) intWritersR[abs.dest] = op.id;
        if (writesFloatReg(op)) floatWritersR[abs.dest] = op.id;
        intWritersR[0] = -1;
        
        registerTracker.reserveInt(op);
        registerTracker.reserveFloat(op);
    endtask

    task automatic mapOpAtCommit(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        if (writesIntReg(op)) intWritersC[abs.dest] = op.id;
        if (writesFloatReg(op)) floatWritersC[abs.dest] = op.id;
        intWritersC[0] = -1;
        
        registerTracker.commitInt(op);
        registerTracker.commitFloat(op);
    endtask

    task automatic execReset();    
        lateEventInfo_Norm <= '{EMPTY_SLOT, 1, IP_RESET};
            lateEventInfoWaiting <= '{EMPTY_SLOT, 1, IP_RESET};
        performAsyncEvent(retiredEmul.coreState, IP_RESET);
    endtask

    task automatic execInterrupt();
        $display(">> Interrupt !!!");
        lateEventInfo_Norm <= '{EMPTY_SLOT, 1, IP_INT};
            lateEventInfoWaiting <= '{EMPTY_SLOT, 1, IP_INT};
        retiredEmul.interrupt();        
    endtask

    task automatic performLink(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        Word result = op.adr + 4;
        writeIntReg(state, abs.dest, result);
    endtask

    task automatic setBranch(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        ExecEvent evt = resolveBranch(state, abs, op.adr);
        
        state.target = evt.redirect ? evt.target : op.adr + 4;
    endtask

    // TODO: accept Event as arg?
    task automatic setExecEvent(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        ExecEvent evt = resolveBranch(state, abs, op.adr);
        
        BranchCheckpoint found[$] = branchCheckpointQueue.find with (item.op.id == op.id);

        branchCP = found[0];
        branchEventInfo <= '{op, evt.redirect, evt.target};
    endtask

    task automatic performBranch(ref CpuState state, input OpSlot op);
        setBranch(state, op);
        performLink(state, op);
    endtask


    task automatic performRegularOp(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        Word3 args = getArgs(state.intRegs, state.floatRegs, abs.sources, parsingMap[abs.fmt].typeSpec);
        Word3 argsP = getPhysicalArgValues(registerTracker, op);
        Word3 argsM = insMap.get(op.id).argValues;
        
        Word result = (abs.def.o == O_sysLoad) ? state.sysRegs[args[1]] : calculateResult(abs, args, op.adr);

            assert (argsP == args) else $error("not equal args %p / %p : %s", args, argsP, parsingMap[abs.fmt].typeSpec);
            assert (argsP == args) else $error("not equal args %p / %p : %s", args, argsM, parsingMap[abs.fmt].typeSpec);

        if (writesIntReg(op)) writeIntReg(state, abs.dest, result);
        if (writesFloatReg(op)) writeFloatReg(state, abs.dest, result);
        state.target = op.adr + 4;
    endtask    

    
    task automatic performMemFirst(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        Word3 args = getArgs(state.intRegs, state.floatRegs, abs.sources, parsingMap[abs.fmt].typeSpec);
        Word3 argsP = getPhysicalArgValues(registerTracker, op);
        Word3 argsM = insMap.get(op.id).argValues;

        Word adr = calculateEffectiveAddress(abs, args);

            assert (argsP == args) else $error("not equal args %p / %p : %s", args, argsP, parsingMap[abs.fmt].typeSpec);
            assert (argsP == args) else $error("not equal args %p / %p : %s", args, argsM, parsingMap[abs.fmt].typeSpec);

        // TODO: make struct, unpack at assigment to ports
        readReq[0] <= '1;
        readAdr[0] <= adr;
        memOp <= op;
        
        if (isStoreMemOp(op)) begin
            updateSQ(op.id, adr, args[2]);
            //writeInfo <= '{1, adr, args[2]};
        end
    endtask

    task automatic performMemLater(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        Word3 args = getArgs(state.intRegs, state.floatRegs, abs.sources, parsingMap[abs.fmt].typeSpec);
        Word3 argsP = getPhysicalArgValues(registerTracker, op);
        Word3 argsM = insMap.get(op.id).argValues;

        Word adr = calculateEffectiveAddress(abs, args);
        Word data;
        
        // TODO: develop adr overlap check?
        StoreQueueEntry oooMatchingStores[$] = storeQueue.find with (item.adr == adr && isStoreMemOp(item.op) && item.op.id < op.id);
        StoreQueueEntry committedMatchingStores[$] = committedStoreQueue.find with (item.adr == adr && isStoreMemOp(item.op) && item.op.id < op.id);
        StoreQueueEntry matchingStores[$] = {committedMatchingStores, oooMatchingStores};
        // Get last (youngest) of the matching stores
        Word memData = (matchingStores.size() != 0) ? matchingStores[$].val : readIn[0];
        if (matchingStores.size() != 0) begin
            $display("SQ forwarding %d->%d", matchingStores[$].op.id, op.id);
        end
        data = isLoadSysIns(abs) ? state.sysRegs[args[1]] : memData;
        
            assert (argsP == args) else $error("not equal args %p / %p : %s", args, argsP, parsingMap[abs.fmt].typeSpec);
            assert (argsP == args) else $error("not equal args %p / %p : %s", args, argsM, parsingMap[abs.fmt].typeSpec);

        if (writesIntReg(op)) writeIntReg(state, abs.dest, data);
        if (writesFloatReg(op)) writeFloatReg(state, abs.dest, data);
        state.target = op.adr + 4;
    endtask


    task automatic performSysStore(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        Word3 args = getArgs(state.intRegs, state.floatRegs, abs.sources, parsingMap[abs.fmt].typeSpec);
        Word3 argsP = getPhysicalArgValues(registerTracker, op);
        Word3 argsM = insMap.get(op.id).argValues;

            assert (argsP == args) else $error("not equal args %p / %p : %s", args, argsP, parsingMap[abs.fmt].typeSpec);
            assert (argsP == args) else $error("not equal args %p / %p : %s", args, argsM, parsingMap[abs.fmt].typeSpec);

        writeSysReg(state, args[1], args[2]);
        state.target = op.adr + 4;
    endtask

    task automatic performSys(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);

        case (abs.def.o)
            O_sysStore: performSysStore(state, op);
            O_halt: $error("halt not implemented");
            default: ;                            
        endcase

        modifySysRegs(state, op.adr, abs);
    endtask


    task automatic execBranch(input OpSlot op);
        setExecEvent(execState, op);
        performBranch(execState, op);
        completeOp(op);
    endtask


    task automatic execMemFirst(input OpSlot op);
        performMemFirst(execState, op);
    endtask

    task automatic execMemLater(input OpSlot op);
        performMemLater(execState, op);
        completeOp(op);
    endtask


    task automatic execSysFirst(input OpSlot op);
        completeOp(op);
    endtask

    task automatic execRegular(input OpSlot op);
        performRegularOp(execState, op);
        completeOp(op);
    endtask

    function automatic OpSlot makeOp(input Stage st, input int i);
        if (!st.active || !st.mask[i]) return EMPTY_SLOT;
        return '{1, st.ctr + i, st.baseAdr + 4*i, st.words[i]};
    endfunction

    function automatic OpSlotA makeOpA(input Stage st);
        OpSlotA res = '{default: EMPTY_SLOT};
        if (!st.active) return res;

        foreach (st.words[i]) if (st.mask[i]) res[i] = makeOp(st, i);
        return res;
    endfunction

    task automatic writeToOpQ(input OpSlotA sa);
        foreach (sa[i]) if (sa[i].active) opQueue.push_back(sa[i]);
        
        // Mirror into separate queues 
        foreach (sa[i]) if (sa[i].active) begin
            if (isMemOp(sa[i]) || isLoadSysIns(decodeAbstract(sa[i].bits)) || isStoreSysIns(decodeAbstract(sa[i].bits))) T_iqMem.push_back(sa[i]);
            //else if (isLoadOp(sa[i]) || isStoreOp(sa[i])) begin
            else if (isSysOp(sa[i])) T_iqSys.push_back(sa[i]);
            else if (isBranchOp(sa[i])) T_iqBranch.push_back(sa[i]);
            else T_iqRegular.push_back(sa[i]);
        end
    endtask

    task automatic writeToOOOQ(input OpSlotA sa);
        foreach (sa[i]) if (sa[i].active) oooQueue.push_back('{sa[i].id, 0});
    endtask

    task automatic updateOOOQ(input OpSlot op);
        const int ind[$] = oooQueue.find_index with (item.id == op.id);
        assert (ind.size() > 0) oooQueue[ind[0]].done = '1; else $error("No such id in OOOQ: %d", op.id); 
    endtask

    task automatic drainWriteQueue();
        if (csqSize != 0) void'(committedStoreQueue.pop_front());

        storeHead_Q <= storeHead_C;
    endtask

    task automatic advanceOOOQ();
        // Don't commit anything more if event is being handled
        if (lateEventInfo.redirect || intPrev || resetPrev ||  interrupt || reset // || lateEventInfoWaiting.redirect // TODO: turn this on when waiting implemented
                    ) return;

        while (oooQueue.size() > 0 && oooQueue[0].done == 1) begin
            OpStatus opSt = oooQueue.pop_front(); // OOO buffer entry release
            InstructionInfo insInfo = insMap.get(opSt.id);
            OpSlot op = '{1, insInfo.id, insInfo.adr, insInfo.bits};
            assert (op.id == opSt.id) else $error("wrong retirement: %p / %p", opSt, op);

            lastInsInfo <= insInfo;
            commitOp(op);

            if (isSysOp(op)) break;
        end
    endtask


    function automatic IssueGroup issueFromOpQ(ref OpSlot queue[$:OP_QUEUE_SIZE], input int size);
        OpSlot q[$:OP_QUEUE_SIZE] = queue;
        int remainingSize = size;
    
        IssueGroup res = DEFAULT_ISSUE_GROUP;
        for (int i = 0; i < 4; i++) begin
            if (remainingSize > 0) begin
                OpSlot op = queue.pop_front();
                assert (op.active) else $fatal(2, "Op from queue is empty!");
                remainingSize--;
                res.num++;
                
                if (isBranchOp(op)) begin
                    res.branch = op;
                    assert (op === T_iqBranch.pop_front()) else $error("wrong");
                    break;
                end
                else if (isMemOp(op) || isLoadSysIns(decodeAbstract(op.bits)) || isStoreSysIns(decodeAbstract(op.bits))) begin
                //else if (isLoadOp(op) || isStoreOp(op)) begin
                    res.mem = op;
                    assert (op === T_iqMem.pop_front()) else $error("wrong");
                    break;
                end
                else if (isSysOp(op)) begin
                    res.sys = op;
                    assert (op === T_iqSys.pop_front()) else $error("wrong");
                    break;
                end
                
                assert (op === T_iqRegular.pop_front()) else $error("wrong");
                res.regular[i] = op;
            end
        end
        
        return res;
    endfunction

    task automatic setLateEvent(ref CpuState state, input OpSlot op);    
        AbstractInstruction abs = decodeAbstract(op.bits);
        LateEvent evt = getLateEvent(op, abs, state.sysRegs[2], state.sysRegs[3]);

        lateEventInfo_Norm <= '{op, evt.redirect, evt.target};
            lateEventInfoWaiting <= '{op, evt.redirect, evt.target};

        sig <= evt.sig;
        wrong <= evt.wrong;
    endtask

    function automatic logic3 checkArgsReady(input InsDependencies deps, input logic readyInt[N_REGS_INT], input logic readyFloat[N_REGS_FLOAT]);
        logic3 res;
        foreach (deps.types[i])
            case (deps.types[i])
                SRC_ZERO:  res[i] = 1;
                SRC_CONST: res[i] = 1;
                SRC_INT:   res[i] = readyInt[deps.sources[i]];
                SRC_FLOAT: res[i] = readyFloat[deps.sources[i]];
            endcase      
        return res;
    endfunction

    function automatic void updateInds(ref IndexSet inds, input OpSlot op);
        AbstractInstruction ins = decodeAbstract(op.bits);        
        inds.rename = (inds.rename + 1) % ROB_SIZE;
        if (isBranchIns(ins)) inds.bq = (inds.bq + 1) % BC_QUEUE_SIZE;
        if (isLoadIns(ins)) inds.lq = (inds.lq + 1) % LQ_SIZE;
        if (isStoreIns(ins)) inds.sq = (inds.sq + 1) % SQ_SIZE;
    endfunction


    // How many in front are ready to commit
    function automatic int countFrontCompleted();
        int found[$] = oooQueue.find_first_index with (!item.done);
        return (found.size() == 0) ? oooQueue.size() : found[0];
    endfunction

        task automatic updateLatestOOO();
            InstructionInfo last = insMap.get(lastRenamed.id);
            latestOOO = {latestOOO[1:19], last};
        endtask

        task automatic updateCommittedOOO();
            InstructionInfo last = insMap.get(lastRetired.id);
            committedOOO = {committedOOO[1:19], last};
        endtask

    assign lastRenamedStr = disasm(lastRenamed.bits);
    assign lastCompletedStr = disasm(lastCompleted.bits);
    assign lastRetiredStr = disasm(lastRetired.bits);
    assign lastCommittedSqeStr = disasm(lastCommittedSqe.op.bits);
     
        string bqStr;
        always @(posedge clk) begin
            automatic int ids[$];
            foreach (branchCheckpointQueue[i]) ids.push_back(branchCheckpointQueue[i].op.id);
            $swrite(bqStr, "%p", ids);
        end

endmodule
 