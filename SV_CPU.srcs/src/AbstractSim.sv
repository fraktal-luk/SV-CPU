
package AbstractSim;
    
    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    import UopList::*;


    // Uarch specific
    localparam int FETCH_QUEUE_SIZE = 8;
    localparam int BC_QUEUE_SIZE = 64;

    localparam int N_REGS_INT = 128;
    localparam int N_REGS_FLOAT = 128;

    localparam int ISSUE_QUEUE_SIZE = 24;

    localparam int ROB_SIZE = 128;
    
    localparam int LQ_SIZE = 80;
    localparam int SQ_SIZE = 80;
    localparam int BQ_SIZE = 32;

    localparam int FETCH_WIDTH = 4;
    localparam int RENAME_WIDTH = 4;
    
    localparam int DISPATCH_WIDTH = RENAME_WIDTH;


    localparam logic IN_ORDER = 0;

    localparam int FW_FIRST = -2 + 0;
    localparam int FW_LAST = 1;

    // DB specific
        localparam int TRACKED_ID = -2;


////////////////////////////
    // Core structures

    typedef int InsId;  // Implem detail
    typedef InsId IdQueue[$]; // Implem detail

    typedef struct {
        logic active;
        InsId id;
        Mword adr;
        Word bits;
    } OpSlot;

    localparam OpSlot EMPTY_SLOT = '{'0, -1, 'x, 'x};
    
    typedef OpSlot OpSlotA[RENAME_WIDTH];
    

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
        
        CO_break,
        
        
            CO_dummy
        
    } ControlOp;
    
    typedef struct {
        logic active;
        InsId id;
        ControlOp cOp;
        logic redirect;
            logic sigOk;
            logic sigWrong;
        Mword adr;
        Mword target;
    } EventInfo;
    
    localparam EventInfo EMPTY_EVENT_INFO = '{0, -1, CO_none,  /*0, 0,*/ 0, 0, 0, 'x, 'x};
    localparam EventInfo RESET_EVENT =      '{1, -1, CO_reset, /*0, 1,*/ 1, 0, 0, 'x, IP_RESET};
    localparam EventInfo INT_EVENT =        '{1, -1, CO_int,   /*1, 0,*/ 1, 0, 0, 'x, IP_INT};

    typedef struct {
        int iqRegular;
        int iqFloat;
        int iqBranch;
        int iqMem;
        int iqSys;
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
        InsId producers[3];
    } InsDependencies;



    class BranchCheckpoint;
    
        function new(input InsId id, input CpuState state, input SimpleMem mem, 
                    input int intWr[32], input int floatWr[32],
                    input int intMapR[32], input int floatMapR[32],
                    input IndexSet indexSet);
            this.id = id;
            this.state = state;
            this.mem = new();
            this.mem.copyFrom(mem);
            this.intWriters = intWr;
            this.floatWriters = floatWr;
            this.intMapR = intMapR;
            this.floatMapR = floatMapR;
            this.inds = indexSet;
        endfunction

        InsId id;
        CpuState state;
        SimpleMem mem;
        int intWriters[32];
        int floatWriters[32];
        int intMapR[32];
        int floatMapR[32];
        IndexSet inds;
    endclass


    class RegisterTracker #(parameter int N_REGS_INT = 128, parameter int N_REGS_FLOAT = 128);
            
        // FUTURE: move to RegisterDomain after moving functiona for num free etc.
        typedef enum {FREE, SPECULATIVE, STABLE
        } PhysRegState;
        
        typedef struct {
            PhysRegState state;
            InsId owner;
        } PhysRegInfo;    

        class RegisterDomain#(
            parameter int N_REGS = N_REGS_INT,
            parameter logic IGNORE_R0 = 1
        );
            localparam PhysRegInfo REG_INFO_FREE = '{state: FREE, owner: -1};
            localparam PhysRegInfo REG_INFO_STABLE = '{state: STABLE, owner: -1};
    
        
            PhysRegInfo info[N_REGS] = '{0: REG_INFO_STABLE, default: REG_INFO_FREE};        
            Mword regs[N_REGS] = '{0: 0, default: 'x};
            logic ready[N_REGS] = '{0: 1, default: '0};
            
            int MapR[32] = '{default: 0};
            int MapC[32] = '{default: 0};
            
            InsId writersR[32] = '{default: -1};
            InsId writersC[32] = '{default: -1};
            
            function automatic logic ignoreV(input int vReg);
                return (vReg == 0) && IGNORE_R0;
            endfunction
            
            function automatic int reserve(input AbstractInstruction ins, input InsId id);
                int vDest = ins.dest;
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
  
            function automatic void commit(input AbstractInstruction ins, input InsId id, input logic normal);
                int vDest = ins.dest;
                int ind[$] = info.find_first_index with (item.owner == id);
                int pDest = ind[0];
                int pDestPrev = MapC[vDest];
 
                if (ignoreV(vDest)) return;
                
                if (normal) begin
                    writersC[vDest] = id;
                    MapC[vDest] = pDest;
                    info[pDest] = '{STABLE, -1};
                    
                    releaseRegister(pDestPrev);
                end
                else begin
                    releaseRegister(pDest);
                end

            endfunction

            function automatic void setReady(input InsId id);
                int pDest = findDest(id);
                ready[pDest] = 1;
            endfunction;
    
            function automatic void writeValue(input AbstractInstruction ins, input InsId id, input Mword value);
                int pDest = findDest(id);
                if (ignoreV(ins.dest)) return;
                regs[pDest] = value;
            endfunction            
 
            function automatic int findFree();
                int res[$] = info.find_first_index with (item.state == FREE);
                return res[0];
            endfunction
    
            function automatic int findDest(input InsId id);
                int inds[$] = info.find_first_index with (item.owner == id);
                return inds.size() > 0 ? inds[0] : -1;
            endfunction;


            function automatic void flush(input InsId id);
                int inds[$] = info.find_index with (item.state == SPECULATIVE && item.owner > id);

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


            function automatic void restoreCP(input int intM[32], input InsId intWriters[32]);
                MapR = intM;
                writersR = intWriters;
            endfunction
        
            function automatic void restoreStable();
                MapR = MapC;
                writersR = writersC;
            endfunction
    
            function automatic void restoreReset();
                MapR = MapC;
                writersR = '{default: -1};

                foreach (info[i])
                    if (info[i].state == STABLE)
                        regs[i] = 0;
            endfunction           
        endclass


        RegisterDomain#(N_REGS_INT, 1) ints = new();
        RegisterDomain#(N_REGS_INT, 0) floats = new(); // FUTURE: change to FP reg num

          
        function automatic int reserve(input AbstractInstruction abs, input InsId id);
            if (hasIntDest(abs)) return ints.reserve(abs, id);
            if (hasFloatDest(abs)) return  floats.reserve(abs, id);  
            return -1;
        endfunction


        function automatic void commit(input AbstractInstruction abs, input InsId id, input abnormal);            
            if (hasIntDest(abs)) ints.commit(abs, id, !abnormal);      
            if (hasFloatDest(abs)) floats.commit(abs, id, !abnormal);
        endfunction

        function automatic void writeValue(input AbstractInstruction abs, input InsId id, input Mword value);
            if (hasIntDest(abs)) begin
                ints.setReady(id);
                ints.writeValue(abs, id, value);
            end
            if (hasFloatDest(abs)) begin
                floats.setReady(id);
                floats.writeValue(abs, id, value);
            end
        endfunction


        function automatic InsDependencies getArgDeps(input AbstractInstruction abs);
            int mapInt[32] = ints.MapR;
            int mapFloat[32] = floats.MapR;
            int sources[3] = '{-1, -1, -1};
            InsId producers[3] = '{-1, -1, -1};
            SourceType types[3] = '{SRC_CONST, SRC_CONST, SRC_CONST}; 
            
            string typeSpec = parsingMap[abs.fmt].typeSpec;
            
            foreach (sources[i]) begin
                if (typeSpec[i + 2] == "i") begin
                    sources[i] = mapInt[abs.sources[i]];
                    types[i] = sources[i] ? SRC_INT: SRC_ZERO;
                    producers[i] = ints.info[sources[i]].owner;
                end
                else if (typeSpec[i + 2] == "f") begin
                    sources[i] = mapFloat[abs.sources[i]];
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
 
 
        function automatic void restoreCP(input int intM[32], input int floatM[32], input InsId intWriters[32], input InsId floatWriters[32]);
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
            int specInds[$] = ints.info.find_index with (item.state == SPECULATIVE);
            int stabInds[$] = ints.info.find_index with (item.state == STABLE);    
            return freeInds.size();
        endfunction        
        
        function automatic int getNumFreeFloat();
            int freeInds[$] = floats.info.find_index with (item.state == FREE);
            int specInds[$] = floats.info.find_index with (item.state == SPECULATIVE);
            int stabInds[$] = floats.info.find_index with (item.state == STABLE);            
            return freeInds.size();
        endfunction

    endclass


    function automatic logic wordOverlap(input Mword wa, input Mword wb);
        Mword aEnd = wa + 4; // Exclusive end
        Mword bEnd = wb + 4; // Exclusive end
        
        if ($isunknown(wa) || $isunknown(wb)) return 0;
        if (wb >= aEnd || wa >= bEnd) return 0;
        else return 1;
    endfunction

    function automatic logic wordInside(input Mword wa, input Mword wb);
        Mword aEnd = wa + 4; // Exclusive end
        Mword bEnd = wb + 4; // Exclusive end
        
        if ($isunknown(wa) || $isunknown(wb)) return 0;
       
        return (wa >= wb && aEnd <= bEnd);
    endfunction
    

    typedef struct {
        InsId owner;
        Mword adr;
        Mword val;
        Mword adrAny; 
    } Transaction;


    class MemTracker;
        Transaction transactions[$];
        Transaction stores[$];
        Transaction loads[$];
        Transaction committedStores[$]; // Not included in transactions
        
        function automatic void add(input InsId id, input AbstractInstruction ins, input Mword argVals[3]);
            Mword effAdr = calculateEffectiveAddress(ins, argVals);
    
            if (isStoreMemIns(ins)) begin 
                Mword value = argVals[2];
                addStore(id, effAdr, value);
            end
            if (isLoadMemIns(ins)) begin
                addLoad(id, effAdr, 'x);
            end
            if (isStoreSysIns(ins)) begin 
                Mword value = argVals[2];
                addStoreSys(id, effAdr, value);
            end
            if (isLoadSysIns(ins)) begin
                addLoadSys(id, effAdr, 'x);
            end
        endfunction

        function automatic void addStore(input InsId id, input Mword adr, input Mword val);
            transactions.push_back('{id, adr, val, adr});
            stores.push_back('{id, adr, val, adr});
        endfunction

        function automatic void addLoad(input InsId id, input Mword adr, input Mword val);            
            transactions.push_back('{id, adr, val, adr});
            loads.push_back('{id, adr, val, adr});
        endfunction

        function automatic void addStoreSys(input InsId id, input Mword adr, input Mword val);
            transactions.push_back('{id, 'x, val, adr});
            stores.push_back('{id, 'x, val, adr});
        endfunction

        function automatic void addLoadSys(input InsId id, input Mword adr, input Mword val);            
            transactions.push_back('{id, 'x, val, adr});
            loads.push_back('{id, 'x, val, adr});
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

        function automatic InsId checkWriter(input InsId id);
            Transaction allStores[$] = {committedStores, stores};
        
            Transaction read[$] = transactions.find_first with (item.owner == id); 
            Transaction writers[$] = allStores.find with (item.adr == read[0].adr && item.owner < id);
            return (writers.size() == 0) ? -1 : writers[$].owner;
        endfunction

            function automatic InsId checkWriter_Overlap(input InsId id);
                Transaction allStores[$] = {committedStores, stores};
            
                Transaction read[$] = transactions.find_first with (item.owner == id); 
                Transaction writers[$] = allStores.find with (wordOverlap(item.adr, read[0].adr) && item.owner < id);
                return (writers.size() == 0) ? -1 : writers[$].owner;
            endfunction

            function automatic InsId checkWriter_Inside(input InsId id);
                Transaction allStores[$] = {committedStores, stores};
            
                Transaction read[$] = transactions.find_first with (item.owner == id); 
                Transaction writers[$] = allStores.find with (wordInside(read[0].adr, item.adr) && item.owner < id);
                return (writers.size() == 0) ? -1 : writers[$].owner;
            endfunction

        function automatic Mword getStoreValue(input InsId id);
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

    function automatic logic anyActive(input OpSlotA s);
        foreach (s[i]) if (s[i].active) return 1;
        return 0;
    endfunction


endpackage
