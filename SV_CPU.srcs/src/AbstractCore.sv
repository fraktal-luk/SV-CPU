
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


    localparam int FETCH_QUEUE_SIZE = 8;
    localparam int OP_QUEUE_SIZE = 24;
    localparam int OOO_QUEUE_SIZE = 120;
    localparam int BC_QUEUE_SIZE = 64;


    InstructionMap insMap = new();


    typedef OpSlot OpSlotA[FETCH_WIDTH];

    typedef struct {
        logic active;
        int ctr;
        Word baseAdr;
        logic mask[FETCH_WIDTH];
        Word words[FETCH_WIDTH];
    } Stage;


    class BranchCheckpoint;
    
        function new(input OpSlot op, input CpuState state, input SimpleMem mem, input int intWr[32], input int floatWr[32]);
            this.op = op;
            this.state = state;
            this.mem = new();
            this.mem.copyFrom(mem);
            this.intWriters = intWr;
            this.floatWriters = floatWr;
        endfunction

        OpSlot op;
        CpuState state;
        SimpleMem mem;
        int intWriters[32];
        int floatWriters[32];
    endclass
    
 
    
    const Stage EMPTY_STAGE = '{'0, -1, 'x, '{default: 0}, '{default: 'x}};


    typedef enum { SRC_CONST, SRC_INT, SRC_FLOAT
    } SourceType;
    
    typedef struct {
        int sources[3];
        SourceType types[3];
    } InsDependencies;
    
        InsDependencies lastDeps;

    typedef struct {
        int id;
        logic done;
    }
    OpStatus;

        InstructionInfo latestOOO[20], committedOOO[20];


    typedef struct {
        int num;
        OpSlot regular[4];
        OpSlot branch;
        OpSlot mem;
        OpSlot sys;
    } IssueGroup;
    
    const IssueGroup DEFAULT_ISSUE_GROUP = '{num: 0, regular: '{default: EMPTY_SLOT}, branch: EMPTY_SLOT, mem: EMPTY_SLOT, sys: EMPTY_SLOT};

    typedef Word FetchGroup[FETCH_WIDTH];
    
    int fetchCtr = 0;
    int fqSize = 0, oqSize = 0, oooqSize = 0, bcqSize = 0;
    int insMapSize = 0, renamedDivergence = 0, nRenamed = 0, nCompleted = 0, nRetired = 0, oooqCompletedNum = 0, frontCompleted = 0;

    logic fetchAllow;
    logic resetPrev = 0, intPrev = 0;
    logic branchRedirect = 0, eventRedirect = 0;
    Word branchTarget = 'x, eventTarget = 'x;
    OpSlot branchOp = EMPTY_SLOT, eventOp = EMPTY_SLOT;
    BranchCheckpoint branchCP;
    
    Stage ipStage = EMPTY_STAGE, fetchStage0 = EMPTY_STAGE, fetchStage1 = EMPTY_STAGE;
    Stage fetchQueue[$:FETCH_QUEUE_SIZE];

    OpSlotA nextStageA = '{default: EMPTY_SLOT};
    OpSlot opQueue[$:OP_QUEUE_SIZE];
    OpSlot memOp = EMPTY_SLOT, memOpPrev = EMPTY_SLOT, sysOp = EMPTY_SLOT, sysOpPrev = EMPTY_SLOT, lastRenamed = EMPTY_SLOT, lastCompleted = EMPTY_SLOT, lastRetired = EMPTY_SLOT;
    IssueGroup issuedSt0 = DEFAULT_ISSUE_GROUP, issuedSt0_C = DEFAULT_ISSUE_GROUP, issuedSt1 = DEFAULT_ISSUE_GROUP, issuedSt1_C = DEFAULT_ISSUE_GROUP;

    OpStatus oooQueue[$:OOO_QUEUE_SIZE];
    
    BranchCheckpoint branchCheckpointQueue[$:BC_QUEUE_SIZE];
    
    CpuState renamedState, execState, retiredState;
    SimpleMem renamedMem = new(), execMem = new(), retiredMem = new();
    
    InsId intWritersR[32] = '{default: -1}, floatWritersR[32] = '{default: -1};
    InsId intWritersC[32] = '{default: -1}, floatWritersC[32] = '{default: -1};


    string lastRenamedStr, lastCompletedStr, lastRetiredStr, oooqStr;
    logic cmp0, cmp1;
    Word cmpw0, cmpw1, cmpw2, cmpw3;


    always @(posedge clk) begin
        resetPrev <= reset;
        intPrev <= interrupt;
        sig <= 0;
        wrong <= 0;

        readReq[0] = 0;
        readAdr[0] = 'x;
        writeReq = 0;
        writeAdr = 'x;
        writeOut = 'x;

        branchOp <= EMPTY_SLOT;
        branchRedirect <= 0;
        branchTarget <= 'x;

        eventOp <= EMPTY_SLOT;
        eventRedirect <= 0;
        eventTarget <= 'x;

        advanceOOOQ();
  
        issuedSt0 <= DEFAULT_ISSUE_GROUP;
        issuedSt1 <= issuedSt0;

        if (resetPrev | intPrev | branchRedirect | eventRedirect) begin
            performRedirect();
        end
        else begin
            fetchAndEnqueue();

            writeToOpQ(nextStageA);
            writeToOOOQ(nextStageA);

            memOp <= EMPTY_SLOT;
            memOpPrev <= memOp;

            sysOp <= EMPTY_SLOT;
            if (!sysOpPrev.active) sysOpPrev <= sysOp;

            if (reset) begin
                execReset();
            end
            else if (interrupt) begin
                execInterrupt();
            end
            else begin
                automatic IssueGroup igIssue = DEFAULT_ISSUE_GROUP, igExec = DEFAULT_ISSUE_GROUP;// = issuedSt0;
            
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
            
            end

        end
        
        fqSize <= fetchQueue.size();
        oqSize <= opQueue.size();
        oooqSize <= oooQueue.size();
        bcqSize <= branchCheckpointQueue.size();
        frontCompleted <= countFrontCompleted();
        
        begin
            automatic OpStatus oooqDone[$] = (oooQueue.find with (item.done == 1));
            oooqCompletedNum <= oooqDone.size();
            assert (oooqDone.size() <= 4) else $error("How 5?");
        end
        
            insMapSize = insMap.size();
            $swrite(oooqStr, "%p", oooQueue);        
    end


    assign lastRenamedStr = disasm(lastRenamed.bits);
    assign lastCompletedStr = disasm(lastCompleted.bits);
    assign lastRetiredStr = disasm(lastRetired.bits);

     
        string bqStr;
        always @(posedge clk) begin
            automatic int ids[$];
            foreach (branchCheckpointQueue[i]) ids.push_back(branchCheckpointQueue[i].op.id);
            $swrite(bqStr, "%p", ids);
        end

    assign fetchAllow = fetchQueueAccepts(fqSize);
    assign insAdr = ipStage.baseAdr;


    function logic fetchQueueAccepts(input int k);
        return k <= FETCH_QUEUE_SIZE - 3 ? '1 : '0;
    endfunction
    
    // TODO
    function logic bcQueueAccepts(input int k);
        //return k <= FETCH_QUEUE_SIZE - 3 ? '1 : '0;
        $fatal(2, "not implemented");
    endfunction

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
        updateOOOQ(op);
        lastCompleted = op;
        nCompleted++;
    endtask

    task automatic flushAll();
        opQueue.delete();
        oooQueue.delete();
        branchCheckpointQueue.delete();
    endtask
    
    task automatic flushPartial(input OpSlot op);
        while (opQueue.size() > 0 && opQueue[$].id > op.id) opQueue.pop_back();
        while (oooQueue.size() > 0 && oooQueue[$].id > op.id) oooQueue.pop_back();    
        while (branchCheckpointQueue.size() > 0 && branchCheckpointQueue[$].op.id > op.id) branchCheckpointQueue.pop_back();    
    endtask

    task automatic performRedirect();
        if (resetPrev) TMP_reset();
        else if (intPrev) TMP_interrupt();

        if (eventRedirect || intPrev || resetPrev) begin
            ipStage <= '{'1, -1, eventTarget, '{default: '0}, '{default: 'x}};
        end
        else if (branchRedirect) begin
            ipStage <= '{'1, -1, branchTarget, '{default: '0}, '{default: 'x}};
        end
        else $fatal("Should never get here");

        if (eventRedirect || intPrev || resetPrev) begin
            renamedState = retiredState;
            renamedMem.copyFrom(retiredMem);
            execState = retiredState;
            execMem.copyFrom(retiredMem);
            
            intWritersR = '{default: -1};
            floatWritersR = '{default: -1};
            renamedDivergence = 0;
        end
        else if (branchRedirect) begin
            BranchCheckpoint single = branchCP;

            renamedState = single.state;
            renamedMem.copyFrom(single.mem);
            execState = single.state;
            execMem.copyFrom(single.mem);
            
            intWritersR = single.intWriters;
            clearStableWriters(intWritersR, lastRetired.id);
            floatWritersR = single.floatWriters;
            clearStableWriters(floatWritersR, lastRetired.id);

            renamedDivergence = insMap.get(branchOp.id).divergence;
        end

        // Clear stages younger than activated redirection
        fetchStage0 <= EMPTY_STAGE;
        fetchStage1 <= EMPTY_STAGE;
        fetchQueue.delete();
        
        nextStageA <= '{default: EMPTY_SLOT};
        
        if (eventRedirect || intPrev || resetPrev) begin
            flushAll();
        end
        else if (branchRedirect) begin
            flushPartial(branchOp);      
        end

        issuedSt0 <= DEFAULT_ISSUE_GROUP;
        issuedSt1 <= DEFAULT_ISSUE_GROUP;
    
        memOp <= EMPTY_SLOT;
        memOpPrev <= EMPTY_SLOT;
        sysOp <= EMPTY_SLOT;
        sysOpPrev <= EMPTY_SLOT;

        if (resetPrev) begin
            renamedState = initialState(IP_RESET);
            renamedMem.reset();

            execState = initialState(IP_RESET);
            execMem.reset();

            retiredState = initialState(IP_RESET);
            retiredMem.reset();
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

        if (fqSize > 0 && oqSize < OP_QUEUE_SIZE - 2*FETCH_WIDTH) begin
            Stage toRename = fetchQueue.pop_front();
            OpSlotA toRenameA = makeOpA(toRename);
            
            mapStageAtRename(toRenameA);
            
            foreach (toRenameA[i])
                if (toRenameA[i].active) begin
                    OpSlot currentOp = toRenameA[i];
                    AbstractInstruction ins = decodeAbstract(currentOp.bits);
                    Word result, target;

                    if (currentOp.adr != renamedState.target) renamedDivergence++;
                    result = computeResult(renamedState, currentOp.adr, ins, renamedMem); // Must be before modifying state
                    performAt(renamedState, renamedMem, currentOp);
                    target = renamedState.target;

                    if (isBranchOp(currentOp)) begin
                        BranchCheckpoint cp = new(currentOp, renamedState, renamedMem, intWritersR, floatWritersR);
                        branchCheckpointQueue.push_back(cp);
                    end
                    
                    lastRenamed = currentOp;
                    nRenamed++;
                    
                    insMap.setDivergence(currentOp.id, renamedDivergence);
                    insMap.setResult(currentOp.id, result);
                    insMap.setTarget(currentOp.id, target);
                    
                        updateLatestOOO();
                end

            nextStageA <= toRenameA;
        end
        else begin
            nextStageA <= '{default: EMPTY_SLOT};
        end
        
    endtask


    function automatic InsDependencies getArgProducers(input OpSlot op);
        int sources[3] = '{-1, -1, -1};
        SourceType types[3] = '{SRC_CONST, SRC_CONST, SRC_CONST}; 
        
        AbstractInstruction abs = decodeAbstract(op.bits);
        string typeSpec = parsingMap[abs.fmt].typeSpec;
        
        foreach (sources[i]) begin
            if (typeSpec[i + 2] == "i") begin
                sources[i] = intWritersR[abs.sources[i]];
                types[i] = SRC_INT;
            end
            else if (typeSpec[i + 2] == "f") begin
                sources[i] = floatWritersR[abs.sources[i]];
                types[i] = SRC_FLOAT;
            end
        end
        
        return '{sources, types};
    endfunction

    task automatic mapOpAtRename(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        
        lastDeps <= getArgProducers(op);
        
        if (writesIntReg(op)) intWritersR[abs.dest] = op.id;
        if (writesFloatReg(op)) floatWritersR[abs.dest] = op.id;
        intWritersR[0] = -1;            
    endtask

    task automatic mapOpAtCommit(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        if (writesIntReg(op)) intWritersC[abs.dest] = op.id;
        if (writesFloatReg(op)) floatWritersC[abs.dest] = op.id;
        intWritersC[0] = -1;    
        
        clearStableWriters(intWritersR, op.id);
        clearStableWriters(floatWritersR, op.id);        
    endtask

    task automatic mapStageAtRename(input OpSlotA stA);
        foreach (stA[i]) begin
            if (stA[i].active) begin
                mapOpAtRename(stA[i]);
            end
        end 
    endtask

    function automatic void clearStableWriters(ref int arr[32], input int stable);
        foreach (arr[i]) if (arr[i] <= stable) arr[i] = -1;
    endfunction



    task automatic execReset();    
        eventTarget <= IP_RESET;

        performAsyncEvent(renamedState, IP_RESET);
        performAsyncEvent(execState, IP_RESET);
        performAsyncEvent(retiredState, IP_RESET);  
    endtask

    task automatic execInterrupt();
        $display(">> Interrupt !!!");
        eventTarget <= IP_INT;

        performAsyncEvent(renamedState, IP_INT);
        performAsyncEvent(execState, IP_INT);
        performAsyncEvent(retiredState, IP_INT);
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
        branchOp <= op;
        branchTarget <= evt.target;
        branchRedirect <= evt.redirect;
    endtask

    task automatic performBranch(ref CpuState state, input OpSlot op);
        setBranch(state, op);
        performLink(state, op);
    endtask

    

    task automatic performRegularOp(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        Word3 args = getArgs(state.intRegs, state.floatRegs, abs.sources, parsingMap[abs.fmt].typeSpec);
        Word result = (abs.def.o == O_sysLoad) ? state.sysRegs[args[1]] : calculateResult(abs, args, op.adr);

        if (writesIntReg(op)) writeIntReg(state, abs.dest, result);
        if (writesFloatReg(op)) writeFloatReg(state, abs.dest, result);
        
        state.target = op.adr + 4;
    endtask    

    
    task automatic performMemFirst(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        Word3 args = getArgs(state.intRegs, state.floatRegs, abs.sources, parsingMap[abs.fmt].typeSpec);
        Word adr = calculateEffectiveAddress(abs, args);

        // TODO: make struct, unpack at assigment to ports
        readReq[0] <= '1;
        readAdr[0] <= adr;
        memOp <= op;
        
        if (isStoreMemOp(op)) begin
            // TODO: make struct, unpack at assigment to ports 
            writeReq = 1;
            writeAdr = adr;
            writeOut = args[2];
        end
    endtask

    task automatic performMemLater(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);

        if (writesIntReg(op)) writeIntReg(state, abs.dest, readIn[0]);
        if (writesFloatReg(op)) writeFloatReg(state, abs.dest, readIn[0]);
        
        state.target = op.adr + 4;
    endtask

    task automatic performMemAll(ref CpuState state, input OpSlot op, ref SimpleMem mem);
        AbstractInstruction abs = decodeAbstract(op.bits);
        Word3 args = getArgs(state.intRegs, state.floatRegs, abs.sources, parsingMap[abs.fmt].typeSpec);

        Word adr = calculateEffectiveAddress(abs, args);
        Word result = getLoadValue(abs, adr, mem, state);
        
        if (isStoreMemOp(op)) mem.storeW(adr, args[2]);
        if (writesIntReg(op)) writeIntReg(state, abs.dest, result);
        if (writesFloatReg(op)) writeFloatReg(state, abs.dest, result);
        
        state.target = op.adr + 4;
    endtask

    task automatic performSysStore(ref CpuState state, input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        Word3 args = getArgs(state.intRegs, state.floatRegs, abs.sources, parsingMap[abs.fmt].typeSpec);

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


    task automatic performAt(ref CpuState state, ref SimpleMem mem, input OpSlot op);
        if (isBranchOp(op)) performBranch(state, op);
        else if (isMemOp(op)) performMemAll(state, op, mem);
        else if (isSysOp(op)) performSys(state, op);
        else performRegularOp(state, op);
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
    endtask

    task automatic writeToOOOQ(input OpSlotA sa);
        foreach (sa[i]) if (sa[i].active) oooQueue.push_back('{sa[i].id, 0});
    endtask

    task automatic updateOOOQ(input OpSlot op);
        const int ind[$] = oooQueue.find_index with (item.id == op.id);
        assert (ind.size() > 0) oooQueue[ind[0]].done = '1; else $error("No such id in OOOQ: %d", op.id); 
    endtask

    task automatic advanceOOOQ();
        if (eventRedirect || interrupt || reset) return;
    
        while (oooQueue.size() > 0 && oooQueue[0].done == 1) begin
            OpStatus opSt = oooQueue.pop_front(); // OOO buffer entry release
            
            InstructionInfo insInfo = insMap.get(opSt.id);//insMap[opSt.id];
            OpSlot op = '{1, insInfo.id, insInfo.adr, insInfo.bits};
            assert (op.id == opSt.id) else $error("wrong retirement: %p / %p", opSt, op);

            mapOpAtCommit(op);
            TMP_commit(op);
            
            // Actual execution of ops which must be done after Commit
            if (isSysOp(op)) begin
                 setLateEvent(execState, op);
                 performSys(execState, op);
            end

            performAt(retiredState, retiredMem, op);
        
            if (isBranchOp(op)) begin // Br queue entry release
                branchCheckpointQueue.pop_front();
            end
        
            lastRetired = op;
            nRetired++;
            
                updateCommittedOOO();
            
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
                    break;
                end
                else if (isMemOp(op)) begin
                    res.mem = op;
                    break;
                end
                else if (isSysOp(op)) begin
                    res.sys = op;
                    break;
                end
                
                res.regular[i] = op;
            end
        end
        
        return res;
    endfunction

    task automatic setLateEvent(ref CpuState state, input OpSlot op);    
        AbstractInstruction abs = decodeAbstract(op.bits);
        LateEvent evt = getLateEvent(op, abs, state.sysRegs[2], state.sysRegs[3]);

        eventOp <= op;
        eventTarget <= evt.target;
        eventRedirect <= evt.redirect;
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

endmodule
