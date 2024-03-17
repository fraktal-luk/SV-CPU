
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
    
    
    const logic SYS_LOAD_AS_MEM = 0;
    
    
    typedef struct {
        OpSlot op;
    } RobEntry;
    

    typedef struct {
        OpSlot op;
    } LoadQueueEntry;
    
    
    typedef struct {
        OpSlot op;
    } StoreQueueEntry;

    
    typedef logic logic3[3];
    
    function automatic logic3 checkArgsReady(input InsDependencies deps, input logic readyInt[N_REGS_INT], input logic readyFloat[N_REGS_FLOAT]);
        logic3 res;
        foreach (deps.types[i])
            case (deps.types[i])
                SRC_CONST: res[i] = 1;
                SRC_INT:   res[i] = readyInt[deps.sources[i]];
                SRC_FLOAT: res[i] = readyFloat[deps.sources[i]];
            endcase
            
        return res;
    endfunction

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

    function automatic void updateInds(ref IndexSet inds, input OpSlot op);
        AbstractInstruction ins = decodeAbstract(op.bits);        
        inds.rename = (inds.rename + 1) % ROB_SIZE;
        if (isBranchIns(ins)) inds.bq = (inds.bq + 1) % BC_QUEUE_SIZE;
        if (isLoadIns(ins)) inds.lq = (inds.lq + 1) % LQ_SIZE;
        if (isStoreIns(ins)) inds.sq = (inds.sq + 1) % SQ_SIZE;
    endfunction

    InstructionMap insMap = new();
  
        InsDependencies lastDepsRe, lastDepsEx;
        InstructionInfo latestOOO[20], committedOOO[20];
        InstructionInfo lastInsInfo;

    RegisterTracker #(N_REGS_INT, N_REGS_FLOAT) registerTracker = new();
    
    InsId intWritersR[32] = '{default: -1}, floatWritersR[32] = '{default: -1};
    InsId intWritersC[32] = '{default: -1}, floatWritersC[32] = '{default: -1};

    
    int cycleCtr = 0, fetchCtr = 0;
    int fqSize = 0, oqSize = 0, oooqSize = 0, bcqSize = 0, nFreeRegsInt = 0, nSpecRegsInt = 0, nStabRegsInt = 0, nFreeRegsFloat = 0, robSize = 0, lqSize = 0, sqSize = 0;
    int insMapSize = 0, renamedDivergence = 0, nRenamed = 0, nCompleted = 0, nRetired = 0, oooqCompletedNum = 0, frontCompleted = 0;

    logic fetchAllow, renameAllow;
    logic resetPrev = 0, intPrev = 0;
    //logic branchRedirect = 0, eventRedirect = 0;
    //Word branchTarget = 'x, eventTarget = 'x;
    //OpSlot branchOp = EMPTY_SLOT, eventOp = EMPTY_SLOT;
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
  

    OpSlot memOp = EMPTY_SLOT, memOpPrev = EMPTY_SLOT, sysOp = EMPTY_SLOT, sysOpPrev = EMPTY_SLOT,
        lastRenamed = EMPTY_SLOT, lastCompleted = EMPTY_SLOT, lastRetired = EMPTY_SLOT;
    IssueGroup issuedSt0 = DEFAULT_ISSUE_GROUP, issuedSt1 = DEFAULT_ISSUE_GROUP;



    OpStatus oooQueue[$:OOO_QUEUE_SIZE];

    RobEntry rob[$:ROB_SIZE];
    LoadQueueEntry loadQueue[$:LQ_SIZE];
    StoreQueueEntry storeQueue[$:SQ_SIZE];

    int bqIndex = 0, lqIndex = 0, sqIndex = 0;

    IndexSet renameInds = '{default: 0}, commitInds = '{default: 0};


    BranchCheckpoint branchCheckpointQueue[$:BC_QUEUE_SIZE];
    
    CpuState execState;
    SimpleMem execMem = new();
    Emulator renamedEmul = new(), execEmul = new(), retiredEmul = new();

    string lastRenamedStr, lastCompletedStr, lastRetiredStr, oooqStr;
    logic cmp0, cmp1;
    Word cmpw0, cmpw1, cmpw2, cmpw3;

    always @(posedge clk) cycleCtr++; 


    typedef struct {
        OpSlot op;
        logic redirect;
        Word target;
    } EventInfo;
    
    const EventInfo EMPTY_EVENT_INFO = '{EMPTY_SLOT, 0, 'x};

    EventInfo branchEventInfo = EMPTY_EVENT_INFO, lateEventInfo = EMPTY_EVENT_INFO;
      //  branchEventInfo_T, lateEventInfo_T;

    typedef struct {
        logic req;
        Word adr;
        Word value;
    } MemWriteInfo;
    
    const MemWriteInfo EMPTY_WRITE_INFO = '{0, 'x, 'x};
    
    MemWriteInfo writeInfo = EMPTY_WRITE_INFO;  
    
        assign writeReq = writeInfo.req;
        assign writeAdr = writeInfo.adr;
        assign writeOut = writeInfo.value;

//        assign cmp0 = (writeReq === writeInfo.req);
//        assign cmp1 = (writeAdr === writeInfo.adr);
//        assign cmpw0 = (writeOut === writeInfo.value);
    

    always @(posedge clk) begin
        resetPrev <= reset;
        intPrev <= interrupt;
        
        sig <= 0;
        wrong <= 0;

        readReq[0] = 0;
        readAdr[0] = 'x;
        
//        writeReq = 0;
//        writeAdr = 'x;
//        writeOut = 'x;
            writeInfo = EMPTY_WRITE_INFO;
            
    //    branchOp <= EMPTY_SLOT;
    //    branchRedirect <= 0;
     //   branchTarget <= 'x;
            branchEventInfo <= EMPTY_EVENT_INFO;

     //   eventOp <= EMPTY_SLOT;
      //  eventRedirect <= 0;
      //  eventTarget <= 'x;
            lateEventInfo <= EMPTY_EVENT_INFO;

        advanceOOOQ();
  
        issuedSt0 <= DEFAULT_ISSUE_GROUP;
        issuedSt1 <= issuedSt0;

        //if (resetPrev | intPrev | eventRedirect) begin
        if (resetPrev | intPrev | lateEventInfo.redirect) begin
            performRedirect();
        end
        //else if (branchRedirect) begin
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

            sysOp <= EMPTY_SLOT;
            if (!sysOpPrev.active) sysOpPrev <= tick(sysOp, evts);
            else sysOpPrev <= tick(sysOpPrev, evts);

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
        
        frontCompleted <= countFrontCompleted();

        nFreeRegsInt <= registerTracker.getNumFreeInt();
            nSpecRegsInt <= registerTracker.getNumSpecInt();
            nStabRegsInt <= registerTracker.getNumStabInt();
        nFreeRegsFloat <= registerTracker.getNumFreeFloat();
     
            setOpsReady();
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
                 //  cmp0 <= (TMP_getEmul().coreState == retiredEmul.coreState);

    end


    assign insAdr = ipStage.baseAdr;

    assign fetchAllow = fetchQueueAccepts(fqSize) && bcQueueAccepts(bcqSize);
    assign renameAllow = opQueueAccepts(oqSize) && oooQueueAccepts(oooqSize) && regsAccept(nFreeRegsInt, nFreeRegsFloat)
                    && robAccepts(robSize) && lqAccepts(lqSize) && sqAccepts(sqSize);

//        assign branchEventInfo_T = '{branchOp, branchRedirect, branchTarget};
  //      assign cmp0 = (branchEventInfo === branchEventInfo_T);
  //      assign lateEventInfo_T = '{eventOp, eventRedirect, eventTarget};
  //      assign cmp1 = (lateEventInfo === lateEventInfo_T);

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
        else if (sysOpPrev.active) begin // Finish executing sys operation from prev cycle
            execSysLater(sysOpPrev);
            sysOpPrev <= EMPTY_SLOT;
        end
        else if (memOp.active || issuedSt0.mem.active || issuedSt1.mem.active
                ) begin
        end
        else if (sysOp.active || issuedSt0.sys.active || issuedSt1.sys.active
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

          //  if (op.id == 218) $display("218: %p \n %p", decodeAbstract(op.bits), insMap.get(218));

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
        //if (eventRedirect || intPrev || resetPrev) begin
        if (lateEventInfo.redirect || intPrev || resetPrev) begin
            //ipStage <= '{'1, -1, eventTarget, '{default: '0}, '{default: 'x}};
            ipStage <= '{'1, -1, lateEventInfo.target, '{default: '0}, '{default: 'x}};
        end
        //else if (branchRedirect) begin
        else if (branchEventInfo.redirect) begin
            //ipStage <= '{'1, -1, branchTarget, '{default: '0}, '{default: 'x}};
            ipStage <= '{'1, -1, branchEventInfo.target, '{default: '0}, '{default: 'x}};
        end
        else $fatal(2, "Should never get here");

        //if (eventRedirect || intPrev || resetPrev) begin
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
        //else if (branchRedirect) begin
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

            //renamedDivergence = insMap.get(branchOp.id).divergence;
            renamedDivergence = insMap.get(branchEventInfo.op.id).divergence;
        end

        // Clear stages younger than activated redirection
        fetchStage0 <= EMPTY_STAGE;
        fetchStage1 <= EMPTY_STAGE;
        fetchQueue.delete();
        
        nextStageA <= '{default: EMPTY_SLOT};
        
        //if (eventRedirect || intPrev || resetPrev) begin
        if (lateEventInfo.redirect || intPrev || resetPrev) begin
            flushAll();
            registerTracker.flushAll();    
        end
        //else if (branchRedirect) begin
        else if (branchEventInfo.redirect) begin
            //flushPartial(branchOp);  
            flushPartial(branchEventInfo.op);  
            //registerTracker.flush(branchOp);    
            registerTracker.flush(branchEventInfo.op);    
        end

        issuedSt0 <= DEFAULT_ISSUE_GROUP;
        issuedSt1 <= DEFAULT_ISSUE_GROUP;
    
        memOp <= EMPTY_SLOT;
        memOpPrev <= EMPTY_SLOT;
        sysOp <= EMPTY_SLOT;
        sysOpPrev <= EMPTY_SLOT;

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
        storeQueue.push_back('{op});
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

           // if (op.id == 218) $display("!!! %p, %p, %d", renamedEmul.coreState.intRegs, deps, result);


        runInEmulator(renamedEmul, op);
        renamedEmul.drain();
        target = renamedEmul.coreState.target;

        updateInds(renameInds, op);

        mapOpAtRename(op);
        if (isBranchOp(op)) saveCP(op);

            lastRenamed = op;
            nRenamed++;

        insMap.setDivergence(op.id, renamedDivergence);
        insMap.setResult(op.id, result);
        insMap.setTarget(op.id, target);
        insMap.setDeps(op.id, deps);
        insMap.setInds(op.id, renameInds);
        insMap.setArgValues(op.id, argVals);

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
        
        // Actual execution of ops which must be done after Commit
        if (isSysOp(op)) begin
            setLateEvent(execState, op);
            performSys(execState, op);
        end

            lastRetired = op;
            nRetired++;
        
        releaseQueues(op);

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
        
        foreach (fetchStage0ua[i]) 
            if (fetchStage0ua[i].active)
                insMap.setEncoding(fetchStage0ua[i]);
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



        task automatic setOpsReady();
            opsReady <= '{default: 'z};
            foreach (opQueue[i]) begin
                InsDependencies deps = insMap.get(opQueue[i].id).deps;
                logic3 ra = checkArgsReady(deps, registerTracker.intReady, registerTracker.floatReady);
                opsReady[i] <= ra.and();
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


    function automatic InsDependencies getPhysicalArgs(input OpSlot op, input int mapInt[32], input int mapFloat[32]);
        int sources[3] = '{-1, -1, -1};
        SourceType types[3] = '{SRC_CONST, SRC_CONST, SRC_CONST}; 
        
        AbstractInstruction abs = decodeAbstract(op.bits);
        string typeSpec = parsingMap[abs.fmt].typeSpec;
        
        foreach (sources[i]) begin
            if (typeSpec[i + 2] == "i") begin
                sources[i] = mapInt[abs.sources[i]];
                types[i] = SRC_INT;
            end
            else if (typeSpec[i + 2] == "f") begin
                sources[i] = mapFloat[abs.sources[i]];
                types[i] = SRC_FLOAT;
            end
            else if (typeSpec[i + 2] == "c") begin
                sources[i] = abs.sources[i];
                types[i] = SRC_CONST;
            end
            else if (typeSpec[i + 2] == "0") begin
                sources[i] = abs.sources[i];
                types[i] = SRC_ZERO;
            end
        end

        return '{sources, types};
    endfunction

        function automatic Word3 getArgValues(input RegisterTracker tracker, input InsDependencies deps);
            Word res[3];
            foreach (res[i]) begin
                if (deps.types[i] == SRC_INT) begin
                    res[i] = tracker.intRegs[deps.sources[i]];
                end
                else if (deps.types[i] == SRC_FLOAT) begin
                    res[i] = tracker.floatRegs[deps.sources[i]];
                end
                else if (deps.types[i] == SRC_CONST) begin
                    res[i] = deps.sources[i];
                end
                else if (deps.types[i] == SRC_ZERO) begin
                    res[i] = 0;
                end
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
     //   eventTarget <= IP_RESET;
            lateEventInfo <= '{EMPTY_SLOT, 1, IP_RESET};
        performAsyncEvent(retiredEmul.coreState, IP_RESET);
    endtask

    task automatic execInterrupt();
        $display(">> Interrupt !!!");
      //  eventTarget <= IP_INT;
            lateEventInfo <= '{EMPTY_SLOT, 1, IP_INT};
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
//        branchOp <= op;
  //      branchTarget <= evt.target;
  //      branchRedirect <= evt.redirect;
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
//            writeReq = 1;
//            writeAdr = adr;
//            writeOut = args[2];
                writeInfo <= '{1, adr, args[2]};
        end
    endtask

    task automatic performMemLater(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        Word3 args = getArgs(state.intRegs, state.floatRegs, abs.sources, parsingMap[abs.fmt].typeSpec);
        Word3 argsP = getPhysicalArgValues(registerTracker, op);
        Word3 argsM = insMap.get(op.id).argValues;
        
        Word data = isLoadSysIns(abs) ? state.sysRegs[args[1]] : readIn[0];
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
        sysOp <= op;
    endtask

    task automatic execSysLater(input OpSlot op);
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
            if (isMemOp(sa[i])) T_iqMem.push_back(sa[i]);
            else if (isSysOp(sa[i]) || (SYS_LOAD_AS_MEM && isLoadSysIns(decodeAbstract(sa[i].bits)))) T_iqSys.push_back(sa[i]);
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

    task automatic advanceOOOQ();
        // Don't commit anything more if event is being handled
        //if (eventRedirect || intPrev || resetPrev ||  interrupt || reset) return;
        if (lateEventInfo.redirect || intPrev || resetPrev ||  interrupt || reset) return;

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
                else if (isMemOp(op) || (SYS_LOAD_AS_MEM && isLoadSysIns(decodeAbstract(op.bits)))) begin
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

  //      eventOp <= op;
  //      eventTarget <= evt.target;
  //      eventRedirect <= evt.redirect;
            lateEventInfo <= '{op, evt.redirect, evt.target};
        sig <= evt.sig;
        wrong <= evt.wrong;
    endtask

    // How many in front are ready to commit
    function automatic int countFrontCompleted();
        foreach (oooQueue[i]) begin
            if (!oooQueue[i].done) return i;
        end
        return oooQueue.size();
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

     
        string bqStr;
        always @(posedge clk) begin
            automatic int ids[$];
            foreach (branchCheckpointQueue[i]) ids.push_back(branchCheckpointQueue[i].op.id);
            $swrite(bqStr, "%p", ids);
        end

endmodule
 