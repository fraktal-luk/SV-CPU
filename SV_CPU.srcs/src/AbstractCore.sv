
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

        logic cmpR, cmpC, cmpR_r, cmpC_r;

    localparam int FETCH_QUEUE_SIZE = 8;
    localparam int BC_QUEUE_SIZE = 64;

    localparam int N_REGS_INT = 128;
    localparam int N_REGS_FLOAT = 128;

    localparam int OP_QUEUE_SIZE = 24;
    localparam int OOO_QUEUE_SIZE = 120;

    
    
    
    class RegisterTracker;
        typedef enum {FREE, SPECULATIVE, STABLE
        } PhysRegState;
        
        typedef struct {
            PhysRegState state;
            InsId owner;
        } PhysRegInfo;

        const PhysRegInfo REG_INFO_FREE = '{state: FREE, owner: -1};
        const PhysRegInfo REG_INFO_STABLE = '{state: STABLE, owner: -1};

        PhysRegInfo intInfo[N_REGS_INT] = '{0: REG_INFO_STABLE, default: REG_INFO_FREE};
        //InsId floatOwners[N_REGS_INT] = '{default: -1};
        
        int intMapR[32] = '{default: 0};
        int intMapC[32] = '{default: 0};
        
        
        function automatic void reserveInt(input OpSlot op);
            AbstractInstruction ins = decodeAbstract(op.bits);
            int vDest = ins.dest;
            int pDest = findFree();
            
            if (!writesIntReg(op) || vDest == 0) return;
            
            intInfo[pDest] = '{SPECULATIVE, op.id};
            intMapR[vDest] = pDest;
            
        endfunction

//        function automatic int reserveFloat(input InsId id);
        
//        endfunction


        function automatic int getIntFree();
        
        endfunction
        
//        function automatic int getFloatFree();
        
//        endfunction
        
        
        function automatic void commitInt(input OpSlot op);
            AbstractInstruction ins = decodeAbstract(op.bits);
            int vDest = ins.dest;
            int ind[$] = intInfo.find_first_index with (item.owner == op.id);
            int pDest = ind[0];
            int pDestPrev = intMapC[vDest];
            
            if (!writesIntReg(op) || vDest == 0) return;
            
            intMapC[vDest] = pDest;
            if (pDestPrev != 0) intInfo[pDestPrev] = REG_INFO_FREE;
        endfunction
        
        
        function automatic int findFree();
            int res[$] = intInfo.find_first_index with (item.state == FREE);
            return res[0];
        endfunction
        
        function automatic void flush(input OpSlot op);
            AbstractInstruction ins = decodeAbstract(op.bits);

            //int vDest = ins.dest;
            int inds[$] = intInfo.find_index with (item.state == SPECULATIVE && item.owner > op.id);
            
            foreach (inds[i]) begin
                int pDest = inds[i];
                intInfo[pDest] = REG_INFO_FREE;
            end
            // Restoring map is separate
        endfunction
        
        function automatic void flushAll();
            //int vDest = ins.dest;
            int inds[$] = intInfo.find_first_index with (item.state == SPECULATIVE);
            
            foreach (inds[i]) begin
                int pDest = inds[i];
                intInfo[pDest] = REG_INFO_FREE;
            end
            // Restoring map is separate
        endfunction
 
        function automatic void restore(input int mapR[32]);
            intMapR = mapR;
        endfunction
        
    endclass


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
    
        function new(input OpSlot op, input CpuState state, input SimpleMem mem, input int intWr[32], input int floatWr[32], input int intMapR[32]);
            this.op = op;
            this.state = state;
            this.mem = new();
            this.mem.copyFrom(mem);
            this.intWriters = intWr;
            this.floatWriters = floatWr;
            this.intMapR = intMapR;
        endfunction

        OpSlot op;
        CpuState state;
        SimpleMem mem;
        int intWriters[32];
        int floatWriters[32];
        int intMapR[32];
        int floatMapR[32];
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
    
    RegisterTracker registerTracker = new();
    
    int fetchCtr = 0;
    int fqSize = 0, oqSize = 0, oooqSize = 0, bcqSize = 0, nFreeRegsInt = N_REGS_INT, nFreeRegsFloat = N_REGS_FLOAT;
    int insMapSize = 0, renamedDivergence = 0, nRenamed = 0, nCompleted = 0, nRetired = 0, oooqCompletedNum = 0, frontCompleted = 0;

    logic fetchAllow, renameAllow;
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
    
    CpuState execState;
    SimpleMem execMem = new();
    Emulator renamedEmul = new(), execEmul = new(), retiredEmul = new();
    
    
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

            if (reset) execReset();
            else if (interrupt) execInterrupt();
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
                 //  cmp0 <= (TMP_getEmul().coreState == retiredEmul.coreState);

    end


    assign insAdr = ipStage.baseAdr;

    assign fetchAllow = fetchQueueAccepts(fqSize) && bcQueueAccepts(bcqSize);
    assign renameAllow = //oqSize < OP_QUEUE_SIZE - 2*FETCH_WIDTH;
                         opQueueAccepts(oqSize) && oooQueueAccepts(oooqSize) && regsAccept(nFreeRegsInt, nFreeRegsFloat);

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
        if (eventRedirect || intPrev || resetPrev) begin
            ipStage <= '{'1, -1, eventTarget, '{default: '0}, '{default: 'x}};
        end
        else if (branchRedirect) begin
            ipStage <= '{'1, -1, branchTarget, '{default: '0}, '{default: 'x}};
        end
        else $fatal(2, "Should never get here");

        if (eventRedirect || intPrev || resetPrev) begin
            renamedEmul.setLike(retiredEmul);
            execEmul.setLike(retiredEmul);
            
            execState = retiredEmul.coreState;
            execMem.copyFrom(retiredEmul.tmpDataMem);
            
            intWritersR = '{default: -1};
            floatWritersR = '{default: -1};
            
                registerTracker.restore(registerTracker.intMapC);
            
            renamedDivergence = 0;
        end
        else if (branchRedirect) begin
            BranchCheckpoint single = branchCP;

            renamedEmul.coreState = single.state;
            renamedEmul.tmpDataMem.copyFrom(single.mem);
            execEmul.coreState = single.state;
            execEmul.tmpDataMem.copyFrom(single.mem);
            
            execState = single.state;
            execMem.copyFrom(single.mem);
            
            intWritersR = single.intWriters;
            clearStableWriters(intWritersR, lastRetired.id);
            floatWritersR = single.floatWriters;
            clearStableWriters(floatWritersR, lastRetired.id);

                registerTracker.restore(single.intMapR);

            renamedDivergence = insMap.get(branchOp.id).divergence;
        end

        // Clear stages younger than activated redirection
        fetchStage0 <= EMPTY_STAGE;
        fetchStage1 <= EMPTY_STAGE;
        fetchQueue.delete();
        
        nextStageA <= '{default: EMPTY_SLOT};
        
        if (eventRedirect || intPrev || resetPrev) begin
            flushAll();
                registerTracker.flushAll();    
        end
        else if (branchRedirect) begin
            flushPartial(branchOp);  
                registerTracker.flush(branchOp);    
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

    task automatic renameOp(input OpSlot op);             
        AbstractInstruction ins = decodeAbstract(op.bits);
        Word result, target;

        if (op.adr != renamedEmul.coreState.target) renamedDivergence++;
        result = computeResult(renamedEmul.coreState, op.adr, ins, renamedEmul.tmpDataMem); // Must be before modifying state

        runInEmulator(renamedEmul, op);
        renamedEmul.drain();

        mapOpAtRename(op);
            registerTracker.reserveInt(op);

        target = renamedEmul.coreState.target;

        if (isBranchOp(op)) begin
            int intMapR[32] = registerTracker.intMapR;
            BranchCheckpoint cp = new(op, renamedEmul.coreState, renamedEmul.tmpDataMem, intWritersR, floatWritersR, intMapR);
            branchCheckpointQueue.push_back(cp);
        end

        lastRenamed = op;
        nRenamed++;

        insMap.setDivergence(op.id, renamedDivergence);
        insMap.setResult(op.id, result);
        insMap.setTarget(op.id, target);

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
    
        mapOpAtCommit(op);
            registerTracker.commitInt(op);
        
        // Actual execution of ops which must be done after Commit
        if (isSysOp(op)) begin
            setLateEvent(execState, op);
            performSys(execState, op);
        end

        lastRetired = op;
        nRetired++;
        
        if (isBranchOp(op)) begin // Br queue entry release
            branchCheckpointQueue.pop_front();
        end           
        updateCommittedOOO();
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

    function automatic void clearStableWriters(ref int arr[32], input int stable);
        foreach (arr[i]) if (arr[i] <= stable) arr[i] = -1;
    endfunction


    task automatic execReset();    
        eventTarget <= IP_RESET;
        performAsyncEvent(retiredEmul.coreState, IP_RESET);
    endtask

    task automatic execInterrupt();
        $display(">> Interrupt !!!");
        eventTarget <= IP_INT;
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

//    // UNUSED
//    task automatic performAt(ref CpuState state, ref SimpleMem mem, input OpSlot op);
//        if (isBranchOp(op)) performBranch(state, op);
//        else if (isMemOp(op)) performMemAll(state, op, mem);
//        else if (isSysOp(op)) performSys(state, op);
//        else performRegularOp(state, op);
//    endtask


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
        // Don't commit anything more if event is being handled
        if (eventRedirect || interrupt || reset) return;
    
        while (oooQueue.size() > 0 && oooQueue[0].done == 1) begin
            OpStatus opSt = oooQueue.pop_front(); // OOO buffer entry release
            InstructionInfo insInfo = insMap.get(opSt.id);
            OpSlot op = '{1, insInfo.id, insInfo.adr, insInfo.bits};
            assert (op.id == opSt.id) else $error("wrong retirement: %p / %p", opSt, op);
       
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
 