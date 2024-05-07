
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;



module Frontend(ref InstructionMap insMap, input EventInfo branchEventInfo, input EventInfo lateEventInfo);

    typedef Word FetchGroup[FETCH_WIDTH];

    int fqSize = 0;

    Stage_N ipStage = EMPTY_STAGE, fetchStage0 = EMPTY_STAGE, fetchStage1 = EMPTY_STAGE;
    Stage_N fetchQueue[$:FETCH_QUEUE_SIZE];

    int fetchCtr = 0;
    OpSlotA stageRename0 = '{default: EMPTY_SLOT};


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
        if (AbstractCore.fetchAllow) begin
            Word target = (ipStage[0].adr & ~(4*FETCH_WIDTH-1)) + 4*FETCH_WIDTH;
            ipStage <= '{0: '{1, -1, target, 'x}, default: EMPTY_SLOT};
            fetchCtr <= fetchCtr + FETCH_WIDTH;
            
            registerNewTarget(fetchCtr + FETCH_WIDTH, target);
        end

        ipStageU = setActive(ipStage, ipStage[0].active & AbstractCore.fetchAllow, fetchCtr);

        fetchStage0 <= ipStageU;
        fetchStage0ua = setWords(fetchStage0, AbstractCore.insIn);
        
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
        if (fqSize > 0 && AbstractCore.renameAllow) begin
            Stage_N fqOut_N = fetchQueue.pop_front();
            foreach (fqOut_N[i]) res[i] = fqOut_N[i];
        end
        
        return res;
    endfunction

   
    always @(posedge AbstractCore.clk) begin
        if (lateEventInfo.redirect || branchEventInfo.redirect)
            redirectFront();
        else
            fetchAndEnqueue();
            
        fqSize <= fetchQueue.size();
    end

endmodule




module IssueQueue
#(
    parameter int SIZE = OP_QUEUE_SIZE,
    parameter int OUT_WIDTH = 1
)
(
                ref InstructionMap insMap,
                input EventInfo branchEventInfo,
                input EventInfo lateEventInfo,
                input OpSlotA inGroup,
                input logic inMask[$size(OpSlotA)],
                
                output OpSlot outGroup[OUT_WIDTH]
);

    typedef logic ReadyVec[SIZE];

    int num = 0;

    OpSlot content[$:SIZE];
    ReadyVec readyVec = '{default: 'z};
    
    OpSlot issued[OUT_WIDTH] = '{default: EMPTY_SLOT};
    
    assign outGroup = issued;
    
    
    always @(posedge AbstractCore.clk) begin

        if (lateEventInfo.redirect || branchEventInfo.redirect)
            flushIq();
        else begin
            writeInput();
        end
        
        issue();

        
        num <= content.size();
        
        readyVec <= getReadyVec_A(content);
    end


    task automatic flushIq();
        if (lateEventInfo.redirect) begin
            flushOpQueueAll();
        end
        else if (branchEventInfo.redirect) begin
            flushOpQueuePartial(branchEventInfo.op);
        end
    endtask


    task automatic flushOpQueueAll();
        while (content.size() > 0) begin
            void'(content.pop_back());
        end
    endtask

    task automatic flushOpQueuePartial(input OpSlot op);
        while (content.size() > 0 && content[$].id > op.id) begin
            void'(content.pop_back());
        end
    endtask

    task automatic writeInput();
        foreach (inGroup[i]) begin
            OpSlot op = inGroup[i];
            if (op.active && inMask[i]) begin
                content.push_back(op);
            end
        end
    endtask

    task automatic issue();
        int n = OUT_WIDTH > num ? num : OUT_WIDTH;
        if (content.size() < n) n = content.size();
        
        issued = '{default: EMPTY_SLOT};
                
        foreach (issued[i])
            if (i < n && readyVec[i])
                issued[i] = tick(content.pop_front());
            else
                break;//issued[i] = EMPTY_SLOT;
    endtask

endmodule



module IssueQueueComplex(
                            ref InstructionMap insMap,
                            input EventInfo branchEventInfo,
                            input EventInfo lateEventInfo,
                            input OpSlotA inGroup
);

    localparam int IN_WIDTH = $size(inGroup);

    typedef logic ReadyVec[OP_QUEUE_SIZE];

    OpSlot T_iqRegular[$:OP_QUEUE_SIZE];
    OpSlot T_iqBranch[$:OP_QUEUE_SIZE];
    OpSlot T_iqMem[$:OP_QUEUE_SIZE];
    OpSlot T_iqSys[$:OP_QUEUE_SIZE];

    ReadyVec opsReadyRegular, opsReadyBranch, opsReadyMem, opsReadySys;

        logic regularMask[IN_WIDTH];
        OpSlot issuedRegular[4];
        OpSlot issuedMem[1];
        OpSlot issuedSys[1];
        OpSlot issuedBranch[1];
        
        IssueGroup ig;
        
        IssueQueue#(.OUT_WIDTH(4)) regularQueue(insMap, branchEventInfo, lateEventInfo, inGroup, regularMask,
                                                issuedRegular);
        IssueQueue#(.OUT_WIDTH(1)) branchQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.branch,
                                                issuedBranch);
        IssueQueue#(.OUT_WIDTH(1)) memQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.mem,
                                                issuedMem);
        IssueQueue#(.OUT_WIDTH(1)) sysQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.sys,
                                                issuedSys);


        assign ig.regular = issuedRegular;
        assign ig.branch = issuedBranch[0];
        assign ig.mem = issuedMem[0];
        assign ig.sys = issuedSys[0];


    task automatic writeToIqs();
        foreach (inGroup[i]) begin
            OpSlot op = inGroup[i];
            if (op.active) begin
                addToIssueQueues(op);
            end
        end
    endtask
    
    typedef struct {
        logic regular[IN_WIDTH];
        logic branch[IN_WIDTH];
        logic mem[IN_WIDTH];
        logic sys[IN_WIDTH];
    } RoutingInfo;
    
    const RoutingInfo DEFAULT_ROUTING_INFO = '{
        regular: '{default: 0},
        branch: '{default: 0},
        mem: '{default: 0},
        sys: '{default: 0}
    };
    
    RoutingInfo routingInfo;
    
    assign routingInfo = routeOps(inGroup); 
    assign regularMask = routingInfo.regular;


    function automatic RoutingInfo routeOps(input OpSlotA gr);
        RoutingInfo res = DEFAULT_ROUTING_INFO;
        
        foreach (gr[i]) begin
            OpSlot op = gr[i]; 
            
            if (isLoadIns(decAbs(op)) || isStoreIns(decAbs(op))) res.mem[i] = 1;
            else if (isSysIns(decAbs(op))) res.sys[i] = 1;
            else if (isBranchIns(decAbs(op))) res.branch[i] = 1;
            else res.regular[i] = 1;
        end
        
        return res;
    endfunction



    task automatic addToIssueQueues(input OpSlot op);    
        if (isLoadIns(decAbs(op)) || isStoreIns(decAbs(op))) T_iqMem.push_back(op);
        else if (isSysIns(decAbs(op))) T_iqSys.push_back(op);
        else if (isBranchIns(decAbs(op))) T_iqBranch.push_back(op);
        else T_iqRegular.push_back(op);
    endtask

    task automatic flushIqs();
        if (lateEventInfo.redirect) begin
            flushOpQueuesAll();
        end
        else if (branchEventInfo.redirect) begin
            flushOpQueuesPartial(branchEventInfo.op);
        end
    endtask


    task automatic flushOpQueuesAll();
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

    task automatic flushOpQueuesPartial(input OpSlot op);
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


    function automatic IssueGroup issueFromQueues();
        IssueGroup res = DEFAULT_ISSUE_GROUP;
        
        int size = AbstractCore.oooLevels_N.iqRegular;
        int maxNum = size > 4 ? 4 : size;
        if (maxNum > T_iqRegular.size()) maxNum = T_iqRegular.size(); // Queue may be flushing in this cycle, so possiblre shrinkage is checked here 
    
        for (int i = 0; i < maxNum; i++) begin
            OpSlot op;
            
            if (!opsReadyRegular[i]) break;
            
            op = T_iqRegular.pop_front();
            
            assert (op.active) else $fatal(2, "Op from queue is empty!");
            //res.num++;
            
            res.regular[i] = op;
        end
        
        if (T_iqSys.size() > 0 && opsReadySys[0]) begin
            res.sys = T_iqSys.pop_front();
        end

        if (T_iqMem.size() > 0 && opsReadyMem[0]) begin
            res.mem = T_iqMem.pop_front();
        end

        if (T_iqBranch.size() > 0 && opsReadyBranch[0]) begin
            res.branch = T_iqBranch.pop_front();
        end       
        
        return res;
    endfunction


    function automatic logic3 checkArgsReady_A(input InsDependencies deps);//, input logic readyInt[N_REGS_INT], input logic readyFloat[N_REGS_FLOAT]);
        logic3 res;
        foreach (deps.types[i])
            case (deps.types[i])
                SRC_ZERO:  res[i] = 1;
                SRC_CONST: res[i] = 1;
                SRC_INT:   res[i] = AbstractCore.intRegsReadyV[deps.sources[i]];
                SRC_FLOAT: res[i] = AbstractCore.floatRegsReadyV[deps.sources[i]];
            endcase      
        return res;
    endfunction

    function automatic ReadyVec getReadyVec_A(input OpSlot iq[$:OP_QUEUE_SIZE]);
        ReadyVec res = '{default: 'z};
        foreach (iq[i]) begin
            InsDependencies deps = insMap.get(iq[i].id).deps;
            logic3 ra = checkArgsReady_A(deps);
            res[i] = ra.and();
        end
        return res;
    endfunction


    task automatic updateReadyVecs_A();        
        opsReadyRegular <= getReadyVec_A(T_iqRegular);
        opsReadyBranch <= getReadyVec_A(T_iqBranch);
        opsReadyMem <= getReadyVec_A(T_iqMem);
        opsReadySys <= getReadyVec_A(T_iqSys);

        AbstractCore.oooLevels_N.iqRegular <= T_iqRegular.size();
        AbstractCore.oooLevels_N.iqBranch <= T_iqBranch.size();
        AbstractCore.oooLevels_N.iqMem <= T_iqMem.size();
        AbstractCore.oooLevels_N.iqSys <= T_iqSys.size();
    endtask    


    always @(posedge AbstractCore.clk) begin
        if (lateEventInfo.redirect || branchEventInfo.redirect)
            flushIqs();
        else
            writeToIqs();
       
        begin
            automatic IssueGroup igIssue = issueFromQueues();

            AbstractCore.theExecBlock.issuedSt0 <= tickIG(igIssue);
            markIssued(igIssue);
            updateReadyVecs_A();
        end
    end
    
    function automatic void markIssued(input IssueGroup ig);
        foreach (ig.regular[i]) markOpIssued(ig.regular[i]);
        markOpIssued(ig.branch);
        markOpIssued(ig.mem);
        markOpIssued(ig.sys);
    endfunction
    
    function automatic void markOpIssued(input OpSlot op);
        if (!op.active || op.id == -1) return;
        
        putMilestone(op.id, InstructionMap::Issue);
    endfunction
    
endmodule



module ExecBlock(ref InstructionMap insMap);

    IssueGroup issuedSt0 = DEFAULT_ISSUE_GROUP, issuedSt1 = DEFAULT_ISSUE_GROUP;
    IssueGroup issuedSt0_E, issuedSt1_E;


    OpSlot memOp_A = EMPTY_SLOT, memOpPrev = EMPTY_SLOT;
    OpSlot memOp_E, memOpPrev_E;
    
    OpSlot doneOpsRegular[4] = '{default: EMPTY_SLOT};
    OpSlot doneOpBranch = EMPTY_SLOT, doneOpMem = EMPTY_SLOT, doneOpSys = EMPTY_SLOT;

    OpSlot doneOpsRegular_E[4];
    OpSlot doneOpBranch_E, doneOpMem_E, doneOpSys_E;

    Word execResultsRegular[4] = '{'x, 'x, 'x, 'x};
    Word execResultLink = 'x, execResultMem = 'x;


    // Exec process
    always @(posedge AbstractCore.clk) begin
        begin
            AbstractCore.readInfo <= EMPTY_WRITE_INFO;
            AbstractCore.branchEventInfo <= EMPTY_EVENT_INFO;
            runExec();
        end
    end
    
    assign memOp_E = eff(memOp_A);
    assign memOpPrev_E = eff(memOpPrev);

    assign issuedSt0_E = effIG(issuedSt0);
    assign issuedSt1_E = effIG(issuedSt1);

    assign doneOpsRegular_E = effA(doneOpsRegular);
    assign doneOpBranch_E = eff(doneOpBranch);
    assign doneOpMem_E = eff(doneOpMem);
    assign doneOpSys_E = eff(doneOpSys);


    task automatic runExec();
        IssueGroup igExec = DEFAULT_ISSUE_GROUP;

        issuedSt1 <= tickIG(issuedSt0);
        igExec = issuedSt1_E;

        execResultsRegular <= '{default: 'x};
        execResultLink <= 'x;
        execResultMem <= 'x;

        foreach (igExec.regular[i])
            if (igExec.regular[i].active) performRegularOp(igExec.regular[i], i);
        if (igExec.branch.active)   execBranch(igExec.branch);
        if (igExec.mem.active) performMemFirst(igExec.mem);

        memOp_A <= tick(igExec.mem);

        memOpPrev <= tick(memOp_E);
        if (memOpPrev_E.active) performMemLater(memOpPrev_E);

        doneOpsRegular <= tickA(issuedSt1.regular);
        doneOpBranch <= tick(issuedSt1.branch);
        doneOpMem <= tick(memOpPrev);
        doneOpSys <= tick(issuedSt1.sys);
    endtask


    task automatic setBranchTarget(input OpSlot op, input Word trg);
        int ind[$] = AbstractCore.branchTargetQueue.find_first_index with (item.id == op.id);
        AbstractCore.branchTargetQueue[ind[0]].target = trg;
    endtask

    task automatic updateSQ(input InsId id, input Word adr, input Word val);
        int ind[$] = AbstractCore.storeQueue.find_first_index with (item.op.id == id);
        AbstractCore.storeQueue[ind[0]].adr = adr;
        AbstractCore.storeQueue[ind[0]].val = val;
    endtask
    

    function automatic Word3 getPhysicalArgValues(input RegisterTracker tracker, input OpSlot op);
        InsDependencies deps = insMap.get(op.id).deps;
        return getArgValues(tracker, deps);            
    endfunction

    function automatic Word3 getAndVerifyArgs(input OpSlot op);
        Word3 argsP = getPhysicalArgValues(AbstractCore.registerTracker, op);
        Word3 argsM = insMap.get(op.id).argValues;
        
        if (argsP !== argsM) insMap.setArgError(op.id);
        
        return argsP;
    endfunction;



    task automatic performRegularOp(input OpSlot op, input int index);
        AbstractInstruction abs = decAbs(op);
        Word3 args = getAndVerifyArgs(op);
        Word result = calculateResult(abs, args, op.adr); // !!!!
        
        execResultsRegular[index] <= result;
    endtask    

    task automatic performMemFirst(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word3 args = getAndVerifyArgs(op);
        Word adr = calculateEffectiveAddress(abs, args);

        // TODO: compare adr with that in memTracker
        if (isStoreIns(decAbs(op))) begin
            updateSQ(op.id, adr, args[2]);
            
            if (isStoreMemIns(decAbs(op))) begin
                checkStoreValue(op.id, adr, args[2]);
                
                putMilestone(op.id, InstructionMap::WriteMemAddress);
                putMilestone(op.id, InstructionMap::WriteMemValue);
            end
        end

        AbstractCore.readInfo <= '{1, adr, 'x};
    endtask

    typedef StoreQueueEntry StoreQueueExtract[$];

    task automatic performMemLater(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word3 args = getAndVerifyArgs(op);

        Word adr = calculateEffectiveAddress(abs, args);

        StoreQueueEntry matchingStores[$] = getMatchingStores(op, adr);
        // Get last (youngest) of the matching stores
        Word memData = (matchingStores.size() != 0) ? matchingStores[$].val : AbstractCore.readIn[0];
        Word data = isLoadSysIns(abs) ? getSysReg(args[1]) : memData;
    
        if (matchingStores.size() != 0) begin
          //  $display("SQ forwarding %d->%d", matchingStores[$].op.id, op.id);
        end

        execResultMem <= data;
    endtask

    function automatic StoreQueueExtract getMatchingStores(input OpSlot op, input Word adr);  
        // TODO: develop adr overlap check?
        StoreQueueEntry oooMatchingStores[$] = AbstractCore.storeQueue.find with (item.adr == adr && isStoreMemIns(decAbs(item.op)) && item.op.id < op.id);
        StoreQueueEntry committedMatchingStores[$] = AbstractCore.csq_N.find with (item.adr == adr && isStoreMemIns(decAbs(item.op)) && item.op.id < op.id);
        StoreQueueEntry matchingStores[$] = {committedMatchingStores, oooMatchingStores};
        return matchingStores;
    endfunction


    task automatic setExecEvent(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word3 args = getAndVerifyArgs(op);

        ExecEvent evt = resolveBranch(abs, op.adr, args);

        BranchCheckpoint found[$] = AbstractCore.branchCheckpointQueue.find with (item.op.id == op.id);
        AbstractCore.branchCP = found[0];
        setBranchTarget(op, evt.redirect ? evt.target : op.adr + 4);

        AbstractCore.branchEventInfo <= '{op, 0, 0, evt.redirect, evt.target};
    endtask

    task automatic performLinkOp(input OpSlot op);
        AbstractInstruction abs = decAbs(op);
        Word result = op.adr + 4;

        execResultLink <= result;       
    endtask
    
    task automatic execBranch(input OpSlot op);
        setExecEvent(op);
        performLinkOp(op);
    endtask

endmodule



module ReorderBuffer
#(
    parameter int WIDTH = 4
)
(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpSlotA inGroup,
    output OpSlotA outGroup
);

    localparam int DEPTH = ROB_SIZE/WIDTH;

    int startPointer = 0, endPointer = 0;
    int size;
    logic allow;

    typedef struct {
        InsId id;
        logic completed;
    } OpRecord;
    
    const OpRecord EMPTY_RECORD = '{id: -1, completed: 'x};
    typedef OpRecord OpRecordA[WIDTH];

    typedef struct {
        OpRecord records[WIDTH];
    } Row;

    const Row EMPTY_ROW = '{records: '{default: EMPTY_RECORD}};

    Row outRow = EMPTY_ROW;
    Row array[DEPTH] = '{default: EMPTY_ROW};
    
    InsId lastIn = -1, lastRestored = -1, lastOut = -1;
    
    assign size = (endPointer - startPointer + 2*DEPTH) % (2*DEPTH);
    assign allow = (size < DEPTH - 3);
    
    task automatic flushArrayAll();
            lastRestored = lateEventInfo.op.id;
        
        foreach (array[r]) begin
            OpRecord row[WIDTH] = array[r].records;
            foreach (row[c])
                putMilestone(row[c].id, InstructionMap::RobFlush);
        end
               
            endPointer = startPointer;
            array = '{default: EMPTY_ROW};
    endtask
    
    
    task automatic flushArrayPartial();
        logic clear = 0;
        int causingGroup = insMap.get(branchEventInfo.op.id).inds.renameG;
        int causingSlot = insMap.get(branchEventInfo.op.id).slot;
        InsId causingId = branchEventInfo.op.id;
        int p = startPointer;
        
            lastRestored = branchEventInfo.op.id;
            
        for (int i = 0; i < DEPTH; i++) begin
            OpRecord row[WIDTH] = array[p % DEPTH].records;
            for (int c = 0; c < WIDTH; c++) begin
                if (row[c].id == causingId) endPointer = (p+1) % (2*DEPTH);
                if (row[c].id > causingId) begin
                    putMilestone(row[c].id, InstructionMap::RobFlush);
                    array[p % DEPTH].records[c] = EMPTY_RECORD;
                end
            end
            
            p++;
        end

    endtask
    
    
    task automatic markOpCompleted(input OpSlot op); 
        InsId id = op.id;
        
        if (!op.active) return;
        
        for (int r = 0; r < DEPTH; r++)
            for (int c = 0; c < WIDTH; c++) begin
                if (array[r].records[c].id == id)
                    array[r].records[c].completed = 1;
            end
        
    endtask
    
    
    task automatic markCompleted();        
        foreach (theExecBlock.doneOpsRegular_E[i]) begin
            markOpCompleted(theExecBlock.doneOpsRegular_E[i]);
        end
        
        markOpCompleted(theExecBlock.doneOpBranch_E);
        markOpCompleted(theExecBlock.doneOpMem_E);
        markOpCompleted(theExecBlock.doneOpSys_E);
    endtask
    
    
    
    always @(posedge AbstractCore.clk) begin

        if (AbstractCore.interrupt || AbstractCore.reset || AbstractCore.lateEventInfoWaiting.redirect || lateEventInfo.redirect)
            outRow <= EMPTY_ROW;
        else if (frontCompleted()) begin
            automatic Row row = array[startPointer % DEPTH];
                lastOut = getLastOut(lastOut, array[startPointer % DEPTH].records);
            
            foreach (row.records[i])
                putMilestone(row.records[i].id, InstructionMap::RobExit);
                
            outRow <= row;

            array[startPointer % DEPTH] = EMPTY_ROW;
            startPointer = (startPointer+1) % (2*DEPTH);
            
        end
        else
            outRow <= EMPTY_ROW;

        markCompleted();

        if (lateEventInfo.redirect) begin
            flushArrayAll();
        end
        else if (branchEventInfo.redirect) begin
            flushArrayPartial();
        end
        else if (anyActive(inGroup))
            add(inGroup);

    end


    function automatic OpRecordA makeRecord(input OpSlotA ops);
        OpRecordA res = '{default: EMPTY_RECORD};
        foreach (ops[i])
            res[i] = ops[i].active ? '{ops[i].id, 0} : '{-1, 'x};   
        return res;
    endfunction


    task automatic add(input OpSlotA in);
        OpRecordA rec = makeRecord(in);
            lastIn = getLastOut(lastIn, makeRecord(in));
            
        array[endPointer % DEPTH].records = makeRecord(in);
        endPointer = (endPointer+1) % (2*DEPTH);
        
            foreach (rec[i])
                putMilestone(rec[i].id, InstructionMap::RobEnter);
    endtask
    
    function automatic logic frontCompleted();
        OpRecordA records = array[startPointer % DEPTH].records;
        if (endPointer == startPointer) return 0;

        foreach (records[i])
            if (records[i].id != -1 && records[i].completed === 0)
                return 0;
        
        return 1;
    endfunction
    
    
        function automatic InsId getLastOut(input InsId prev, input OpRecordA recs);
            InsId tmp = prev;
            
            foreach (recs[i])
                if  (recs[i].id != -1)
                    tmp = recs[i].id;
                    
            return tmp;
        endfunction
    
endmodule



module StoreQueue
#(
    parameter logic IS_LOAD_QUEUE = 0,
    parameter logic IS_BRANCH_QUEUE = 0,
    
    parameter int SIZE = 32
)
(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpSlotA inGroup
);

    localparam logic IS_STORE_QUEUE = !IS_LOAD_QUEUE && !IS_BRANCH_QUEUE;

    typedef struct {
        InsId id;
    } QueueEntry;

    const QueueEntry EMPTY_ENTRY = '{-1};

    int startPointer = 0, endPointer = 0, drainPointer = 0;
    int size;
    logic allow;
    
    assign size = (endPointer - startPointer + 2*SIZE) % (2*SIZE);
    assign allow = (size < SIZE - 3*RENAME_WIDTH);

    QueueEntry content[SIZE] = '{default: EMPTY_ENTRY};
    
    
    task automatic flushPartial();
        InsId causingId = branchEventInfo.op.id;
        
        int p = startPointer;
        
        endPointer = startPointer;
        
        for (int i = 0; i < SIZE; i++) begin
            if (content[p % SIZE].id > causingId)
                content[p % SIZE] = EMPTY_ENTRY; 
            else if (content[p % SIZE].id == -1)
                break;
            else
                endPointer = (p+1) % (2*SIZE);   
            p++;
        end
    endtask
    
    
    task automatic advance();
        while (content[startPointer % SIZE].id != -1 && content[startPointer % SIZE].id <= AbstractCore.lastRetired.id) begin
            content[startPointer % SIZE] = EMPTY_ENTRY;
            startPointer = (startPointer+1) % (2*SIZE);
        end
    endtask
    

    
    always @(posedge AbstractCore.clk) begin
        advance();
    
        if (lateEventInfo.redirect) begin
            content = '{default: EMPTY_ENTRY};
            endPointer = startPointer;
        end
        else if (branchEventInfo.redirect) begin
           flushPartial(); 
        end
        else if (anyActive(inGroup)) begin
            // put ops which are stores
            foreach (inGroup[i]) begin
                automatic logic applies = 
                                  IS_LOAD_QUEUE && isLoadIns(decAbs(inGroup[i]))
                              ||  IS_BRANCH_QUEUE && isBranchIns(decAbs(inGroup[i]))
                              ||  IS_STORE_QUEUE && isStoreIns(decAbs(inGroup[i]));
            
                if (applies) begin
                    content[endPointer % SIZE].id = inGroup[i].id;
                    endPointer = (endPointer+1) % (2*SIZE);
                end
            end
            
        end
    end

endmodule


