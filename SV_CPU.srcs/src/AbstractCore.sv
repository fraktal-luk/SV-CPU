
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
    
    logic dummy = '0;

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
    
    
    //const logic SYS_STORE_AS_MEM = 1;
    
    const logic USE_DELAYED_EVENTS = 0;
    
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

    logic sigValue, wrongValue;
    
    typedef struct {
        int oq;
        int oooq;
        //int bq;
        int rob;
        int lq;
        int sq;
        int csq;
    } BufferLevels;
    
    BufferLevels oooLevels, oooAccepts; 
    

    RegisterTracker #(N_REGS_INT, N_REGS_FLOAT) registerTracker = new();
    MemTracker memTracker = new();
    
    InsId intWritersR[32] = '{default: -1}, floatWritersR[32] = '{default: -1};
    InsId intWritersC[32] = '{default: -1}, floatWritersC[32] = '{default: -1};

    int cycleCtr = 0, fetchCtr = 0;
    int fqSize = 0, nFreeRegsInt = 0, nSpecRegsInt = 0, nStabRegsInt = 0, nFreeRegsFloat = 0 , bcqSize = 0;
    int insMapSize = 0, trSize = 0, renamedDivergence = 0, nRenamed = 0, nCompleted = 0, nRetired = 0, oooqCompletedNum = 0, frontCompleted = 0;

    logic fetchAllow, renameAllow, renameAllow_N, buffersAccepting;
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

    AbstractInstruction eventIns;

    OpSlot lastRenamed = EMPTY_SLOT, lastCompleted = EMPTY_SLOT, lastRetired = EMPTY_SLOT;
    string lastRenamedStr, lastCompletedStr, lastRetiredStr,  lastCommittedSqeStr, oooqStr;
    logic cmp0, cmp1;
    Word cmpw0, cmpw1, cmpw2, cmpw3;
        string iqRegularStr;
        string iqRegularStrA[OP_QUEUE_SIZE];

    assign lateEventInfo = USE_DELAYED_EVENTS ? lateEventInfo_Alt : lateEventInfo_Norm;
    
        assign eventIns = decAbs(lateEventInfo.op.bits);
        assign sigValue = lateEventInfo.op.active && (eventIns.def.o == O_send);
        assign wrongValue = lateEventInfo.op.active && (eventIns.def.o == O_undef);
    
    task automatic putWrite();
        storeHead_C <= (committedStoreQueue.size != 0) ? committedStoreQueue[0] : '{EMPTY_SLOT, 'x, 'x};
    endtask
    

    task automatic activateEvent();
        if (oooLevels.csq == 0) begin
            lateEventInfoWaiting <= EMPTY_EVENT_INFO;
            lateEventInfo_Alt <= lateEventInfoWaiting;
            
            if (USE_DELAYED_EVENTS && lateEventInfoWaiting.op.active) begin
                modifySysRegs(execState, lateEventInfoWaiting.op.adr, decAbs(lateEventInfoWaiting.op.bits));
            end
        end
    endtask


    always @(posedge clk) cycleCtr++;

    always @(posedge clk) begin
        resetPrev <= reset;
        intPrev <= interrupt;
        
        //sig <= 0;
        //wrong <= 0;

        readReq[0] = 0;
        readAdr[0] = 'x;

        branchEventInfo <= EMPTY_EVENT_INFO;

        lateEventInfo_Norm <= EMPTY_EVENT_INFO;
        lateEventInfo_Alt <= EMPTY_EVENT_INFO;

//        if (oooLevels.csq == 0) begin
//            lateEventInfoWaiting <= EMPTY_EVENT_INFO;
//            lateEventInfo_Alt <= lateEventInfoWaiting;
//        end
        activateEvent();

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
            else runExec();
        end
        
        fqSize <= fetchQueue.size();
        bcqSize <= branchCheckpointQueue.size();
        oooLevels <= getBufferLevels();
        
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
        end
        
            insMapSize = insMap.size();
            trSize = memTracker.transactions.size();
        begin
            $swrite(oooqStr, "%p", oooQueue);
            $swrite(iqRegularStr, "%p", T_iqRegular);
            iqRegularStrA = '{default: ""};
            foreach (T_iqRegular[i])
                iqRegularStrA[i] = disasm(T_iqRegular[i].bits);
        end
    end

    assign oooAccepts = getBufferAccepts(oooLevels);
    assign buffersAccepting = buffersAccept(oooAccepts);

    assign insAdr = ipStage.baseAdr;

    assign fetchAllow = fetchQueueAccepts(fqSize) && bcQueueAccepts(bcqSize);
    assign renameAllow = buffersAccepting && regsAccept(nFreeRegsInt, nFreeRegsFloat);

    //assign cmp1 = cmp0;

    assign writeInfo_C = '{storeHead_C.op.active && isStoreMemOp(storeHead_C.op), storeHead_C.adr, storeHead_C.val};
                           
//                          if (storeHead_C.op.active && isStoreMemOp(storeHead_C.op))
//                                    writeSysReg(state, storeHead_C.adr, storeHead_C.adr.val);

    assign writeReq = writeInfo_C.req;
    assign writeAdr = writeInfo_C.adr;
    assign writeOut = writeInfo_C.value;

    assign sig = sigValue;
    assign wrong = wrongValue;

    function logic fetchQueueAccepts(input int k);
        return k <= FETCH_QUEUE_SIZE - 3; // 2 stages between IP stage and FQ
    endfunction
    
    function logic bcQueueAccepts(input int k);
        return k <= BC_QUEUE_SIZE - 3*FETCH_WIDTH - FETCH_QUEUE_SIZE*FETCH_WIDTH; // 2 stages + FETCH_QUEUE entries, FETCH_WIDTH each
    endfunction

    

    // $$Front
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
    
    task automatic flushFrontend();
        fetchStage0 <= EMPTY_STAGE;
        fetchStage1 <= EMPTY_STAGE;
        fetchQueue.delete();
    endtask



    function automatic BufferLevels getBufferLevels();
        BufferLevels res;
        res.oq = opQueue.size();
        res.oooq = oooQueue.size();
        //res.bq = branchCheckpointQueue.size();
        res.rob = rob.size();
        res.lq = loadQueue.size();
        res.sq = storeQueue.size();
        res.csq = committedStoreQueue.size();
        return res;
    endfunction

    function automatic BufferLevels getBufferAccepts(input BufferLevels levels);
        BufferLevels res;
        res.oq = levels.oq <= OP_QUEUE_SIZE - 2*FETCH_WIDTH;
        res.oooq = levels.oooq <= OOO_QUEUE_SIZE - 2*FETCH_WIDTH;
        //res.bq = levels.bq <= BC_QUEUE_SIZE - 3*FETCH_WIDTH - FETCH_QUEUE_SIZE*FETCH_WIDTH; // 2 stages + FETCH_QUEUE entries, FETCH_WIDTH each
        res.rob = levels.rob <= ROB_SIZE - 2*FETCH_WIDTH;
        res.lq = levels.lq <= LQ_SIZE - 2*FETCH_WIDTH;
        res.sq = levels.sq <= SQ_SIZE - 2*FETCH_WIDTH;
        res.csq = 1;//committedStoreQueue.size();
        return res;
    endfunction

    function automatic logic buffersAccept(input BufferLevels acc);
        return acc.oq && acc.oooq //&& acc.bq 
                                  && acc.rob && acc.lq && acc.sq && acc.csq;
    endfunction
  
    function logic regsAccept(input int nI, input int nF);
        return nI > FETCH_WIDTH && nF > FETCH_WIDTH;
    endfunction
    
    // $$Bufs
    // write queue is not flushed!
    task automatic flushOooBuffersAll();
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
    
    task automatic flushOooBuffersPartial(input OpSlot op);
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

    task automatic rollbackToStable();
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
    endtask

    task automatic rollbackToCheckpoint();
        BranchCheckpoint single = branchCP;

        renamedEmul.coreState = single.state;
        renamedEmul.tmpDataMem.copyFrom(single.mem);
        
        execEmul.coreState = single.state;
        execEmul.tmpDataMem.copyFrom(single.mem);
        
        execState = single.state;
        execMem.copyFrom(single.mem);
        
        restoreMappings(single);
        renameInds = single.inds;
    endtask
    

    task automatic resetEmuls();
        renamedEmul.reset();
        execEmul.reset();
        retiredEmul.reset();
        
        execState = initialState(IP_RESET);
        execMem.reset();
    endtask
    
    task automatic saveCP(input OpSlot op);
        int intMapR[32] = registerTracker.intMapR;
        int floatMapR[32] = registerTracker.floatMapR;
        BranchCheckpoint cp = new(op, renamedEmul.coreState, renamedEmul.tmpDataMem, intWritersR, floatWritersR, intMapR, floatMapR, renameInds);
        branchCheckpointQueue.push_back(cp);
    endtask
    
    task automatic addToQueues(input OpSlot op);
        AbstractInstruction ins = decAbs(op.bits);
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
    
    task automatic renameOp(input OpSlot op);             
        AbstractInstruction ins = decAbs(op.bits);
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

        if (isStoreMemOp(op)) begin
            Word effAdr = calculateEffectiveAddress(ins, argVals);
            Word value = argVals[2];
            memTracker.addStore(op, effAdr, value);
        end
        if (isLoadMemOp(op)) begin
            Word effAdr = calculateEffectiveAddress(ins, argVals);
            memTracker.addLoad(op, effAdr, 'x);
        end

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
        AbstractInstruction ins = decAbs(op.bits);
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
        AbstractInstruction ins = decAbs(op.bits);

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

    task automatic mapOpAtRename(input OpSlot op);
        AbstractInstruction abs = decAbs(op.bits);
        if (writesIntReg(op)) intWritersR[abs.dest] = op.id;
        if (writesFloatReg(op)) floatWritersR[abs.dest] = op.id;
        intWritersR[0] = -1;
        
        registerTracker.reserveInt(op);
        registerTracker.reserveFloat(op);
    endtask

    task automatic mapOpAtCommit(input OpSlot op);
        AbstractInstruction abs = decAbs(op.bits);
        if (writesIntReg(op)) intWritersC[abs.dest] = op.id;
        if (writesFloatReg(op)) floatWritersC[abs.dest] = op.id;
        intWritersC[0] = -1;
        
        registerTracker.commitInt(op);
        registerTracker.commitFloat(op);
        
        if (isMemOp(op)) memTracker.remove(op);
    endtask

    function automatic void updateInds(ref IndexSet inds, input OpSlot op);
        AbstractInstruction ins = decAbs(op.bits);        
        inds.rename = (inds.rename + 1) % ROB_SIZE;
        if (isBranchIns(ins)) inds.bq = (inds.bq + 1) % BC_QUEUE_SIZE;
        if (isLoadIns(ins)) inds.lq = (inds.lq + 1) % LQ_SIZE;
        if (isStoreIns(ins)) inds.sq = (inds.sq + 1) % SQ_SIZE;
    endfunction

    task automatic writeToOOOQ(input OpSlotA sa);
        foreach (sa[i]) if (sa[i].active) oooQueue.push_back('{sa[i].id, 0});
    endtask

    task automatic updateOOOQ(input OpSlot op);
        const int ind[$] = oooQueue.find_index with (item.id == op.id);
        assert (ind.size() > 0) oooQueue[ind[0]].done = '1; else $error("No such id in OOOQ: %d", op.id); 
    endtask

    task automatic drainWriteQueue();
        if (oooLevels.csq != 0) void'(committedStoreQueue.pop_front());
        storeHead_Q <= storeHead_C;
        
       if (storeHead_C.op.active && isStoreSysOp(storeHead_C.op))
           writeSysReg(execState, storeHead_C.adr, storeHead_C.val)
          ;
    endtask

    task automatic advanceOOOQ();
        // Don't commit anything more if event is being handled
        if (lateEventInfo.redirect || intPrev || resetPrev ||  interrupt || reset 
                             || (USE_DELAYED_EVENTS && lateEventInfoWaiting.redirect) // TODO: turn this on when waiting implemented
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
        
        // fqSize is written in prev cycle, so new items must wait at least a cycle in FQ
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


    // $$General
    task automatic performRedirect();
        if (lateEventInfo.redirect || intPrev || resetPrev)
            ipStage <= '{'1, -1, lateEventInfo.target, '{default: '0}, '{default: 'x}};
        else if (branchEventInfo.redirect)
            ipStage <= '{'1, -1, branchEventInfo.target, '{default: '0}, '{default: 'x}};
        else $fatal(2, "Should never get here");

        flushFrontend();
        
        nextStageA <= '{default: EMPTY_SLOT};

        if (lateEventInfo.redirect || intPrev || resetPrev) begin
            rollbackToStable();
            renamedDivergence = 0;
            
            flushOooBuffersAll();
            registerTracker.flushAll();
            memTracker.flushAll();
            
            if (resetPrev) resetEmuls();
        end
        else if (branchEventInfo.redirect) begin
            rollbackToCheckpoint();
            renamedDivergence = insMap.get(branchEventInfo.op.id).divergence;
            
            flushOooBuffersPartial(branchEventInfo.op);  
            registerTracker.flush(branchEventInfo.op);
            memTracker.flush(branchEventInfo.op);
        end
        
        flushExec_();

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

    task automatic writeToOpQ(input OpSlotA sa);
        foreach (sa[i]) if (sa[i].active) opQueue.push_back(sa[i]);
        
        // Mirror into separate queues 
        foreach (sa[i]) if (sa[i].active) begin
            if (isLoadOp(sa[i]) || isStoreOp(sa[i])) T_iqMem.push_back(sa[i]);
            else if (isSysOp(sa[i])) T_iqSys.push_back(sa[i]);
            else if (isBranchOp(sa[i])) T_iqBranch.push_back(sa[i]);
            else T_iqRegular.push_back(sa[i]);
        end
    endtask
    
    task automatic setLateEvent(ref CpuState state, input OpSlot op);    
        AbstractInstruction abs = decAbs(op.bits);
        LateEvent evt = getLateEvent(op, abs, state.sysRegs[2], state.sysRegs[3]);

        lateEventInfo_Norm <= '{op, evt.redirect, evt.target};
            lateEventInfoWaiting <= '{op, evt.redirect, evt.target};

        //sig <= evt.sig;
        //wrong <= evt.wrong;
    endtask




    // $$TEMP
    task automatic performSysStore(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decAbs(op.bits);
        Word3 args = getAndVerifyArgs(state, op);

        //writeSysReg(state, args[1], args[2]);
        state.target = op.adr + 4;
    endtask

    task automatic performSys(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decAbs(op.bits);

        case (abs.def.o)
            //O_sysStore: performSysStore(state, op);
            O_halt: $error("halt not implemented");
            default: ;                            
        endcase
        
        if (!USE_DELAYED_EVENTS)
            modifySysRegs(state, op.adr, abs);
    endtask



    
    // $$Exec
    task automatic runExec();
        IssueGroup igIssue = DEFAULT_ISSUE_GROUP, igExec = DEFAULT_ISSUE_GROUP;// = issuedSt0;
    
        if (memOpPrev.active) begin // Finish executing mem operation from prev cycle
            execMemLater(memOpPrev);
        end
        else if (memOp.active || issuedSt0.mem.active || issuedSt1.mem.active
                ) begin
        end
        else begin
            igIssue = issueFromOpQ(opQueue, oooLevels.oq); // oqSize);
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
    
    task automatic flushExec_();
        issuedSt0 <= DEFAULT_ISSUE_GROUP;
        issuedSt1 <= DEFAULT_ISSUE_GROUP;
    
        memOp <= EMPTY_SLOT;
        memOpPrev <= EMPTY_SLOT;
    endtask
    
    task automatic updateSQ(input InsId id, input Word adr, input Word val);
        int ind[$] = storeQueue.find_first_index with (item.op.id == id);
        storeQueue[ind[0]].adr = adr;
        storeQueue[ind[0]].val = val;
    endtask

    function automatic ReadyVec getReadyVec(input OpSlot iq[$:OP_QUEUE_SIZE]);
        ReadyVec res = '{default: 'z};
        foreach (iq[i]) begin
            InsDependencies deps = insMap.get(iq[i].id).deps;
            logic3 ra = registerTracker.checkArgsReady(deps);//, registerTracker.intReady, registerTracker.floatReady);
            res[i] = ra.and();
        end
        return res;
    endfunction

    function automatic Word3 getPhysicalArgValues(input RegisterTracker tracker, input OpSlot op);
        InsDependencies deps = insMap.get(op.id).deps;
        return getArgValues(tracker, deps);            
    endfunction

    function automatic Word3 getAndVerifyArgs(input CpuState state, input OpSlot op);
        AbstractInstruction abs = decAbs(op.bits);
        Word3 args = getArgs(state.intRegs, state.floatRegs, abs.sources, parsingMap[abs.fmt].typeSpec);
        Word3 argsP = getPhysicalArgValues(registerTracker, op);
        Word3 argsM = insMap.get(op.id).argValues;
        
        assert (argsP == args) else $error("not equal args %p / %p : %s", args, argsP, parsingMap[abs.fmt].typeSpec);
        assert (argsP == args) else $error("not equal args %p / %p : %s", args, argsM, parsingMap[abs.fmt].typeSpec);
    
        return argsP;
    endfunction;


    task automatic setBranch(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decAbs(op.bits);
        ExecEvent evt = resolveBranch(state, abs, op.adr);
        
        state.target = evt.redirect ? evt.target : op.adr + 4;
    endtask

    // TODO: accept Event as arg?
    task automatic setExecEvent(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decAbs(op.bits);
        ExecEvent evt = resolveBranch(state, abs, op.adr);
        
        BranchCheckpoint found[$] = branchCheckpointQueue.find with (item.op.id == op.id);

        branchCP = found[0];
        branchEventInfo <= '{op, evt.redirect, evt.target};
    endtask

    task automatic performLink(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decAbs(op.bits);
        Word result = op.adr + 4;
        writeIntReg(state, abs.dest, result);
    endtask

    task automatic performBranch(ref CpuState state, input OpSlot op);
        setBranch(state, op);
        performLink(state, op);
    endtask
    
    task automatic performRegularOp(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decAbs(op.bits);
        Word3 args = getAndVerifyArgs(state, op);
        
        Word result = (abs.def.o == O_sysLoad) ? state.sysRegs[args[1]] : calculateResult(abs, args, op.adr);

        if (writesIntReg(op)) writeIntReg(state, abs.dest, result);
        if (writesFloatReg(op)) writeFloatReg(state, abs.dest, result);
        state.target = op.adr + 4;
    endtask    

    task automatic performMemFirst(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decAbs(op.bits);
        Word3 args = getAndVerifyArgs(state, op);

        Word adr = calculateEffectiveAddress(abs, args);

        // TODO: make struct, unpack at assigment to ports
        readReq[0] <= '1;
        readAdr[0] <= adr;
        memOp <= op;
        
        //if (isStoreMemOp(op)) begin
        if (isStoreOp(op)) begin
            updateSQ(op.id, adr, args[2]);
        end
    endtask

    task automatic performMemLater(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decAbs(op.bits);
        Word3 args = getAndVerifyArgs(state, op);

        Word adr = calculateEffectiveAddress(abs, args);
        
        // TODO: develop adr overlap check?
        StoreQueueEntry oooMatchingStores[$] = storeQueue.find with (item.adr == adr && isStoreMemOp(item.op) && item.op.id < op.id);
        StoreQueueEntry committedMatchingStores[$] = committedStoreQueue.find with (item.adr == adr && isStoreMemOp(item.op) && item.op.id < op.id);
        StoreQueueEntry matchingStores[$] = {committedMatchingStores, oooMatchingStores};
        // Get last (youngest) of the matching stores
        Word memData = (matchingStores.size() != 0) ? matchingStores[$].val : readIn[0];
        Word data = isLoadSysIns(abs) ? state.sysRegs[args[1]] : memData;
        
        if (matchingStores.size() != 0) begin
            $display("SQ forwarding %d->%d", matchingStores[$].op.id, op.id);
        end

        if (writesIntReg(op)) writeIntReg(state, abs.dest, data);
        if (writesFloatReg(op)) writeFloatReg(state, abs.dest, data);
        state.target = op.adr + 4;
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
                //else if (isMemOp(op) || isLoadSysIns(decAbs(op.bits)) || isStoreSysIns(decAbs(op.bits))) begin
                else if (isLoadOp(op) || isStoreOp(op)) begin
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



    // $$Helper
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

    function automatic AbstractInstruction decAbs(input Word bits);
        return decodeAbstract(bits);
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
