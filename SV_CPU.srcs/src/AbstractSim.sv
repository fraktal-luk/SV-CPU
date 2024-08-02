
package AbstractSim;
    
    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;


    // Arch specific
    typedef Word Mword;

    // Sim outside core
    typedef Word Ptype[4096];


    localparam int FETCH_QUEUE_SIZE = 8;
    localparam int BC_QUEUE_SIZE = 64;

    localparam int N_REGS_INT = 128;
    localparam int N_REGS_FLOAT = 128;

    localparam int ISSUE_QUEUE_SIZE = 24;

    localparam int ROB_SIZE = 128;
    
    localparam int LQ_SIZE = 80;
    localparam int SQ_SIZE = 80;
    localparam int BQ_SIZE = 32;

    localparam FETCH_WIDTH = 4;
    localparam RENAME_WIDTH = 4;
    localparam LOAD_WIDTH = FETCH_WIDTH; // TODO: change this

    localparam logic IN_ORDER = 0;//1;
    localparam logic USE_FORWARDING = 1;//0;

    localparam int FW_FIRST = -2 + 2;
    localparam int FW_LAST = 1;


////////////////////////////
    // Core structures

    typedef int InsId;  // Implem detail
    typedef InsId IdQueue[$]; // Implet detail

    typedef struct {
        logic active;
        InsId id;
        Word adr;
        Word bits;
    } OpSlot;

    const OpSlot EMPTY_SLOT = '{'0, -1, 'x, 'x};
    
    typedef OpSlot OpSlotQueue[$];
    typedef OpSlot OpSlotA[RENAME_WIDTH];
    typedef OpSlot FetchStage[FETCH_WIDTH];

    const FetchStage EMPTY_STAGE = '{default: EMPTY_SLOT};

   
    // Write buffer
    typedef struct {
        OpSlot op;
        Word adr;
        Word val;
    } StoreQueueEntry;


    typedef struct {
        Mword target;
        logic redirect;
        logic sig;
        logic wrong;
    } LateEvent;

    const LateEvent EMPTY_LATE_EVENT = '{'x, 0, 0, 0};


    typedef struct {
        logic req;
        Word adr;
        Word value;
    } MemWriteInfo;
    
    const MemWriteInfo EMPTY_WRITE_INFO = '{0, 'x, 'x};


    typedef struct {
        OpSlot op;
        logic interrupt;
        logic reset;
        logic redirect;
        logic sigOk;
        logic sigWrong;
        Word target;
    } EventInfo;
    
    const EventInfo EMPTY_EVENT_INFO = '{EMPTY_SLOT, 0, 0, 0, '0, '0, 'x};

    typedef struct {
        int iqRegular;
        int iqFloat;
        int iqBranch;
        int iqMem;
        int iqSys;
    } IqLevels;

    // not really used yet
    typedef struct {
        OpSlot late;
        OpSlot exec;
    } Events;

    typedef struct {
        InsId id;
        Word target;
    } BranchTargetEntry;

    typedef struct {
        int rename;
        int renameG;
        int bq;
        int lq;
        int sq;
    } IndexSet;

    //////////////////////////////////////



    // Defs for tracking, insMap
    typedef enum { SRC_ZERO, SRC_CONST, SRC_INT, SRC_FLOAT
    } SourceType;
    
    typedef struct {
        int sources[3];
        SourceType types[3];
        InsId producers[3];
    } InsDependencies;



    class BranchCheckpoint;
    
        function new(input OpSlot op, input CpuState state, input SimpleMem mem, 
                    input int intWr[32], input int floatWr[32],
                    input int intMapR[32], input int floatMapR[32],
                    input IndexSet indexSet);
            this.op = op;
            this.state = state;
            this.mem = new();
            this.mem.copyFrom(mem);
            this.intWriters = intWr;
            this.floatWriters = floatWr;
            this.intMapR = intMapR;
            this.floatMapR = floatMapR;
            this.inds = indexSet;
        endfunction

        OpSlot op;
        CpuState state;
        SimpleMem mem;
        int intWriters[32];
        int floatWriters[32];
        int intMapR[32];
        int floatMapR[32];
        IndexSet inds;
    endclass



    typedef struct {
        InsId intWritersR[32] = '{default: -1};
        InsId floatWritersR[32] = '{default: -1};
        InsId intWritersC[32] = '{default: -1};
        InsId floatWritersC[32] = '{default: -1};
    } WriterTracker;






    class RegisterTracker #(parameter int N_REGS_INT = 128, parameter int N_REGS_FLOAT = 128);
        typedef enum {FREE, SPECULATIVE, STABLE
        } PhysRegState;
        
        typedef struct {
            PhysRegState state;
            InsId owner;
        } PhysRegInfo;

        localparam PhysRegInfo REG_INFO_FREE = '{state: FREE, owner: -1};
        localparam PhysRegInfo REG_INFO_STABLE = '{state: STABLE, owner: -1};

        typedef struct {
            PhysRegInfo info[N_REGS_INT] = '{0: REG_INFO_STABLE, default: REG_INFO_FREE};        
            Word regs[N_REGS_INT] = '{0: 0, default: 'x};
            logic ready[N_REGS_INT] = '{0: 1, default: '0};
            
            int MapR[32] = '{default: 0};
            int MapC[32] = '{default: 0};
        } IntRegisterDomain;

        IntRegisterDomain ints;

        PhysRegInfo ints_info[N_REGS_INT] = '{0: REG_INFO_STABLE, default: REG_INFO_FREE};        
        Word ints_regs[N_REGS_INT] = '{0: 0, default: 'x};
        logic ints_ready[N_REGS_INT] = '{0: 1, default: '0};

        int ints_MapR[32] = '{default: 0};
        int ints_MapC[32] = '{default: 0};
        
        

        PhysRegInfo floatInfo[N_REGS_INT] = '{0: REG_INFO_STABLE, default: REG_INFO_FREE};        
        Word floatRegs[N_REGS_INT] = '{0: 0, default: 'x};
        logic floatReady[N_REGS_INT] = '{0: 1, default: '0};
                
        int floatMapR[32] = '{default: 0};
        int floatMapC[32] = '{default: 0};
 
       
        WriterTracker wrTracker;


            
        function automatic int reserve(input OpSlot op);
            AbstractInstruction abs = decodeAbstract(op.bits);

            if (hasIntDest(abs))
                return reserveInt(abs, op.id);

            if (hasFloatDest(abs)) begin
                wrTracker.floatWritersR[abs.dest] = op.id;
                reserveFloat(op);
                return findDestFloat(op.id);
            end
 
            return -1;
        endfunction

        function automatic int reserveInt(input AbstractInstruction ins, input InsId id);
            int vDest = ins.dest;
            int pDest = findFreeInt();
            
            if (vDest != 0) begin
                wrTracker.intWritersR[vDest] = id;

                ints_info[pDest] = '{SPECULATIVE, id};
                ints_MapR[vDest] = pDest;
            end
            
            return findDestInt(id);
        endfunction


        function automatic void commit(input OpSlot op);
            AbstractInstruction abs = decodeAbstract(op.bits);
            if (hasIntDest(abs))
                commitInt(abs, op.id);
            
            if (hasFloatDest(abs)) begin
                wrTracker.floatWritersC[abs.dest] = op.id;
                commitFloat(op);
            end
        endfunction

        function automatic void commitInt(input AbstractInstruction ins, InsId id);
            int vDest = ins.dest;
            int ind[$] = ints_info.find_first_index with (item.owner == id);
            int pDest = ind[0];
            int pDestPrev = ints_MapC[vDest];
                        
            if (vDest == 0) return;
            
            wrTracker.intWritersC[vDest] = id;

            ints_info[pDest] = '{STABLE, -1};
            ints_MapC[vDest] = pDest;
            if (pDestPrev == 0) return; 
            ints_info[pDestPrev] = REG_INFO_FREE;
            ints_ready[pDestPrev] = 0;
            ints_regs[pDestPrev] = 'x;
        endfunction


        function automatic void writeValue(input OpSlot op, input Word value);
            AbstractInstruction ins = decodeAbstract(op.bits);

            if (writesIntReg(op)) begin
                setReadyInt(op.id);
                writeValueInt(ins, op.id, value);
            end
            if (writesFloatReg(op)) begin
                setReadyFloat(op.id);
                writeValueFloat(op, value);
            end
        endfunction


        function automatic void setReadyInt(input InsId id);
            int pDest = findDestInt(id);
            ints_ready[pDest] = 1;
        endfunction;

        function automatic void writeValueInt(//input OpSlot op, 
                                              input AbstractInstruction ins, input InsId id, input Word value);
            //AbstractInstruction ins = decodeAbstract(op.bits);
            int pDest = findDestInt(id);
            if (//!writesIntReg(op) || 
                ins.dest == 0) return;
            
            ints_regs[pDest] = value;
        endfunction
        

        
        function automatic int findFreeInt();
            int res[$] = ints_info.find_first_index with (item.state == FREE);
            return res[0];
        endfunction

        function automatic int findDestInt(input InsId id);
            int inds[$] = ints_info.find_first_index with (item.owner == id);
            return inds.size() > 0 ? inds[0] : -1;
        endfunction;



            function automatic void reserveFloat(input OpSlot op);
                AbstractInstruction ins = decodeAbstract(op.bits);
                int vDest = ins.dest;
                int pDest = findFreeFloat();
                                
                floatInfo[pDest] = '{SPECULATIVE, op.id};
                floatMapR[vDest] = pDest;
            endfunction
                    
            function automatic void commitFloat(input OpSlot op);
                AbstractInstruction ins = decodeAbstract(op.bits);
                int vDest = ins.dest;
                int ind[$] = floatInfo.find_first_index with (item.owner == op.id);
                int pDest = ind[0];
                int pDestPrev = floatMapC[vDest];
                                
                floatInfo[pDest] = '{STABLE, -1};
                floatMapC[vDest] = pDest;
                if (pDestPrev == 0) return;
                floatInfo[pDestPrev] = REG_INFO_FREE;
                floatReady[pDestPrev] = 0;
                floatRegs[pDestPrev] = 'x;
            endfunction

            function automatic void writeValueFloat(input OpSlot op, input Word value);
                int pDest = findDestFloat(op.id);
                if (!writesFloatReg(op)) return;
                
                floatRegs[pDest] = value;
            endfunction
        
            function automatic void setReadyFloat(input InsId id);
                int pDest = findDestFloat(id);
                floatReady[pDest] = 1;
            endfunction;

            function automatic int findFreeFloat();
                int res[$] = floatInfo.find_first_index with (item.state == FREE);
                return res[0];
            endfunction

            function automatic int findDestFloat(input InsId id);
                int inds[$] = floatInfo.find_first_index with (item.owner == id);
                return inds.size() > 0 ? inds[0] : -1;
            endfunction;


        function automatic InsDependencies getArgDeps(input OpSlot op);
            int mapInt[32] = ints_MapR;
            int mapFloat[32] = floatMapR;
            int sources[3] = '{-1, -1, -1};
            InsId producers[3] = '{-1, -1, -1};
            SourceType types[3] = '{SRC_CONST, SRC_CONST, SRC_CONST}; 
            
            AbstractInstruction abs = decodeAbstract(op.bits);
            string typeSpec = parsingMap[abs.fmt].typeSpec;
            
            foreach (sources[i]) begin
                if (typeSpec[i + 2] == "i") begin
                    sources[i] = mapInt[abs.sources[i]];
                    types[i] = sources[i] ? SRC_INT: SRC_ZERO;
                    producers[i] = ints_info[sources[i]].owner;
                end
                else if (typeSpec[i + 2] == "f") begin
                    sources[i] = mapFloat[abs.sources[i]];
                    types[i] = SRC_FLOAT;
                    producers[i] = floatInfo[sources[i]].owner;
                end
                else if (typeSpec[i + 2] == "c") begin
                    sources[i] = abs.sources[i];
                    types[i] = SRC_CONST;
                end
                else if (typeSpec[i + 2] == "0") begin
                    sources[i] = 0;
                    types[i] = SRC_ZERO;
                end
            end
    
            return '{sources, types, producers};
        endfunction
         
        
        function automatic void flush(input OpSlot op);
            int indsInt[$] = ints_info.find_index with (item.state == SPECULATIVE && item.owner > op.id);
            int indsFloat[$] = floatInfo.find_index with (item.state == SPECULATIVE && item.owner > op.id);

            foreach (indsInt[i]) begin
                int pDest = indsInt[i];
                ints_info[pDest] = REG_INFO_FREE;
                ints_ready[pDest] = 0;
                ints_regs[pDest] = 'x;
            end

            foreach (indsFloat[i]) begin
                int pDest = indsFloat[i];
                floatInfo[pDest] = REG_INFO_FREE;
                floatReady[pDest] = 0;
                floatRegs[pDest] = 'x;
            end          
            
            // Restoring map is separate
        endfunction
        
        function automatic void flushAll();
            int indsInt[$] = ints_info.find_index with (item.state == SPECULATIVE);
            int indsFloat[$] = floatInfo.find_index with (item.state == SPECULATIVE);

            foreach (indsInt[i]) begin
                int pDest = indsInt[i];
                ints_info[pDest] = REG_INFO_FREE;
                ints_ready[pDest] = 0;
                ints_regs[pDest] = 'x;
            end
             
            foreach (indsFloat[i]) begin
                int pDest = indsFloat[i];
                floatInfo[pDest] = REG_INFO_FREE;
                floatReady[pDest] = 0;
                floatRegs[pDest] = 'x;
            end
            
            // Restoring map is separate
        endfunction
 
        function automatic void restoreCP(input int intM[32], input int floatM[32], input InsId intWriters[32], input InsId floatWriters[32]);
            ints_MapR = intM;
            floatMapR = floatM;
            
            wrTracker.intWritersR = intWriters;
            wrTracker.floatWritersR = floatWriters;
        endfunction
    
        function automatic void restoreStable();
            ints_MapR = ints_MapC;
            floatMapR = floatMapC;
        
            wrTracker.intWritersR = wrTracker.intWritersC;
            wrTracker.floatWritersR = wrTracker.floatWritersC;
        endfunction

        function automatic void restoreReset();
            ints_MapR = ints_MapC;
            floatMapR = floatMapC;
        
            wrTracker.intWritersR = '{default: -1};
            wrTracker.floatWritersR = '{default: -1};
        endfunction


        function automatic int getNumFreeInt();
            int freeInds[$] = ints_info.find_index with (item.state == FREE);
            int specInds[$] = ints_info.find_index with (item.state == SPECULATIVE);
            int stabInds[$] = ints_info.find_index with (item.state == STABLE);            
            return freeInds.size();
        endfunction
        
        
        function automatic int getNumFreeFloat();
            int freeInds[$] = floatInfo.find_index with (item.state == FREE);
            int specInds[$] = floatInfo.find_index with (item.state == SPECULATIVE);
            int stabInds[$] = floatInfo.find_index with (item.state == STABLE);            
            return freeInds.size();
        endfunction


            // UNUSED
            function automatic int getNumSpecInt();
                int specInds[$] = ints_info.find_index with (item.state == SPECULATIVE);            
                return specInds.size();
            endfunction 
            
            // UNUSED
            function automatic int getNumStabInt();
                int stabInds[$] = ints_info.find_index with (item.state == STABLE);            
                return stabInds.size();
            endfunction

    endclass

    
    typedef struct {
        InsId owner;
        Word adr;
        Word val;
        Word adrAny; 
    } Transaction;


    class MemTracker;
        Transaction transactions[$];
        Transaction stores[$];
        Transaction loads[$];
        Transaction committedStores[$]; // Not included in transactions
        
        function automatic void add(input OpSlot op, input AbstractInstruction ins, input Word argVals[3]);
            Word effAdr = calculateEffectiveAddress(ins, argVals);
    
            if (isStoreMemIns(ins)) begin 
                Word value = argVals[2];
                addStore(op, effAdr, value);
            end
            if (isLoadMemIns(ins)) begin
                addLoad(op, effAdr, 'x);
            end
            if (isStoreSysIns(ins)) begin 
                Word value = argVals[2];
                addStoreSys(op, effAdr, value);
            end
            if (isLoadSysIns(ins)) begin
                addLoadSys(op, effAdr, 'x);
            end
        endfunction

        
        function automatic void addStore(input OpSlot op, input Word adr, input Word val);
            transactions.push_back('{op.id, adr, val, adr});
            stores.push_back('{op.id, adr, val, adr});
        endfunction

        function automatic void addLoad(input OpSlot op, input Word adr, input Word val);            
            transactions.push_back('{op.id, adr, val, adr});
            loads.push_back('{op.id, adr, val, adr});
        endfunction

        function automatic void addStoreSys(input OpSlot op, input Word adr, input Word val);
            transactions.push_back('{op.id, 'x, val, adr});
            stores.push_back('{op.id, 'x, val, adr});
        endfunction

        function automatic void addLoadSys(input OpSlot op, input Word adr, input Word val);            
            transactions.push_back('{op.id, 'x, val, adr});
            loads.push_back('{op.id, 'x, val, adr});
        endfunction


        function automatic void remove(input OpSlot op);
            assert (transactions[0].owner == op.id) begin
                void'(transactions.pop_front());
                if (stores.size() != 0 && stores[0].owner == op.id) begin
                    Transaction store = (stores.pop_front());
                    committedStores.push_back(store);                       
                end
                if (loads.size() != 0 && loads[0].owner == op.id) void'(loads.pop_front());
            end
            else $error("Incorrect transaction commit");
        endfunction

        function automatic void drain(input OpSlot op);
            assert (committedStores[0].owner == op.id) begin
                void'(committedStores.pop_front());
            end
            else $error("Incorrect transaction drain: %d but found %d", op.id, committedStores[0].owner);
        endfunction

        function automatic void flushAll();
            transactions.delete();
            stores.delete();
            loads.delete();
        endfunction

        function automatic void flush(input OpSlot op);
            while (transactions.size() != 0 && transactions[$].owner > op.id) void'(transactions.pop_back());
            while (stores.size() != 0 && stores[$].owner > op.id) void'(stores.pop_back());
            while (loads.size() != 0 && loads[$].owner > op.id) void'(loads.pop_back());
        endfunction

        function automatic InsId checkWriter(input OpSlot op);
            Transaction allStores[$] = {committedStores, stores};
        
            Transaction read[$] = transactions.find_first with (item.owner == op.id); 
            Transaction writers[$] = allStores.find with (item.adr == read[0].adr && item.owner < op.id);
            return (writers.size() == 0) ? -1 : writers[$].owner;
        endfunction
  
        function automatic Word getStoreValue(input InsId id);
            Transaction allStores[$] = {committedStores, stores};
            Transaction writers[$] = allStores.find with (item.owner == id);
            return writers[0].val;
        endfunction

        function automatic Transaction findStore(input InsId id);
            Transaction writers[$] = stores.find with (item.owner == id);
            return writers[0];
        endfunction

    endclass





//////////////////
// General
    function automatic logic anyActiveFetch(input FetchStage s);
        foreach (s[i]) if (s[i].active) return 1;
        return 0;
    endfunction

    function automatic logic anyActive(input OpSlotA s);
        foreach (s[i]) if (s[i].active) return 1;
        return 0;
    endfunction

    // Op classiication
    
    function automatic logic writesIntReg(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return hasIntDest(abs);
    endfunction

    function automatic logic writesFloatReg(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return hasFloatDest(abs);
    endfunction


    function automatic logic isBranchOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isBranchIns(abs);
    endfunction

    function automatic logic isStoreMemOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isStoreMemIns(abs);
    endfunction

    function automatic logic isStoreSysOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isStoreSysIns(abs);
    endfunction

    function automatic logic isLoadMemOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isLoadMemIns(abs);
    endfunction

    function automatic logic isLoadOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isLoadIns(abs);
    endfunction

    function automatic logic isStoreOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isStoreIns(abs);
    endfunction

    function automatic logic isMemOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isMemIns(abs);
    endfunction

    function automatic logic isSysOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isSysIns(abs);
    endfunction
    /////////////////////////////////////////////////


    ////////////////////////////////////////////
    // Core functions

    function automatic LateEvent getLateEvent(input OpSlot op, input AbstractInstruction abs, input Mword sr2, input Mword sr3);
        LateEvent res = '{target: 'x, redirect: 0, sig: 0, wrong: 0};
        case (abs.def.o)
            O_sysStore: ;
            O_undef: begin
                res.target = IP_ERROR;
                res.redirect = 1;
                res.wrong = 1;
            end
            O_call: begin
                res.target = IP_CALL;
                res.redirect = 1;
            end
            O_retE: begin
                res.target = sr2;
                res.redirect = 1;
            end 
            O_retI: begin
                res.target = sr3;
                res.redirect = 1;
            end 
            O_sync: begin
                res.target = op.adr + 4;
                res.redirect = 1;
            end
            
            O_replay: begin
                res.target = op.adr;
                res.redirect = 1;
            end 
            O_halt: begin                
                res.target = op.adr + 4;
                res.redirect = 1;
            end
            O_send: begin
                res.target = op.adr + 4;
                res.redirect = 1;
                res.sig = 1;
            end
            default: ;                            
        endcase

        return res;
    endfunction

    function automatic void modifyStateSync(ref Word sysRegs[32], input Word adr, input AbstractInstruction abs);
        case (abs.def.o)
            O_undef: begin
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr + 4;
                
                sysRegs[1] |= 1; // TODO: handle state register correctly
            end
            O_call: begin                    
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr + 4;
                
                sysRegs[1] |= 1; // TODO: handle state register correctly
            end
            O_retE: sysRegs[1] = sysRegs[4];
            O_retI: sysRegs[1] = sysRegs[5];
        endcase
    endfunction

    function automatic void saveStateAsync(ref Word sysRegs[32], input Word prevTarget);
        sysRegs[5] = sysRegs[1];
        sysRegs[3] = prevTarget;
        
        sysRegs[1] |= 2; // TODO: handle state register correctly
    endfunction


    function automatic logic getWrongSignal(input AbstractInstruction ins);
        return ins.def.o == O_undef;
    endfunction

    function automatic logic getSendSignal(input AbstractInstruction ins);
        return ins.def.o == O_send;
    endfunction

    task automatic checkUnimplementedInstruction(input AbstractInstruction ins);
        if (ins.def.o == O_halt) $error("halt not implemented");
    endtask

    // core logic
    function automatic Word getCommitTarget(input AbstractInstruction ins, input Word prev, input Word executed);
        if (isBranchIns(ins))
            return executed;
        else if (isSysIns(ins))
            return 'x;
        else
            return prev + 4;
    endfunction;

endpackage
