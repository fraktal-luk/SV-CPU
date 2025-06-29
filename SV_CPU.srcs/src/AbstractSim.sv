
package AbstractSim;
    
    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import EmulationDefs::*;
    import Emulation::*;
    import UopList::*;


        localparam logic DEV_ICACHE_MISS = 1; // TODO: remove


    // Uarch specific
    localparam int FETCH_QUEUE_SIZE = 8;
    localparam int BC_QUEUE_SIZE = 64;

    localparam int N_REGS_INT = 128;
    localparam int N_REGS_FLOAT = 128;

    localparam int ISSUE_QUEUE_SIZE = 24;

    localparam int ROB_SIZE = 128;
    localparam int ROB_WIDTH = 4;
    
    localparam int LQ_SIZE = 80;
    localparam int SQ_SIZE = 80;
    localparam int BQ_SIZE = 32;

    localparam int FETCH_WIDTH = 4;
    localparam int RENAME_WIDTH = 4;
    
    localparam int DISPATCH_WIDTH = RENAME_WIDTH;


    localparam logic IN_ORDER = 0;

    localparam int FW_FIRST = -2 + 0;
    localparam int FW_LAST = 1;


////////////////////////////
    // Core structures

    typedef int InsId;  // Implem detail
    typedef InsId IdQueue[$]; // Implem detail


    typedef struct {
        int m;
        int s;
    } UopId;
    
    localparam UopId UID_NONE = '{-1, -1};


    typedef UopId UidT; // FUTURE change to UopId
    localparam UidT UIDT_NONE = UID_NONE;

    function automatic UidT FIRST_U(input InsId id);
        return '{id, 0};
    endfunction
    
    function automatic InsId U2M(input UidT uid);
        return uid.m;
    endfunction

    function automatic int SUBOP(input UidT uid);
        return uid.s;
    endfunction

    
    typedef UidT UidQueueT[$];
    
    typedef UidT WriterId;
    localparam WriterId WID_NONE = UIDT_NONE;


    // Transfer size in bytes
    typedef enum {
        SIZE_NONE = 0,
        SIZE_1 = 1,
        SIZE_4 = 4,
        SIZE_8 = 8
    } AccessSize;
    
    function automatic AccessSize getTransactionSize(input UopName uname);
        if (uname inside {UOP_mem_ldib, UOP_mem_stib}) return SIZE_1;
        else if (isMemUop(uname)) return SIZE_4;
        else return SIZE_NONE;
    endfunction


    typedef struct {
        logic active;
        InsId id;
        Mword adr;
        Word bits;
        
        logic takenBranch;
        Mword predictedTarget;
    } OpSlotF;
        
        // Maybe redundant (OpSlotF has it all)
        typedef struct {
            logic active;
            InsId mid;
            Mword adr;  // hardly used
            Word bits;  // hardly used
        } OpSlotB;


    typedef struct {
        logic active;
        InsId mid;
        Mword adr;

        logic takenBranch;
        logic exception;
        logic refetch;

        Mword target;
    } RetirementInfo;


    localparam OpSlotF EMPTY_SLOT_F = '{'0, -1, 'x, 'x, 'x, 'x};
    localparam OpSlotB EMPTY_SLOT_B = '{'0, -1, 'x, 'x};
    localparam RetirementInfo EMPTY_RETIREMENT_INFO = '{'0, -1, 'x, 'x, 'x, 'x, 'x};

    typedef OpSlotF OpSlotAF[FETCH_WIDTH];
    typedef OpSlotB OpSlotAB[RENAME_WIDTH];
    typedef RetirementInfo RetirementInfoA[RENAME_WIDTH];


    typedef enum {
        CO_none,
        
        CO_reset,
        CO_int,
        
        CO_undef,
        
        CO_error,
        CO_send,
        CO_call,
        
        CO_exception,
        
        CO_sync,
        CO_refetch,
        
        CO_retE,
        CO_retI,
        
        CO_break

    } ControlOp;
    
    typedef struct {
        logic active;
        InsId eventMid;
        ControlOp cOp;
        logic redirect;
        Mword adr;
        Mword target;
    } EventInfo;
    
    localparam EventInfo EMPTY_EVENT_INFO = '{0, -1, CO_none,  0, 'x, 'x};
    localparam EventInfo RESET_EVENT =      '{1, -1, CO_reset, 1, 'x, IP_RESET};
    localparam EventInfo INT_EVENT =        '{1, -1, CO_int,   1, 'x, IP_INT};

    typedef struct {
        int iqRegular;
        int iqFloat;
        int iqBranch;
        int iqMem;
        int iqStoreData;
    } IqLevels;


    typedef struct {
        InsId id;
        Mword target;
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
        WriterId producers[3];
    } InsDependencies;

    localparam InsDependencies DEFAULT_INS_DEPS = '{sources: '{default: -1}, types: '{default: SRC_ZERO}, producers: '{default: UIDT_NONE}};


    class BranchCheckpoint;
        function new(input InsId id,
                    input WriterId intWr[32], input WriterId floatWr[32],
                    input int intMapR[32], input int floatMapR[32],
                    input IndexSet indexSet, input Emulator em);
            this.id = id;
            this.intWriters = intWr;
            this.floatWriters = floatWr;
            this.intMapR = intMapR;
            this.floatMapR = floatMapR;
            this.inds = indexSet;
            this.emul = em.copyCore();
            this.emul.dataMem = new em.dataMem;
        endfunction

        InsId id;
        WriterId intWriters[32];
        WriterId floatWriters[32];
        int intMapR[32];
        int floatMapR[32];
        IndexSet inds;
        Emulator emul;
    endclass


    class RegisterTracker #(parameter int N_REGS_INT = 128, parameter int N_REGS_FLOAT = 128);
            
        // FUTURE: move to RegisterDomain after moving functiona for num free etc.
        typedef enum {FREE, SPECULATIVE, STABLE
        } PhysRegState;
        
        typedef struct {
            PhysRegState state;
            WriterId owner;
        } PhysRegInfo;    

        class RegisterDomain#(
            parameter int N_REGS = N_REGS_INT,
            parameter logic IGNORE_R0 = 1
        );
            localparam PhysRegInfo REG_INFO_FREE = '{state: FREE, owner: WID_NONE};
            localparam PhysRegInfo REG_INFO_STABLE = '{state: STABLE, owner: WID_NONE};
    
        
            PhysRegInfo info[N_REGS] = '{0: REG_INFO_STABLE, default: REG_INFO_FREE};        
            Mword regs[N_REGS] = '{0: 0, default: 'x};
            logic ready[N_REGS] = '{0: 1, default: '0};
            
            int MapR[32] = '{default: 0};
            int MapC[32] = '{default: 0};
            
            WriterId writersR[32] = '{default: WID_NONE};
            WriterId writersC[32] = '{default: WID_NONE};
            
            function automatic logic ignoreV(input int vReg);
                return (vReg == 0) && IGNORE_R0;
            endfunction
            
            function automatic int reserve(input int vDest, input WriterId id);
                int pDest = findFree();
                 
                if (!ignoreV(vDest)) begin
                    writersR[vDest] = id;
                    info[pDest] = '{SPECULATIVE, id};
                    MapR[vDest] = pDest;
                end
                return findDest(id);
            endfunction
    

            function automatic void releaseRegister(input int p);                
                if (p == 0) return;
                info[p] = REG_INFO_FREE;
                ready[p] = 0;
                regs[p] = 'x;
            endfunction
  
            function automatic void commit(input int vDest, input WriterId id, input logic normal);
                int ind[$] = info.find_first_index with (item.owner == id);
                int pDest = ind[0];
                int pDestPrev = MapC[vDest];
 
                if (ignoreV(vDest)) return;
                
                if (normal) begin
                    writersC[vDest] = id;
                    MapC[vDest] = pDest;
                    info[pDest] = '{STABLE, WID_NONE};
                    
                    releaseRegister(pDestPrev);
                end
                else begin
                    releaseRegister(pDest);
                end

            endfunction

            function automatic void setReady(input WriterId id);
                int pDest = findDest(id);
                ready[pDest] = 1;
            endfunction;
    
            function automatic void writeValue(input int vDest, input WriterId id, input Mword value);
                int pDest = findDest(id);
                if (ignoreV(vDest)) return;
                regs[pDest] = value;
            endfunction            
 
            function automatic int findFree();
                int res[$] = info.find_first_index with (item.state == FREE);
                return res[0];
            endfunction
    
            function automatic int findDest(input WriterId id);
                int inds[$] = info.find_first_index with (item.owner == id);
                return inds.size() > 0 ? inds[0] : -1;
            endfunction;


            function automatic void flush(input InsId id);
                int inds[$] = info.find_index with (item.state == SPECULATIVE && U2M(item.owner) > id);

                foreach (inds[i]) begin
                    int pDest = inds[i];
                    info[pDest] = REG_INFO_FREE;
                    ready[pDest] = 0;
                    regs[pDest] = 'x;
                end
                // Restoring map is separate
            endfunction

            function automatic void flushAll();
                int inds[$] = info.find_index with (item.state == SPECULATIVE);

                foreach (inds[i]) begin
                    int pDest = inds[i];
                    info[pDest] = REG_INFO_FREE;
                    ready[pDest] = 0;
                    regs[pDest] = 'x;
                end
                // Restoring map is separate
            endfunction


            function automatic void restoreCP(input int intM[32], input WriterId intWriters[32]);
                MapR = intM;
                writersR = intWriters;
            endfunction

            function automatic void restoreStable();
                MapR = MapC;
                writersR = writersC;
            endfunction

            function automatic void restoreReset();
                MapR = MapC;
                writersR = '{default: WID_NONE};

                foreach (info[i])
                    if (info[i].state == STABLE) regs[i] = 0;
            endfunction           
        endclass


        RegisterDomain#(N_REGS_INT, 1) ints = new();
        RegisterDomain#(N_REGS_INT, 0) floats = new(); // FUTURE: change to FP reg num


        function automatic int reserve(input UopName name, input int dest, input WriterId id);            
            if (uopHasIntDest(name)) return ints.reserve(dest, id);
            if (uopHasFloatDest(name)) return  floats.reserve(dest, id);
            return -1;
        endfunction


        function automatic void commit(input UopName name, input int dest, input WriterId id, input abnormal);            
            if (uopHasIntDest(name)) ints.commit(dest, id, !abnormal);      
            if (uopHasFloatDest(name)) floats.commit(dest, id, !abnormal);
        endfunction

        function automatic void writeValue(input UopName name, input int dest, input WriterId id, input Mword value);
            if (uopHasIntDest(name)) begin
                ints.setReady(id);
                ints.writeValue(dest, id, value);
            end
            if (uopHasFloatDest(name)) begin
                floats.setReady(id);
                floats.writeValue(dest, id, value);
            end
        endfunction


        function automatic InsDependencies getArgDeps(input AbstractInstruction abs);
            int sources[3] = '{-1, -1, -1};
            WriterId producers[3] = '{WID_NONE, WID_NONE, WID_NONE};
            SourceType types[3] = '{SRC_CONST, SRC_CONST, SRC_CONST}; 
            
            string typeSpec = parsingMap[abs.def.f].typeSpec;
            
            foreach (sources[i]) begin
                if (typeSpec[i + 2] == "i") begin
                    sources[i] = ints.MapR[abs.sources[i]];
                    types[i] = sources[i] ? SRC_INT: SRC_ZERO;
                    producers[i] = ints.info[sources[i]].owner;
                end
                else if (typeSpec[i + 2] == "f") begin
                    sources[i] = floats.MapR[abs.sources[i]];
                    types[i] = SRC_FLOAT;
                    producers[i] = floats.info[sources[i]].owner;
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
        
 
 
        function automatic void flush(input InsId id);
            ints.flush(id);
            floats.flush(id);
        endfunction
        
        function automatic void flushAll();
            ints.flushAll();
            floats.flushAll();
        endfunction
 
 
        function automatic void restoreCP(input int intM[32], input int floatM[32], input WriterId intWriters[32], input WriterId floatWriters[32]);
            ints.restoreCP(intM, intWriters);
            floats.restoreCP(floatM, floatWriters);
        endfunction
    
        function automatic void restoreStable();
            ints.restoreStable();
            floats.restoreStable();
        endfunction

        function automatic void restoreReset();
            ints.restoreReset();
            floats.restoreReset();
        endfunction


        function automatic int getNumFreeInt();
            int freeInds[$] = ints.info.find_index with (item.state == FREE);   
            return freeInds.size();
        endfunction        
        
        function automatic int getNumFreeFloat();
            int freeInds[$] = floats.info.find_index with (item.state == FREE);           
            return freeInds.size();
        endfunction

    endclass

    

    typedef struct {
        InsId owner;
        Mword adr;
        Mword val;
        Mword adrAny;
        Dword padr;
        AccessSize size;
    } Transaction;

    localparam Transaction EMPTY_TRANSACTION = '{-1, 'x, 'x, 'x, 'x, SIZE_NONE};


    class MemTracker;
        Transaction transactions[$];
        Transaction stores[$];
        Transaction loads[$];
        Transaction committedStores[$]; // Not included in transactions
        
        function automatic void add(input InsId id, input UopName uname, input AbstractInstruction ins, input Mword argVals[3],  input Dword padr);
            Mword effAdr = calculateEffectiveAddress(ins, argVals);
            AccessSize size = getTransactionSize(uname);

            if (isStoreMemIns(ins)) begin 
                Mword value = argVals[2];
                addStore(id, effAdr, padr, value, size);
            end
            if (isLoadMemIns(ins)) begin
                addLoad(id, effAdr, padr, 'x, size);
            end
            if (isStoreSysIns(ins)) begin 
                Mword value = argVals[2];
                addStoreSys(id, effAdr, value);
            end
            if (isLoadSysIns(ins)) begin
                addLoadSys(id, effAdr, 'x);
            end
        endfunction

        function automatic void addStore(input InsId id, input Mword adr, input Dword padr, input Mword val, input AccessSize size);
            transactions.push_back('{id, adr, val, adr, padr, size});
            stores.push_back('{id, adr, val, adr, padr, size});
        endfunction

        function automatic void addLoad(input InsId id, input Mword adr, input Dword padr, input Mword val, input AccessSize size);
            transactions.push_back('{id, adr, val, adr, padr, size});
            loads.push_back('{id, adr, val, adr, padr, size});
        endfunction

        function automatic void addStoreSys(input InsId id, input Mword adr, input Mword val);
            transactions.push_back('{id, 'x, val, adr, 'x, SIZE_NONE});
            stores.push_back('{id, 'x, val, adr, 'x, SIZE_NONE});
        endfunction

        function automatic void addLoadSys(input InsId id, input Mword adr, input Mword val);            
            transactions.push_back('{id, 'x, val, adr, 'x, SIZE_NONE});
            loads.push_back('{id, 'x, val, adr, 'x, SIZE_NONE});
        endfunction

        function automatic void remove(input InsId id);        
            assert (transactions[0].owner == id) begin
                void'(transactions.pop_front());
                if (stores.size() != 0 && stores[0].owner == id) begin
                    Transaction store = (stores.pop_front());
                    committedStores.push_back(store);                       
                end
                if (loads.size() != 0 && loads[0].owner == id) void'(loads.pop_front());
            end
            else $error("Incorrect transaction commit");
        endfunction

        function automatic void drain(input InsId id);
            assert (committedStores[0].owner == id) begin
                void'(committedStores.pop_front());
            end
            else $error("Incorrect transaction drain: %d but found %d", id, committedStores[0].owner);
        endfunction

        function automatic void flushAll();
            transactions.delete();
            stores.delete();
            loads.delete();
        endfunction

        function automatic void flush(input InsId id);
            while (transactions.size() != 0 && transactions[$].owner > id) void'(transactions.pop_back());
            while (stores.size() != 0 && stores[$].owner > id) void'(stores.pop_back());
            while (loads.size() != 0 && loads[$].owner > id) void'(loads.pop_back());
        endfunction
        
        
        function automatic Transaction checkTransactionOverlap(input InsId id);
            Transaction allStores[$] = {committedStores, stores};
            Transaction read[$] = transactions.find_first with (item.owner == id); 
            Transaction writers[$] = allStores.find_last with (item.owner < id && memOverlap(item.padr, (item.size), read[0].padr, (read[0].size)));
            return (writers.size() == 0) ? EMPTY_TRANSACTION : writers[$];
        endfunction


        function automatic Transaction findStore(input InsId id);
            Transaction writers[$] = stores.find with (item.owner == id);
            return (writers.size() == 0) ? EMPTY_TRANSACTION : writers[0];
        endfunction

        function automatic Transaction findStoreAll(input InsId id);
            Transaction allStores[$] = {committedStores, stores};
            Transaction writers[$] = allStores.find with (item.owner == id);
            return (writers.size() == 0) ? EMPTY_TRANSACTION : writers[0];
        endfunction

    endclass



//////////////////
// General

    function automatic logic anyActiveB(input OpSlotAB s);
        foreach (s[i]) if (s[i].active) return 1;
        return 0;
    endfunction

    function automatic logic anyActiveF(input OpSlotAF s);
        foreach (s[i]) if (s[i].active) return 1;
        return 0;
    endfunction
    
    
    function automatic OpSlotB TMP_translateFrontToRename(input OpSlotF op);
        return '{
            active: op.active,
            mid: -1,
            adr: op.adr,
            bits: op.bits
        };
    endfunction;

    function automatic OpSlotAB TMP_front2rename(input OpSlotAF ops);
        OpSlotAB res;
        foreach (ops[i]) res[i] = TMP_translateFrontToRename(ops[i]);
        return res;
    endfunction;


    // Mem handling

    function automatic logic memOverlap(input Dword wa, input AccessSize sizeA, input Dword wb, input AccessSize sizeB);
        Dword aEnd = wa + Dword'(sizeA); // Exclusive end
        Dword bEnd = wb + Dword'(sizeB); // Exclusive end
        
        if ($isunknown(wa) || $isunknown(wb)) return 0;

        return (wa < bEnd && wb < aEnd);
    endfunction
    
    // is a inside b
    function automatic logic memInside(input Dword wa, input AccessSize sizeA, input Dword wb, input AccessSize sizeB);
        Mword aEnd = wa + Dword'(sizeA); // Exclusive end
        Mword bEnd = wb + Dword'(sizeB); // Exclusive end
        
        if ($isunknown(wa) || $isunknown(wb)) return 0;
       
        return (wa >= wb && aEnd <= bEnd);
    endfunction




    function automatic IqLevels getBufferAccepts(input IqLevels levels);
        IqLevels res = '{
            iqRegular:   levels.iqRegular <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH,
            iqFloat:     levels.iqFloat <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH,
            iqBranch:    levels.iqBranch <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH,
            iqMem:       levels.iqMem <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH,
            iqStoreData: levels.iqStoreData <= ISSUE_QUEUE_SIZE - 3*FETCH_WIDTH
        };
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

    function automatic Mword loadValue(input Mword w, input UopName uop);
        case (uop)
             UOP_mem_ldi: return w;
             UOP_mem_ldib: return Mword'(w[7:0]);
             UOP_mem_ldf,
             UOP_mem_lds: return w;

             UOP_mem_sti,
             UOP_mem_stib,
             UOP_mem_stf,
             UOP_mem_sts: return 0;
            
            default: $fatal(2, "Wrong op");
        endcase
    endfunction

    function automatic Mword fetchLineBase(input Mword adr);
        return adr & ~(4*FETCH_WIDTH-1);
    endfunction;

endpackage
