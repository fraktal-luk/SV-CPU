
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
    
    logic dummy = '1;


    localparam int FETCH_QUEUE_SIZE = 8;
    localparam int BC_QUEUE_SIZE = 64;

    localparam int N_REGS_INT = 128;
    localparam int N_REGS_FLOAT = 128;

    localparam int OP_QUEUE_SIZE = 24;
    localparam int OOO_QUEUE_SIZE = 120;

    localparam int ROB_SIZE = 128;
    
    localparam int LQ_SIZE = 80;
    localparam int SQ_SIZE = 80;
    
    
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

    typedef OpSlot Stage_N[FETCH_WIDTH];

    const Stage_N EMPTY_STAGE = '{default: EMPTY_SLOT};

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


        typedef struct {
            OpSlot late;
            OpSlot exec;
        } Events;

        function automatic OpSlot tick(input OpSlot op, input Events evts);
            return op;
        endfunction

        function automatic OpSlot eff(input OpSlot op);
            if (lateEventInfo.redirect || (branchEventInfo.redirect && op.id > branchEventInfo.op.id)) begin
                return EMPTY_SLOT;
            end
            return op;
        endfunction

        function automatic IssueGroup effIG(input IssueGroup ig);
            IssueGroup res;
            
            foreach (ig.regular[i])
                res.regular[i] = eff(ig.regular[i]);

            res.branch = eff(ig.branch);
            res.mem = eff(ig.mem);
            res.sys = eff(ig.sys);
            
            res.num = ig.num;
            
            return res;
        endfunction
        
        typedef OpSlot OpSlot4[4];

        function automatic OpSlot4 effA(input OpSlot ops[4]);
            OpSlot res[4];
            foreach (ops[i]) res[i] = eff(ops[i]);
            return res;
        endfunction


    typedef struct {
        InsId intWritersR[32] = '{default: -1};
        InsId floatWritersR[32] = '{default: -1};
        InsId intWritersC[32] = '{default: -1};
        InsId floatWritersC[32] = '{default: -1};
    } WriterTracker;


    int cycleCtr = 0;

    always @(posedge clk) cycleCtr++;


    // Overall

    RegisterTracker #(N_REGS_INT, N_REGS_FLOAT) registerTracker = new();
    MemTracker memTracker = new();

    WriterTracker wrTracker;

    Events evts;
    BufferLevels oooLevels, oooLevels_N, oooAccepts;


    int nFreeRegsInt = 0, /*nSpecRegsInt = 0, nStabRegsInt = 0,*/ nFreeRegsFloat = 0, bcqSize = 0;
    int insMapSize = 0, trSize = 0, nRenamed = 0, nCompleted = 0, nRetired = 0;//, 
           // oooqCompletedNum = 0 //, frontCompleted = 0
           // ;

    logic fetchAllow, renameAllow, buffersAccepting, csqEmpty = 0;

    BranchCheckpoint branchCP;


    int fqSize = 0;

    // Frontend
    generate

        Stage_N ipStage = EMPTY_STAGE, fetchStage0 = EMPTY_STAGE, fetchStage1 = EMPTY_STAGE;
        Stage_N fetchQueue[$:FETCH_QUEUE_SIZE];

        int fetchCtr = 0;
        OpSlotA stageRename0 = '{default: EMPTY_SLOT};

        task automatic flushFrontend();
            markKilledFrontStage(fetchStage0);
            markKilledFrontStage(fetchStage1);
            fetchStage0 <= EMPTY_STAGE;
            fetchStage1 <= EMPTY_STAGE;

            foreach (fetchQueue[i]) begin
                Stage_N current = fetchQueue[i];
                markKilledFrontStage(current);
            end
            fetchQueue.delete();
        endtask

        task automatic redirectFront();
            Word target;

            if (lateEventInfo.redirect)         target = lateEventInfo.target;
            else if (branchEventInfo.redirect)  target = branchEventInfo.target;
            else $fatal(2, "Should never get here");

            markKilledFrontStage(ipStage);
            ipStage <= '{0: '{1, -1, target, 'x}, default: EMPTY_SLOT};

            fetchCtr <= fetchCtr + FETCH_WIDTH;

            registerNewTarget(fetchCtr + FETCH_WIDTH, target);

            flushFrontend();

            markKilledFrontStage(stageRename0);
            stageRename0 <= '{default: EMPTY_SLOT};
        endtask

        task automatic fetchAndEnqueue();
            Stage_N fetchStage0ua, ipStageU;
            if (fetchAllow) begin
                Word target = (ipStage[0].adr & ~(4*FETCH_WIDTH-1)) + 4*FETCH_WIDTH;
                ipStage <= '{0: '{1, -1, target, 'x}, default: EMPTY_SLOT};
                fetchCtr <= fetchCtr + FETCH_WIDTH;
                
                registerNewTarget(fetchCtr + FETCH_WIDTH, target);
            end

            ipStageU = setActive(ipStage, ipStage[0].active & fetchAllow, fetchCtr);

            fetchStage0 <= ipStageU;
            fetchStage0ua = setWords(fetchStage0, insIn);
            
            foreach (fetchStage0ua[i]) if (fetchStage0ua[i].active) begin
                insMap.add(fetchStage0ua[i]);
                insMap.setEncoding(fetchStage0ua[i]);
            end

            fetchStage1 <= fetchStage0ua;
            if (anyActive(fetchStage1)) fetchQueue.push_back(fetchStage1);
        
            stageRename0 <= readFromFQ();
        endtask
        
        function automatic OpSlotA readFromFQ();
            OpSlotA res = '{default: EMPTY_SLOT};
    
            // fqSize is written in prev cycle, so new items must wait at least a cycle in FQ
            if (fqSize > 0 && renameAllow) begin
                Stage_N fqOut_N = fetchQueue.pop_front();
                foreach (fqOut_N[i]) res[i] = fqOut_N[i];
            end
            
            return res;
        endfunction
        
            
        // Frontend process
        always @(posedge clk) begin
            if (lateEventInfo.redirect || branchEventInfo.redirect)
                redirectFront();
            else
                fetchAndEnqueue();
                
            fqSize <= fetchQueue.size();
        end

    endgenerate

    assign insAdr = ipStage[0].adr;


    // Rename
    OpSlotA stageRename1 = '{default: EMPTY_SLOT}; 
    
    // OOO IQ
    OpSlot opQueue[$:OP_QUEUE_SIZE];            
        typedef logic ReadyVec[OP_QUEUE_SIZE];
        ReadyVec opsReady, opsReadyRegular, opsReadyBranch, opsReadyMem, opsReadySys;

    OpSlot T_iqRegular[$:OP_QUEUE_SIZE];
    OpSlot T_iqBranch[$:OP_QUEUE_SIZE];
    OpSlot T_iqMem[$:OP_QUEUE_SIZE];
    OpSlot T_iqSys[$:OP_QUEUE_SIZE];


    // Issue/Exec
    IssueGroup issuedSt0 = DEFAULT_ISSUE_GROUP, issuedSt1 = DEFAULT_ISSUE_GROUP;
    IssueGroup issuedSt0_E, issuedSt1_E;


    // Exec
    OpSlot memOp_A = EMPTY_SLOT, memOpPrev = EMPTY_SLOT;
    OpSlot memOp_E, memOpPrev_E;
    
    OpSlot doneOpsRegular[4] = '{default: EMPTY_SLOT};
    OpSlot doneOpBranch = EMPTY_SLOT, doneOpMem = EMPTY_SLOT, doneOpSys = EMPTY_SLOT;

    OpSlot doneOpsRegular_E[4];
    OpSlot doneOpBranch_E, doneOpMem_E, doneOpSys_E;

    Word execResultsRegular[4] = '{'x, 'x, 'x, 'x};
    Word execResultLink = 'x, execResultMem = 'x;
    
    
    // OOO
    OpStatus oooQueue[$:OOO_QUEUE_SIZE];

    RobEntry rob[$:ROB_SIZE];
    LoadQueueEntry loadQueue[$:LQ_SIZE];
    StoreQueueEntry storeQueue[$:SQ_SIZE];
    
    // Committed
    StoreQueueEntry csq_N[$] = '{'{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}, '{EMPTY_SLOT, 'x, 'x}};
    StoreQueueEntry storeHead = '{EMPTY_SLOT, 'x, 'x};

    //int bqIndex = 0, lqIndex = 0, sqIndex = 0;

    // OOO
    IndexSet renameInds = '{default: 0}, commitInds = '{default: 0};


    typedef struct {
        InsId id;
        Word target;
    } BranchTargetEntry;

    BranchTargetEntry branchTargetQueue[$:BC_QUEUE_SIZE];
    BranchCheckpoint branchCheckpointQueue[$:BC_QUEUE_SIZE];



    // Overall DB
    Emulator renamedEmul = new(), retiredEmul = new();

    EventInfo branchEventInfo = EMPTY_EVENT_INFO, // Overall?
             lateEventInfo = EMPTY_EVENT_INFO, lateEventInfoWaiting = EMPTY_EVENT_INFO; // Overall?

    MemWriteInfo writeInfo, // Committed
                 readInfo = EMPTY_WRITE_INFO; // Exec


    // Overall
    AbstractInstruction eventIns;

    // Control
    Word sysRegs_N[32];  
    Word retiredTarget = 0;


    // DB
    InstructionInfo latestOOO[20], committedOOO[20];
    OpSlot lastRenamed = EMPTY_SLOT, lastCompleted = EMPTY_SLOT, lastRetired = EMPTY_SLOT;
    string lastRenamedStr, lastCompletedStr, lastRetiredStr, oooqStr;

    logic cmp0, cmp1;
    Word cmpw0, cmpw1, cmpw2, cmpw3;
        string iqRegularStr;
        string iqRegularStrA[OP_QUEUE_SIZE];

    assign eventIns = decAbs(lateEventInfo.op);
    assign sigValue = lateEventInfo.op.active && (eventIns.def.o == O_send);
    assign wrongValue = lateEventInfo.op.active && (eventIns.def.o == O_undef);
    
    assign readReq[0] = readInfo.req;
    assign readAdr[0] = readInfo.adr;




    always @(posedge clk) begin
        lateEventInfo <= EMPTY_EVENT_INFO;

        activateEvent();

        drainWriteQueue();
        advanceOOOQ();        
        putWrite();


        if (reset) execReset();
        else if (interrupt) execInterrupt();


    

        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
            redirectRest();
        end
        else begin
            runInOrderPartRe();
        end


        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
            flushIqs();
        end
        else begin
            writeToIqs();
        end
       
        // Issue
        begin
            automatic IssueGroup igIssue = DEFAULT_ISSUE_GROUP;
            igIssue = issueFromOpQ(opQueue, oooLevels.oq, opsReady);
            issuedSt0 <= effIG(igIssue);
        end

        // Complete + write regs
        begin
            foreach (doneOpsRegular_E[i]) begin
                completeOp(doneOpsRegular_E[i]);
                writeResult_N(doneOpsRegular_E[i], execResultsRegular[i]);
            end
            
            completeOp(doneOpBranch_E);
            writeResult_N(doneOpBranch_E, execResultLink);
    
            completeOp(doneOpMem_E);
            writeResult_N(doneOpMem_E, execResultMem);
    
            completeOp(doneOpSys_E);
        end
        
        // CAREFUL, TODO: this requires updates to IQs and reg tracker, so must be after both.
        // Logic based on signals will be more complicated to do.
        updateReadyVecs();

        updateBookkeeping();
    end


    // Exec process
    always @(posedge clk) begin
        begin
            readInfo <= EMPTY_WRITE_INFO;
            branchEventInfo <= EMPTY_EVENT_INFO;
            runExec();
        end
    end
    
        
       // assign cmp0 = (fqSize_A == fqSize);
    
    task automatic updateReadyVecs();
        opsReady <= getReadyVec(opQueue);
        
        opsReadyRegular <= getReadyVec(T_iqRegular);
        opsReadyBranch <= getReadyVec(T_iqBranch);
        opsReadyMem <= getReadyVec(T_iqMem);
        opsReadySys <= getReadyVec(T_iqSys);
        
        
        oooLevels_N.oq <= opQueue.size();
    endtask
    
    
    
    task automatic updateBookkeeping();
        bcqSize <= branchCheckpointQueue.size();
        oooLevels <= getBufferLevels();
        
        nFreeRegsInt <= registerTracker.getNumFreeInt();
        nFreeRegsFloat <= registerTracker.getNumFreeFloat();
     

        
        // Overall DB
            insMapSize = insMap.size();
            trSize = memTracker.transactions.size();

            begin
                automatic OpStatus oooqDone[$] = (oooQueue.find with (item.done == 1));
            //    oooqCompletedNum <= oooqDone.size();
                $swrite(oooqStr, "%p", oooQueue);
                $swrite(iqRegularStr, "%p", T_iqRegular);
                iqRegularStrA = '{default: ""};
                foreach (T_iqRegular[i])
                    iqRegularStrA[i] = disasm(T_iqRegular[i].bits);
            end
    endtask




    function automatic LateEvent getLateEvt(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word sr2 = getSysReg(2);
        Word sr3 = getSysReg(3);
        return getLateEvent(op, abs, sr2, sr3);
    endfunction

    function automatic logic getLateRedirect(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word sr2 = getSysReg(2);
        Word sr3 = getSysReg(3);
        return getLateEvent(op, abs, sr2, sr3).redirect;
    endfunction

    function automatic Word getLateTarget(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word sr2 = getSysReg(2);
        Word sr3 = getSysReg(3);
        return getLateEvent(op, abs, sr2, sr3).target;
    endfunction


    task automatic activateEvent();
        if (!csqEmpty) return;    

        lateEventInfoWaiting <= EMPTY_EVENT_INFO;

        if (lateEventInfoWaiting.op.active) begin
            modifyStateSync(sysRegs_N, lateEventInfoWaiting.op.adr, decAbs(lateEventInfoWaiting.op));               
            retiredTarget <= getLateTarget(lateEventInfoWaiting.op);
            lateEventInfo <= '{lateEventInfoWaiting.op, 0, 0, getLateRedirect(lateEventInfoWaiting.op), getLateTarget(lateEventInfoWaiting.op)};
        end
        else if (lateEventInfoWaiting.reset) begin
            saveStateAsync(sysRegs_N, retiredTarget);
            retiredTarget <= IP_RESET;
            lateEventInfo <= '{EMPTY_SLOT, 0, 1, 1, IP_RESET};
        end
        else if (lateEventInfoWaiting.interrupt) begin
            saveStateAsync(sysRegs_N, retiredTarget);
            retiredTarget <= IP_INT;
            lateEventInfo <= '{EMPTY_SLOT, 1, 0, 1, IP_INT};
        end
    endtask




    task automatic drainWriteQueue();
       if (storeHead.op.active && isStoreSysOp(storeHead.op)) setSysReg(storeHead.adr, storeHead.val);
       void'(csq_N.pop_front());
    endtask


    task automatic advanceOOOQ();
        // Don't commit anything more if event is being handled
        if (interrupt || reset || lateEventInfoWaiting.redirect || lateEventInfo.redirect) return;

        while (oooQueue.size() > 0 && oooQueue[0].done == 1) begin
            OpSlot op = takeFrontOp();
            commitOp(op);
            putMilestone(op.id, InstructionMap::Retire);
            insMap.setRetired(op.id);
            
            if (isSysIns(decAbs(op))) break;
        end
    endtask

    task automatic putWrite();            
        if (csq_N.size() < 4) begin
            csq_N.push_back('{EMPTY_SLOT, 'x, 'x});
            csqEmpty <= 1;
        end
        else csqEmpty <= 0;
        
        storeHead <= csq_N[3];
    endtask



    task automatic renameGroup(input OpSlotA ops);
        foreach (ops[i])
            if (ops[i].active) begin
                renameOp(ops[i]);
                putMilestone(ops[i].id, InstructionMap::Rename);
            end
    endtask



    task automatic writeToIqs();
        foreach (stageRename1[i]) begin
            OpSlot op = stageRename1[i];
            if (op.active) begin
                addToIssueQueues(op);
            end
        end
    endtask

    task automatic addToIssueQueues(input OpSlot op);
        opQueue.push_back(op);
        // Mirror into separate queues 
        if (isLoadIns(decAbs(op)) || isStoreIns(decAbs(op))) T_iqMem.push_back(op);
        else if (isSysIns(decAbs(op))) T_iqSys.push_back(op);
        else if (isBranchIns(decAbs(op))) T_iqBranch.push_back(op);
        else T_iqRegular.push_back(op); 
    endtask

    task automatic flushIqs();
        if (lateEventInfo.redirect) begin
            flushOpQueueAll();
        end
        else if (branchEventInfo.redirect) begin
            flushOpQueuePartial(branchEventInfo.op);
        end
    endtask




    task automatic addToQueues(input OpSlot op);
        oooQueue.push_back('{op.id, 0});   
    
        rob.push_back('{op});      
        if (isLoadIns(decAbs(op))) loadQueue.push_back('{op});
        if (isStoreIns(decAbs(op))) storeQueue.push_back('{op, 'x, 'x});
    endtask

    // Frontend, rename and everything before getting to OOO queues
    task automatic runInOrderPartRe();        
        renameGroup(stageRename0);
        stageRename1 <= stageRename0;
        
        foreach (stageRename1[i]) begin
            OpSlot op = stageRename1[i];
            if (op.active) begin
                addToQueues(op);
            end
        end 
    endtask
    
    
    assign oooAccepts = getBufferAccepts(oooLevels, oooLevels_N);
    assign buffersAccepting = buffersAccept(oooAccepts);


    assign fetchAllow = fetchQueueAccepts(fqSize) && bcQueueAccepts(bcqSize);
    assign renameAllow = buffersAccepting && regsAccept(nFreeRegsInt, nFreeRegsFloat);

    assign writeInfo = '{storeHead.op.active && isStoreMemIns(decAbs(storeHead.op)), storeHead.adr, storeHead.val};

    assign writeReq = writeInfo.req;
    assign writeAdr = writeInfo.adr;
    assign writeOut = writeInfo.value;

    assign sig = sigValue;
    assign wrong = wrongValue;


    function logic fetchQueueAccepts(input int k);
        return k <= FETCH_QUEUE_SIZE - 3; // 2 stages between IP stage and FQ
    endfunction
    
    function logic bcQueueAccepts(input int k);
        return k <= BC_QUEUE_SIZE - 3*FETCH_WIDTH - FETCH_QUEUE_SIZE*FETCH_WIDTH; // 2 stages + FETCH_QUEUE entries, FETCH_WIDTH each
    endfunction

    
    assign memOp_E = eff(memOp_A);
    assign memOpPrev_E = eff(memOpPrev);

    assign issuedSt0_E = effIG(issuedSt0);
    assign issuedSt1_E = effIG(issuedSt1);

    assign doneOpsRegular_E = effA(doneOpsRegular);
    assign doneOpBranch_E = eff(doneOpBranch);
    assign doneOpMem_E = eff(doneOpMem);
    assign doneOpSys_E = eff(doneOpSys);



    function automatic BufferLevels getBufferLevels();
        BufferLevels res;
        res.oq = opQueue.size();
        res.oooq = oooQueue.size();
        //res.bq = branchCheckpointQueue.size();
        res.rob = rob.size();
        res.lq = loadQueue.size();
        res.sq = storeQueue.size();
        //res.csq = committedStoreQueue.size();
        return res;
    endfunction

    function automatic BufferLevels getBufferAccepts(input BufferLevels levels, input BufferLevels levels_N);
        BufferLevels res;
        res.oq = levels.oq <= OP_QUEUE_SIZE - 3*FETCH_WIDTH;
            //res.oq = levels_N.oq <= OP_QUEUE_SIZE - 3*FETCH_WIDTH;
        
        res.oooq = levels.oooq <= OOO_QUEUE_SIZE - 3*FETCH_WIDTH;
        //res.bq = levels.bq <= BC_QUEUE_SIZE - 3*FETCH_WIDTH - FETCH_QUEUE_SIZE*FETCH_WIDTH; // 2 stages + FETCH_QUEUE entries, FETCH_WIDTH each
        res.rob = levels.rob <= ROB_SIZE - 3*FETCH_WIDTH;
        res.lq = levels.lq <= LQ_SIZE - 3*FETCH_WIDTH;
        res.sq = levels.sq <= SQ_SIZE - 3*FETCH_WIDTH;
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
        flushOooQueueAll();
        flushBranchCheckpointQueueAll();
        flushBranchTargetQueueAll();
        flushRobAll();
        flushStoreQueueAll();
        flushLoadQueueAll();
    endtask
    
    
    task automatic flushOpQueueAll();
        while (opQueue.size() > 0) begin
            OpSlot op = (opQueue.pop_back());
            //insMap.setKilled(op.id);
        end
        while (T_iqRegular.size() > 0) begin
            void'(T_iqRegular.pop_back());
        end
        while (T_iqBranch.size() > 0) begin
            void'(T_iqBranch.pop_back());
        end
        while (T_iqMem.size() > 0) begin
            void'(T_iqMem.pop_back());
        end
        while (T_iqSys.size() > 0) begin
            void'(T_iqSys.pop_back());
        end
    endtask

    task automatic flushOooQueueAll();
        while (oooQueue.size() > 0) begin
            void'(oooQueue.pop_back());
        end
    endtask
    
    task automatic flushBranchCheckpointQueueAll();
        while (branchCheckpointQueue.size() > 0) begin
            void'(branchCheckpointQueue.pop_back());
        end
    endtask    

    task automatic flushBranchTargetQueueAll();
        while (branchTargetQueue.size() > 0) begin
            void'(branchTargetQueue.pop_back());
        end
    endtask

    task automatic flushRobAll();
        while (rob.size() > 0) begin
            RobEntry entry = (rob.pop_back());
            putMilestone(entry.op.id, InstructionMap::FlushOOO);
            insMap.setKilled(entry.op.id);
        end
    endtask
 
    task automatic flushStoreQueueAll();
        while (loadQueue.size() > 0) begin
            void'(loadQueue.pop_back());
        end
    endtask
   
    task automatic flushLoadQueueAll();
        while (storeQueue.size() > 0) begin
            void'(storeQueue.pop_back());
        end
    endtask



    task automatic flushOpQueuePartial(input OpSlot op);
        while (opQueue.size() > 0 && opQueue[$].id > op.id) begin
            void'(opQueue.pop_back());
        end
        while (T_iqRegular.size() > 0 && T_iqRegular[$].id > op.id) begin
            void'(T_iqRegular.pop_back());
        end
        while (T_iqBranch.size() > 0 && T_iqBranch[$].id > op.id) begin
            void'(T_iqBranch.pop_back());
        end
        while (T_iqMem.size() > 0 && T_iqMem[$].id > op.id) begin
            void'(T_iqMem.pop_back());
        end
        while (T_iqSys.size() > 0 && T_iqSys[$].id > op.id) begin
            void'(T_iqSys.pop_back());
        end
    endtask

    task automatic flushOooQueuePartial(input OpSlot op);
        while (oooQueue.size() > 0 && oooQueue[$].id > op.id) begin
            void'(oooQueue.pop_back());
        end
    endtask
 
    task automatic flushBranchCheckpointQueuePartial(input OpSlot op);
        while (branchCheckpointQueue.size() > 0 && branchCheckpointQueue[$].op.id > op.id) begin
            void'(branchCheckpointQueue.pop_back());
        end
    endtask    

    task automatic flushBranchTargetQueuePartial(input OpSlot op);
        while (branchTargetQueue.size() > 0 && branchTargetQueue[$].id > op.id) void'(branchTargetQueue.pop_back());
    endtask

    task automatic flushRobPartial(input OpSlot op);
        while (rob.size() > 0 && rob[$].op.id > op.id) begin
            RobEntry entry = (rob.pop_back());
            putMilestone(entry.op.id, InstructionMap::FlushOOO);
            insMap.setKilled(entry.op.id);
        end
    endtask

    task automatic flushStoreQueuePartial(input OpSlot op);
        while (loadQueue.size() > 0 && loadQueue[$].op.id > op.id) begin
            void'(loadQueue.pop_back());
        end
    endtask
   
    task automatic flushLoadQueuePartial(input OpSlot op);
        while (storeQueue.size() > 0 && storeQueue[$].op.id > op.id) begin
            void'(storeQueue.pop_back());
        end
    endtask


    task automatic flushOooBuffersPartial(input OpSlot op);
        flushOooQueuePartial(op);
        flushBranchCheckpointQueuePartial(op);
        flushBranchTargetQueuePartial(op);
        flushRobPartial(op);
        flushStoreQueuePartial(op);
        flushLoadQueuePartial(op);
    endtask


    task automatic restoreMappings(input BranchCheckpoint cp);
        wrTracker.intWritersR = cp.intWriters;
        wrTracker.floatWritersR = cp.floatWriters;

        registerTracker.restore(cp.intMapR, cp.floatMapR);
    endtask


    task automatic rollbackToCheckpoint();
        BranchCheckpoint single = branchCP;

        renamedEmul.coreState = single.state;
        renamedEmul.tmpDataMem.copyFrom(single.mem);
        
        restoreMappings(single);
        renameInds = single.inds;
    endtask


    task automatic rollbackToStable();
        renamedEmul.setLike(retiredEmul);
        
        if (lateEventInfo.reset) begin
            wrTracker.intWritersR = '{default: -1};
            wrTracker.floatWritersR = '{default: -1};
        end
        else begin
            wrTracker.intWritersR = wrTracker.intWritersC;
            wrTracker.floatWritersR = wrTracker.floatWritersC;
        end
        registerTracker.restore(registerTracker.intMapC, registerTracker.floatMapC);
        renameInds = commitInds;
    endtask


    task automatic redirectRest();
        stageRename1 <= '{default: EMPTY_SLOT};
        markKilledFrontStage(stageRename1);

        if (lateEventInfo.redirect) begin
            rollbackToStable(); // Rename stage
        end
        else if (branchEventInfo.redirect) begin
            rollbackToCheckpoint(); // Rename stage
        end

        if (lateEventInfo.redirect) begin
            flushOooBuffersAll();
            registerTracker.flushAll();
            memTracker.flushAll();
            
            if (lateEventInfo.reset) begin
                sysRegs_N = SYS_REGS_INITIAL;
                renamedEmul.reset();
                retiredEmul.reset();
            end
        end
        else if (branchEventInfo.redirect) begin
            flushOooBuffersPartial(branchEventInfo.op);  
            registerTracker.flush(branchEventInfo.op);
            memTracker.flush(branchEventInfo.op);
        end
        
    endtask
    


    task automatic saveCP(input OpSlot op);
        int intMapR[32] = registerTracker.intMapR;
        int floatMapR[32] = registerTracker.floatMapR;
        BranchCheckpoint cp = new(op, renamedEmul.coreState, renamedEmul.tmpDataMem, wrTracker.intWritersR, wrTracker.floatWritersR, intMapR, floatMapR, renameInds);
        branchCheckpointQueue.push_back(cp);
        branchTargetQueue.push_back('{op.id, 'z});
    endtask
    
    
    task automatic setupOnRename(input OpSlot op);
        AbstractInstruction ins = decAbs(op);
        Word result, target;
        InsDependencies deps;
        Word argVals[3];
        
        // For insMap and mem queues
        argVals = getArgs(renamedEmul.coreState.intRegs, renamedEmul.coreState.floatRegs, ins.sources, parsingMap[ins.fmt].typeSpec);
        // For ins map
        result = computeResult(renamedEmul.coreState, op.adr, ins, renamedEmul.tmpDataMem); // Must be before modifying state

        // For insMap
        deps = getPhysicalArgs(op, registerTracker.intMapR, registerTracker.floatMapR);

        runInEmulator(renamedEmul, op);
        renamedEmul.drain();
        target = renamedEmul.coreState.target; // For insMap


        setWriterR(op); // DB tracking

        if (isStoreMemIns(decAbs(op))) begin // DB
            Word effAdr = calculateEffectiveAddress(ins, argVals);
            Word value = argVals[2];
            memTracker.addStore(op, effAdr, value);
        end
        if (isLoadMemIns(decAbs(op))) begin // DB
            Word effAdr = calculateEffectiveAddress(ins, argVals);
            memTracker.addLoad(op, effAdr, 'x);
        end

        insMap.setResult(op.id, result);
        insMap.setTarget(op.id, target);
        insMap.setDeps(op.id, deps);
        insMap.setArgValues(op.id, argVals);
    endtask


    task automatic renameOp(input OpSlot op);
        setupOnRename(op);

        updateInds(renameInds, op); // Crucial state

        // Crucial state
        registerTracker.reserveInt(op);
        registerTracker.reserveFloat(op);
        
        if (isBranchIns(decAbs(op))) saveCP(op); // Crucial state
        
        insMap.setInds(op.id, renameInds);
       
            lastRenamed = op;
            nRenamed++;
            updateLatestOOO();
    endtask


    task automatic setLateEvent(input OpSlot op);    
        LateEvent evt = getLateEvt(op);

        AbstractInstruction abs = decAbs(op);
        if (abs.def.o == O_halt) $error("halt not implemented");
        
        lateEventInfoWaiting <= '{op, 0, 0, evt.redirect, evt.target};
    endtask


    function automatic OpSlot takeFrontOp();
        OpStatus opSt = oooQueue.pop_front(); // OOO buffer entry release
        InstructionInfo insInfo = insMap.get(opSt.id);
        OpSlot op = '{1, insInfo.id, insInfo.adr, insInfo.bits};
        assert (op.id == opSt.id) else $error("wrong retirement: %p / %p", opSt, op);
        return op;
    endfunction


    task automatic verifyOnCommit(input OpSlot op);
        InstructionInfo info = insMap.get(op.id);
    
        Word trg = retiredEmul.coreState.target; // DB
        Word nextTrg;
        Word bits = fetchInstruction(TMP_getP(), trg); // DB

        assert (trg === op.adr) else $fatal(2, "Commit: mm adr %h / %h", trg, op.adr);
        assert (bits === op.bits) else $fatal(2, "Commit: mm enc %h / %h", bits, op.bits);
        
        if (writesIntReg(op) || writesFloatReg(op)) // DB
            assert (info.actualResult === info.result) else $error(" not matching result. %p, %s", op, disasm(op.bits));
        
        runInEmulator(retiredEmul, op);
        retiredEmul.drain();
        nextTrg = retiredEmul.coreState.target; // DB

        // DB
        if (isBranchIns(decAbs(op))) begin
            assert (branchTargetQueue[0].target === nextTrg) else $error("Mismatch in BQ id = %d, target: %h / %h", op.id, branchTargetQueue[0].target, nextTrg);
        end
    endtask
    

    task automatic commitOp(input OpSlot op);
        verifyOnCommit(op);

        updateInds(commitInds, op); // Crucial

        setWriterC(op); // DB
        
        // Crucial state
        registerTracker.commitInt(op);
        registerTracker.commitFloat(op);
        
        if (isMemOp(op)) memTracker.remove(op); // DB?
        
        // Crucial state
        if (isBranchIns(decAbs(op)))
            retiredTarget <= branchTargetQueue[0].target;
        else if (isSysIns(decAbs(op)))
            retiredTarget <= 'x;
        else
            retiredTarget <= retiredTarget + 4;
        
        if (isStoreIns(decAbs(op))) csq_N.push_back(storeQueue[0]); // Crucial state
        if (isSysIns(decAbs(op))) setLateEvent(op); // Crucial state

        releaseQueues(op); // Crucial state

            lastRetired = op;
            nRetired++;
            updateCommittedOOO();
    endtask

    task automatic releaseQueues(input OpSlot op);
        RobEntry re = rob.pop_front();
        assert (re.op === op) else $error("Not matching op: %p / %p", re.op, op);
        
        if (isBranchIns(decAbs(op))) begin // Br queue entry release
            BranchCheckpoint bce = branchCheckpointQueue.pop_front();
            BranchTargetEntry bte = branchTargetQueue.pop_front();
            assert (bce.op === op) else $error("Not matching op: %p / %p", bce.op, op);
            assert (bte.id === op.id) else $error("Not matching op id: %p / %d", bte, op.id);
        end
        
        if (isLoadIns(decAbs(op))) begin
            LoadQueueEntry lqe = loadQueue.pop_front();
            assert (lqe.op === op) else $error("Not matching op: %p / %p", lqe.op, op);
        end
        
        if (isStoreIns(decAbs(op))) begin // Br queue entry release
            StoreQueueEntry sqe = storeQueue.pop_front();
            assert (sqe.op === op) else $error("Not matching op: %p / %p", sqe.op, op);
        end
    endtask


    function automatic void setWriterR(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        if (hasIntDest(abs)) wrTracker.intWritersR[abs.dest] = op.id;
        if (hasFloatDest(abs)) wrTracker.floatWritersR[abs.dest] = op.id;
        wrTracker.intWritersR[0] = -1;
    endfunction

    function automatic void setWriterC(input OpSlot op);  
        AbstractInstruction abs = decAbs(op);
        if (hasIntDest(abs)) wrTracker.intWritersC[abs.dest] = op.id;
        if (hasFloatDest(abs)) wrTracker.floatWritersC[abs.dest] = op.id;
        wrTracker.intWritersC[0] = -1;
    endfunction



    function automatic void updateInds(ref IndexSet inds, input OpSlot op);
        inds.rename = (inds.rename + 1) % ROB_SIZE;
        if (isBranchIns(decAbs(op))) inds.bq = (inds.bq + 1) % BC_QUEUE_SIZE;
        if (isLoadIns(decAbs(op))) inds.lq = (inds.lq + 1) % LQ_SIZE;
        if (isStoreIns(decAbs(op))) inds.sq = (inds.sq + 1) % SQ_SIZE;
    endfunction


    task automatic updateOOOQ(input OpSlot op);
        const int ind[$] = oooQueue.find_index with (item.id == op.id);
        assert (ind.size() > 0) oooQueue[ind[0]].done = '1; else $error("No such id in OOOQ: %d", op.id);
        putMilestone(op.id, InstructionMap::Complete); 
    endtask



    task automatic execReset();
            insMap.cleanDescs();
    
        //$display("%d, %d (%d : %d)", insMap.content.size(), insMap.indexList.size(), insMap.indexList[0], insMap.indexList[$]);
      
        lateEventInfoWaiting <= '{EMPTY_SLOT, 0, 1, 1, IP_RESET};
        performAsyncEvent(retiredEmul.coreState, IP_RESET, retiredEmul.coreState.target);
    endtask

    task automatic execInterrupt();
        $display(">> Interrupt !!!");
        lateEventInfoWaiting <= '{EMPTY_SLOT, 1, 0, 1, IP_INT};
        retiredEmul.interrupt();
    endtask




    // $$Exec
    task automatic runExec();
        IssueGroup igExec = DEFAULT_ISSUE_GROUP;

        issuedSt1 <= issuedSt0_E;
        igExec = issuedSt1_E;

        execResultsRegular <= '{default: 'x};
        execResultLink <= 'x;
        execResultMem <= 'x;

        foreach (igExec.regular[i])
            if (igExec.regular[i].active) performRegularOp(igExec.regular[i], i);
        if (igExec.branch.active)   execBranch(igExec.branch);
        if (igExec.mem.active) performMemFirst(igExec.mem);

        memOp_A <= igExec.mem;

        memOpPrev <= memOp_E;
        if (memOpPrev_E.active) performMemLater(memOpPrev_E);

        doneOpsRegular <= igExec.regular;
        doneOpBranch <= igExec.branch;
        doneOpMem <= memOpPrev_E;
        doneOpSys <= igExec.sys;
    endtask


    task automatic completeOp(input OpSlot op);            
        if (!op.active) return;
        
        updateOOOQ(op);
            lastCompleted = op;
            nCompleted++;
    endtask
    

    task automatic setBranchTarget(input OpSlot op, input Word trg);
        int ind[$] = branchTargetQueue.find_first_index with (item.id == op.id);
        branchTargetQueue[ind[0]].target = trg;
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
            logic3 ra = registerTracker.checkArgsReady(deps);
            res[i] = ra.and();
        end
        return res;
    endfunction

    function automatic Word3 getPhysicalArgValues(input RegisterTracker tracker, input OpSlot op);
        InsDependencies deps = insMap.get(op.id).deps;
        return getArgValues(tracker, deps);            
    endfunction

    function automatic Word3 getAndVerifyArgs(input OpSlot op);
        Word3 argsP = getPhysicalArgValues(registerTracker, op);
        Word3 argsM = insMap.get(op.id).argValues;
        assert (argsP === argsM) else $error("not equal args %p / %p", argsP, argsM);
        return argsP;
    endfunction;



    task automatic performRegularOp(input OpSlot op, input int index);
        AbstractInstruction abs = decAbs(op);
        Word3 args = getAndVerifyArgs(op);
        Word result = calculateResult(abs, args, op.adr); // !!!!
        
            execResultsRegular[index] <= result;
        writeResult(op, abs, result);
    endtask    

    task automatic performMemFirst(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word3 args = getAndVerifyArgs(op);
        Word adr = calculateEffectiveAddress(abs, args);

        // TODO: compare adr with that in memTracker
        if (isStoreIns(decAbs(op))) updateSQ(op.id, adr, args[2]);

        readInfo <= '{1, adr, 'x};
    endtask

    typedef StoreQueueEntry StoreQueueExtract[$];

    task automatic performMemLater(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word3 args = getAndVerifyArgs(op);

        Word adr = calculateEffectiveAddress(abs, args);

        StoreQueueEntry matchingStores[$] = getMatchingStores(op, adr);
        // Get last (youngest) of the matching stores
        Word memData = (matchingStores.size() != 0) ? matchingStores[$].val : readIn[0];
        Word data = isLoadSysIns(abs) ? getSysReg(args[1]) : memData;
    
        if (matchingStores.size() != 0) begin
          //  $display("SQ forwarding %d->%d", matchingStores[$].op.id, op.id);
        end

            execResultMem <= data;

        writeResult(op, abs, data);
    endtask

    function automatic StoreQueueExtract getMatchingStores(input OpSlot op, input Word adr);  
        // TODO: develop adr overlap check?
        StoreQueueEntry oooMatchingStores[$] = storeQueue.find with (item.adr == adr && isStoreMemIns(decAbs(item.op)) && item.op.id < op.id);
        StoreQueueEntry committedMatchingStores[$] = csq_N.find with (item.adr == adr && isStoreMemIns(decAbs(item.op)) && item.op.id < op.id);
        StoreQueueEntry matchingStores[$] = {committedMatchingStores, oooMatchingStores};
        return matchingStores;
    endfunction


    task automatic setExecEvent(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word3 args = getAndVerifyArgs(op);

        ExecEvent evt = resolveBranch(abs, op.adr, args);

        BranchCheckpoint found[$] = branchCheckpointQueue.find with (item.op.id == op.id);
        branchCP = found[0];
        setBranchTarget(op, evt.redirect ? evt.target : op.adr + 4);

        branchEventInfo <= '{op, 0, 0, evt.redirect, evt.target};
    endtask

    task automatic performLinkOp(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word result = op.adr + 4;

            execResultLink <= result;       
        writeResult(op, abs, result);
    endtask
    
    task automatic execBranch(input OpSlot op);
        setExecEvent(op);
        performLinkOp(op);
    endtask


    function automatic IssueGroup issueFromOpQ(ref OpSlot queue[$:OP_QUEUE_SIZE], input int size, input ReadyVec rv);
        IssueGroup res = DEFAULT_ISSUE_GROUP;

        int maxNum = size > 4 ? 4 : size;
        if (maxNum > queue.size()) maxNum = queue.size(); // Queue may be flushing in this cycle, so possiblre shrinkage is checked here 
    
        for (int i = 0; i < maxNum; i++) begin
            OpSlot op;
            
            if (!rv[i]) break;
            
            op = queue.pop_front();
            assert (op.active) else $fatal(2, "Op from queue is empty!");
            res.num++;
            
            if (isBranchIns(decAbs(op))) begin
                res.branch = op;
                assert (op === T_iqBranch.pop_front()) else $error("wrong");
                break;
            end
            else if (isLoadIns(decAbs(op)) || isStoreIns(decAbs(op))) begin
                res.mem = op;
                assert (op === T_iqMem.pop_front()) else $error("wrong");
                break;
            end
            else if (isSysIns(decAbs(op))) begin
                res.sys = op;
                assert (op === T_iqSys.pop_front()) else $error("wrong");
                break;
            end
            
            assert (op === T_iqRegular.pop_front()) else $error("wrong");
            res.regular[i] = op;
        end
        
        return res;
    endfunction


    task automatic writeResult(input OpSlot op, input AbstractInstruction abs, input Word value);
            return;
        writeResult_Impl(op, abs, value);
    endtask

    task automatic writeResult_N(input OpSlot op, input Word value);
        if (!op.active) return;

        begin
            AbstractInstruction abs = decAbs(op);
                //return;
            writeResult_Impl(op, abs, value);
        end
    endtask

    task automatic writeResult_Impl(input OpSlot op, input AbstractInstruction abs, input Word value);
        Word result = insMap.get(op.id).result;        
        insMap.setActualResult(op.id, value);

        if (writesIntReg(op)) begin
            registerTracker.setReadyInt(op.id);
            registerTracker.writeValueInt(op, value);
        end
        if (writesFloatReg(op)) begin
            registerTracker.setReadyFloat(op.id);
            registerTracker.writeValueFloat(op, value);
        end
    endtask


    function automatic Word getSysReg(input Word adr);
        return sysRegs_N[adr];
    endfunction

    function automatic void setSysReg(input Word adr, input Word val);
        sysRegs_N[adr] = val;
    endfunction



        function automatic Stage_N setActive(input Stage_N s, input logic on, input int ctr);
            Stage_N res = s;
            Word firstAdr = res[0].adr;
            Word baseAdr = res[0].adr & ~(4*FETCH_WIDTH-1);

            if (!on) return EMPTY_STAGE;

            foreach (res[i]) begin
                res[i].active = (((firstAdr/4) % FETCH_WIDTH <= i)) === 1;
                res[i].id = res[i].active ? ctr + i : -1;
                res[i].adr = res[i].active ? baseAdr + 4*i : 'x;
            end

            return res;
        endfunction

        function automatic Stage_N setWords(input Stage_N s, input FetchGroup fg);
            Stage_N res = s;
            foreach (res[i])
                if (res[i].active) res[i].bits = fg[i];
            return res;
        endfunction

    function automatic logic anyActive(input Stage_N s);
        foreach (s[i]) if (s[i].active) return 1;
        return 0;
    endfunction


    function automatic AbstractInstruction decAbs(input OpSlot op);
        if (!op.active || op.id == -1) return DEFAULT_ABS_INS;     
        return insMap.get(op.id).dec;
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


    task automatic registerNewTarget(input int fCtr, input Word target);
        int slotPosition = (target/4) % FETCH_WIDTH;
        Word baseAdr = target & ~(4*FETCH_WIDTH-1);
        for (int i = slotPosition; i < FETCH_WIDTH; i++) begin
            Word adr = baseAdr + 4*i;
            int index = fCtr + i;
            insMap.registerIndex(index);
            putMilestone(index, InstructionMap::GenAddress);
        end
    endtask


    task automatic putMilestone(input int id, input InstructionMap::Milestone kind);
        insMap.putMilestone(id, kind, cycleCtr);
    endtask

    task automatic markKilledFrontStage(ref Stage_N stage);
        foreach (stage[i]) begin
            if (!stage[i].active) continue;
            putMilestone(stage[i].id, InstructionMap::FlushFront);
            insMap.setKilled(stage[i].id);
        end        
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
