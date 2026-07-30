
package AbstractSim;
    
    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import EmulationDefs::*;
    import Emulation::*;
    import UopList::*;


    /////////////////////////////////////////
    // Implementation settings
    ////////////////////////////////////////////

    localparam int FETCH_QUEUE_SIZE = 16;
    localparam int BC_QUEUE_SIZE = 128;

    localparam int N_REGS_INT = 128;
    localparam int N_REGS_FLOAT = 128;

    localparam int ISSUE_QUEUE_SIZE = 24;

    localparam int ROB_SIZE = 128;
    localparam int ROB_WIDTH = 4;

    localparam int LQ_SIZE = 40;
    localparam int SQ_SIZE = 40;
    localparam int BQ_SIZE = 32;

    localparam int FETCH_WIDTH = 4;
    localparam int RENAME_WIDTH = 4;
    
    localparam int DISPATCH_WIDTH = RENAME_WIDTH;

    localparam int N_RENAME_STAGES = 2; // Number of stages between FQ and OOO buffers

    // General uarch defs
    localparam int N_INT_PORTS = 6;
    localparam int N_MEM_PORTS = 4;
    localparam int N_VEC_PORTS = 4;

    localparam int FW_FIRST = -2 + 0;
    localparam int FW_LAST = 1;


    localparam int N_WAYS_INS = 6;
    localparam int N_WAYS_DATA = 6;


    // Impl specific
    localparam int BLOCK_SIZE = 64;
    localparam int BLOCK_OFFSET_BITS = $clog2(BLOCK_SIZE);
    localparam int WAY_SIZE = 4096; // FUTURE: specific for each cache?
    localparam int BLOCKS_PER_WAY = WAY_SIZE/BLOCK_SIZE;    


    localparam int DATA_ARRAY_FILL_DELAY = 14;
    localparam int DATA_TLB_FILL_DELAY = 11;

    localparam int INS_ARRAY_FILL_DELAY = 14;
    localparam int INS_TLB_FILL_DELAY = 11;


////////////////////////////
    typedef int InsId;  // Implem detail

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

    // Defs for tracking, insMap
    typedef enum { SRC_ZERO, SRC_CONST, SRC_INT, SRC_FLOAT
    } SourceType;
    
    typedef struct {
        int sources[3];
        SourceType types[3];
        WriterId producers[3];
    } InsDependencies;

    localparam InsDependencies DEFAULT_INS_DEPS = '{sources: '{default: -1}, types: '{default: SRC_ZERO}, producers: '{default: UIDT_NONE}};



    function automatic UopName decodeUop(input AbstractInstruction ins);
        if (ins.def.o == O_fetchError) return UOP_ctrl_fetchError;

            if (ins.def.o == O_fpDisabled) return UOP_ctrl_fp_disabled;

        assert (OP_DECODING_TABLE.exists(ins.mnemonic)) else $fatal(2, "what instruction is this?? %p", ins.mnemonic);
        return OP_DECODING_TABLE[ins.mnemonic];
    endfunction


        // Transfer size in bytes
        typedef enum {
            SIZE_NONE = 0,
            SIZE_1 = 1,
            SIZE_4 = 4,
            SIZE_8 = 8,
            SIZE_INS_LINE = FETCH_WIDTH*4
        } AccessSize;


        typedef enum {
            CR_UNCACHED,
            CR_INVALID, // Address illegal
            CR_TLB_MISS,
            CR_NOT_ALLOWED,
            CR_TAG_MISS,
            CR_HIT
        } CacheReadStatus;


        typedef enum {
            MC_NONE,
            MC_NORMAL,
            MC_BARRIER,
            MC_UNCACHED,
            MC_AQ_REL,
            MC_SYS,

            MC_UPPER_B // block cross replay
            //MC_UPPER_P  // page cross replay
        } MemClass;


        typedef enum {
            ES_BEGIN,

            ES_OK,
            
            ES_UNALIGNED,
            
            ES_UNCACHED_1,
            ES_UNCACHED_2,

            ES_BARRIER_1,
            ES_AQ_REL_1,

            ES_SQ_MISS,
            ES_DATA_MISS,
            ES_TLB_MISS,
            
            ES_REFETCH, // cause refetch
            ES_CANT_FORWARD,
            
            ES_INSTANT_REPLAY,

            ES_LOWER_DONE,


            ES_ILLEGAL,
            ES_INVALID,
            ES_NONEXISTENT,

            ES_FP_INVALID,
            ES_FP_OVERFLOW
        } ExecStatus;

        typedef enum {
            BS_NONE,
            BS_NORMAL, // accepts renamed ops
            BS_WAIT,   // event to handle is present, don't accept new ops
            BS_HANDLING // event processing ongoing
        } BackendState;



        typedef struct {
            InsId owner;
            Mword adr;
            Mword val;
            Mword adrAny;
            Dword padr;
            AccessSize size;
            logic barrierF;
        } Transaction;

        localparam Transaction EMPTY_TRANSACTION = '{-1, 'x, 'x, 'x, 'x, SIZE_NONE, 'x};



        typedef struct {
            logic active;
            InsId mid;
            Mword adr;
            Word bits;
            logic first;
            logic branch;
            logic takenBranch;
            Mword predictedTarget;
        } OpSlotF;

        typedef OpSlotF OpSlotB;

        localparam OpSlotF EMPTY_SLOT_F = '{'0, -1, 'x, 'x, 'x, 'x};
        localparam OpSlotB EMPTY_SLOT_B = '{'0, -1, 'x, 'x, 'x, 'x};

        typedef OpSlotF OpSlotAF[FETCH_WIDTH];
        typedef OpSlotB OpSlotAB[RENAME_WIDTH];

        localparam OpSlotAF EMPTY_STAGE = '{default: EMPTY_SLOT_F};



        typedef struct {
            integer sct;
            logic[1:0] strHist[16];
            logic[1:0] recentHist[2];
        } TMP_PredState;

        localparam TMP_PredState DEFAULT_PRED_STATE = '{-1, '{default: 0}, '{default: 'z}}; 

        function automatic Mbyte TMP_bpEncode(input int index);
            if (index == -1) return 0;
            else if (index >= 2) return 3;
            else return index + 1;
        endfunction

        function automatic TMP_PredState updatePred(input TMP_PredState prev, input logic[1:0] last);
            TMP_PredState res = prev;

            if (res.recentHist[1] !== 'z) begin
                res.sct++;
                res.strHist = {res.recentHist[1], res.strHist[0:14]};
            end

            res.recentHist = {last, res.recentHist[0]};

            return res;
        endfunction

        function automatic TMP_PredState replacePred(input TMP_PredState prev, input logic[1:0] last);
            TMP_PredState res = prev;
            res.recentHist[0] = last;
            return res;
        endfunction


        function automatic logic TMP_getPrediction(input TMP_PredState pred);
            // TODO: generate prediction (use VADR too)
            return 'z;
        endfunction


        typedef struct {
            logic active;
            CacheReadStatus status;
            ProgramEvent evt;
            Mword vadr;
            Dword padr;
            OpSlotAF arr;
            TMP_PredState predState;
        } FrontStage;

        localparam FrontStage DEFAULT_FRONT_STAGE = '{0, CR_INVALID, PE_NONE, 'x, 'x, EMPTY_STAGE, DEFAULT_PRED_STATE};


        function automatic logic anyActiveB(input OpSlotAB s);
            foreach (s[i]) if (s[i].active) return 1;
            return 0;
        endfunction


    typedef struct {
        logic active;
        InsId eventMid;
        ProgramEvent etype;
        logic redirect;
        logic dir;  // 0|1 for branches, 'x for control events
        Mword adr;
        Mword target;
    } EventInfo;
    
    localparam EventInfo EMPTY_EVENT_INFO = '{0, -1, PE_NONE,  0, 'x, 'x, 'x};
    localparam EventInfo RESET_EVENT =      '{1, -1, PE_EXT_RESET, 1, 'x, 'x, IP_RESET};
    localparam EventInfo INT_EVENT =        '{1, -1, PE_EXT_INTERRUPT, 1, 'x, 'x, IP_INT};
    localparam EventInfo DB_EVENT =         '{1, -1, PE_EXT_DEBUG, 1, 'x, 'x, IP_DB_BREAK};


    typedef struct {
        logic active;
        InsId id;
        ProgramEvent etype;
    } EventDesc;

    localparam EventDesc EMPTY_EVENT_DESC = '{0, -1, PE_NONE};


    function automatic Mword takenTarget(input UopName uname, input Mword adr, input Mword args[3]);
        case (uname)
            UOP_br_z, UOP_br_nz:  return args[1];
            UOP_bc_z, UOP_bc_nz, UOP_bc_a, UOP_bc_l: return adr + args[1];  
            default: $fatal(2, "Wrong branch uop");
        endcase  
    endfunction

    function automatic Mword finalTarget(input UopName uname, input logic dir, input Mword regValue, input Mword bqTarget, input Mword bqLink);
        if (dir === 0) return bqLink;

        case (uname)
            UOP_br_z, UOP_br_nz:  return regValue;
            UOP_bc_z, UOP_bc_nz, UOP_bc_a, UOP_bc_l: return bqTarget;  
            default: $fatal(2, "Wrong branch uop");
        endcase 
    endfunction


    function automatic InsId replaceEvId(input InsId prev, input InsId next);
        if (prev == -1) return next;
        else if (next != -1 && prev > next) return next;
        else return prev;
    endfunction


    function automatic EventInfo getLateEvent(input EventInfo info, input Mword sr2, input Mword sr3);
        EventInfo res = EMPTY_EVENT_INFO;

        res.target = info.target;
        res.active = 1;
        res.eventMid = info.eventMid;
        res.etype = info.etype;
        res.redirect = 1;

        if (info.etype == PE_HW_RETE) res.target = sr2;
        if (info.etype == PE_HW_RETI) res.target = sr3;

        return res;
    endfunction


    task automatic checkUnimplementedInstruction(input AbstractInstruction ins);
        if (ins.def.o == O_halt) $error("halt not implemented");
    endtask


    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        /////////////////////////////////////////////////////////////////////////////////
        // Mem
        /////////////////////////////////////////////////////////////////////////////////

        typedef Translation TranslationA[N_MEM_PORTS];


        typedef struct {
            Dword adr;
            AccessSize size;
            int block;
            int blockOffset;
            logic unaligned;
            logic blockCross;
            logic pageCross;
        } AccessInfo;

        localparam AccessInfo DEFAULT_ACCESS_INFO = '{
            adr: 'x,
            size: SIZE_NONE,
            block: -1,
            blockOffset: -1,
            unaligned: 'x,
            blockCross: 'x,
            pageCross: 'x 
        };


         typedef struct {
            logic active;

            logic invalid;

            logic sys;
            logic store;
            logic uncachedReq;
            logic uncachedCollect;
            logic uncachedStore;
            logic acq;
            logic rel;

            AccessSize size;
            Mword vadr;
            int blockIndex;
            int blockOffset;
            logic unaligned;
            logic blockCross;
            logic pageCross;
            int shift; // Applies to block-crossing: bytes to shift at combining 
         } AccessDesc;

        localparam AccessDesc DEFAULT_ACCESS_DESC = '{0, 0, 'z, 'z, 'z, 'z, 'z, 'z, 'z, SIZE_NONE, 'z, -1, -1, 'z, 'z, 'z};


        function automatic Mword loadValue(input Mword w, input UopName uop);
            case (uop)
                UOP_mem_ldi: return (w);
                UOP_mem_ldid: return w;
                UOP_mem_ldib: return Mword'(w[7:0]);
                UOP_mem_ldf: return (w);
                UOP_mem_ldfd: return w;
                UOP_mem_lds: return w;
                
                UOP_mem_lda: return w;

                UOP_mem_sti,
                UOP_mem_stid,
                UOP_mem_stib,
                UOP_mem_stf,
                UOP_mem_stfd,
                UOP_mem_sts: return 0;

                UOP_mem_stc: return 0;

                default: $fatal(2, "Wrong op");
            endcase
        endfunction

        // @endian
        function automatic Mword combineLoadValues(input Mword saved, input Mword w, input int shift, input UopName uop);
            Dword cw = w; // combined word
            Dword shifted = w << 8*(8-shift);

            foreach (cw[i]) begin
                if (saved[i] === 'x) cw[i] = shifted[i];
                else cw[i] = saved[i];
            end

            return loadValue(cw, uop);
        endfunction


        function automatic logic memOverlap(input Dword wa, input AccessSize sizeA, input Dword wb, input AccessSize sizeB);
            Dword aEnd = wa + Dword'(sizeA); // Exclusive end
            Dword bEnd = wb + Dword'(sizeB); // Exclusive end
            
            if ($isunknown(wa) || $isunknown(wb)) return 0;
            return (wa < bEnd && wb < aEnd);
        endfunction
        
        // is a inside b
        function automatic logic memInside(input Dword wa, input AccessSize sizeA, input Dword wb, input AccessSize sizeB);
            Dword aEnd = wa + Dword'(sizeA); // Exclusive end
            Dword bEnd = wb + Dword'(sizeB); // Exclusive end
            
            if ($isunknown(wa) || $isunknown(wb)) return 0;
            return (wa >= wb && aEnd <= bEnd);
        endfunction


        function automatic AccessSize getTransactionSize(input UopName uname);
            if (uname inside {UOP_mem_ldib, UOP_mem_stib}) return SIZE_1;
            else if (uname inside {UOP_mem_ldid, UOP_mem_stid, UOP_mem_ldfd, UOP_mem_stfd}) return SIZE_8;
            else if (isMemUop(uname)) return SIZE_4;
            else return SIZE_NONE;
        endfunction


        function automatic Translation translateAddress(input AccessDesc aDesc, input Translation tq[$], input logic MMU_EN);    
            Mword adr = aDesc.vadr;
            Translation res = DEFAULT_TRANSLATION;
            Translation found[$];

            if (!aDesc.active || $isunknown(adr)) return DEFAULT_TRANSLATION;
            if (!MMU_EN) return '{present: 1, vadr: adr, desc: '{1, 1, 1, 1, 0}, padr: adr};

            found = tq.find with (item.vadr == getPageBaseM(adr));

            assert (found.size() <= 1) else $fatal(2, "multiple hit in tlb\n%p", tq);

            if (found.size() == 0) begin
                res.vadr = adr; // It's needed because TLB fill is based on this adr
                return res;
            end

            res = found[0];

            res.vadr = adr;
            res.padr = res.padr + (adr - getPageBaseM(adr));

            return res;
        endfunction


        ////////////////////////////////////
        // Dep on BLOCK_SIZE

        function automatic Dword getBlockBaseD(input Dword adr);
            Dword res = adr;
            res[BLOCK_OFFSET_BITS-1:0] = 0;
            return res;
        endfunction

        function automatic Mword getBlockBaseM(input Mword adr);
            Mword res = adr;
            res[BLOCK_OFFSET_BITS-1:0] = 0;
            return res;
        endfunction


        function automatic int getBlockIndex(input Dword adr);
            return (adr % WAY_SIZE)/BLOCK_SIZE;
        endfunction

        function automatic AccessInfo analyzeAccess(input Dword adr, input AccessSize accessSize);
            AccessInfo res;

            Dword aLow = adr % WAY_SIZE;
            int block = aLow / BLOCK_SIZE;
            int blockOffset = aLow % BLOCK_SIZE;

            if ($isunknown(adr)) return DEFAULT_ACCESS_INFO;

            res.adr = adr;
            res.size = accessSize;
            
            res.block = block;
            res.blockOffset = blockOffset;
            
            res.unaligned = (aLow % accessSize) > 0;
            res.blockCross = (blockOffset + accessSize) > BLOCK_SIZE;
            res.pageCross = (aLow + accessSize) > PAGE_SIZE;

            return res;
        endfunction



        ////////////////////////////////////////////////////////////////////

    typedef struct {
        int iqRegular;
        int iqFloat;
        int iqBranch;
        int iqMem;
        int iqStoreData;
    } IqLevels;


    typedef struct {
        int rename;
        int renameG;
        int bq;
        int lq;
        int sq;
    } IndexSet;

    typedef struct {
        InsId load;
        InsId store;
        InsId mbLoadF;
        InsId mbStoreF;
        InsId mbF;

        InsId loadAq;
        InsId storeRel;
    } MarkerSet;



    class BranchCheckpoint;
        function new(input InsId id,
                    input WriterId intWr[32], input WriterId floatWr[32],
                    input int intMapR[32], input int floatMapR[32],
                    input IndexSet indexSet, input MarkerSet markerSet,
                    input int branchInd,
                    input Emulator em, input TMP_PredState predState);
            this.id = id;
            this.intWriters = intWr;
            this.floatWriters = floatWr;
            this.intMapR = intMapR;
            this.floatMapR = floatMapR;
            this.inds = indexSet;
            this.markers = markerSet;
            this.branchInd = branchInd;
            this.emul = em.copyCore();
            this.emul.dataMem = new em.dataMem;
            this.predState = predState;
        endfunction

        InsId id;
        WriterId intWriters[32];
        WriterId floatWriters[32];
        int intMapR[32];
        int floatMapR[32];
        IndexSet inds;
        int branchInd; // branch index within block (from 0)
        MarkerSet markers;
        Emulator emul;
        TMP_PredState predState;
        logic predDir;
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



    class MemTracker;
        Transaction transactions[$];
        Transaction stores[$];
        Transaction loads[$];
        Transaction committedStores[$]; // Not included in transactions
        
        function automatic void add(input InsId id, input UopName uname, input AbstractInstruction ins, input Mword argVals[3],  input Dword padr);
            Mword effAdr = calculateEffectiveAddress(ins, argVals);
            AccessSize size = getTransactionSize(uname);

            if (isLoadAqIns(ins)) begin
                addLoadAq(id, effAdr, padr, 'x, size);
                return;
            end

            if (isMemBarrierIns(ins)) begin
                addBarrier(id, 'x, 'x, 'x, SIZE_NONE, isMemBarrierFwIns(ins));
            end

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

        function automatic void addLoadAq(input InsId id, input Mword adr, input Dword padr, input Mword val, input AccessSize size);
            transactions.push_back('{id, adr, val, adr, padr, size, 0});
            loads.push_back('{id, adr, val, adr, padr, size, 0});
            stores.push_back('{id, adr, val, adr, padr, size, 1});
        endfunction

        function automatic void addBarrier(input InsId id, input Mword adr, input Dword padr, input Mword val, input AccessSize size, input logic isFw);
            transactions.push_back('{id, adr, val, adr, padr, size, isFw});
            stores.push_back('{id, adr, val, adr, padr, size, isFw});
        endfunction

        function automatic void addStore(input InsId id, input Mword adr, input Dword padr, input Mword val, input AccessSize size);
            transactions.push_back('{id, adr, val, adr, padr, size, 0});
            stores.push_back('{id, adr, val, adr, padr, size, 0});
        endfunction

        function automatic void addLoad(input InsId id, input Mword adr, input Dword padr, input Mword val, input AccessSize size);
            transactions.push_back('{id, adr, val, adr, padr, size, 0});
            loads.push_back('{id, adr, val, adr, padr, size, 0});
        endfunction

        function automatic void addStoreSys(input InsId id, input Mword adr, input Mword val);
            transactions.push_back('{id, 'x, val, adr, 'x, SIZE_NONE, 0});
            stores.push_back('{id, 'x, val, adr, 'x, SIZE_NONE, 0});
        endfunction

        function automatic void addLoadSys(input InsId id, input Mword adr, input Mword val);            
            transactions.push_back('{id, 'x, val, adr, 'x, SIZE_NONE, 0});
            loads.push_back('{id, 'x, val, adr, 'x, SIZE_NONE, 0});
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

        function automatic logic checkIssue(input UidT uid);
            Transaction checked[$] = transactions.find_first with (item.owner == U2M(uid));

            Transaction allStores[$] = {committedStores, stores};
            Transaction barriers[$] = allStores.find with (item.barrierF === 1);
            Transaction activeBarriers[$] = barriers.find with (item.owner < U2M(uid));

            assert (activeBarriers.size() == 0) return 0; else $fatal(2, "Barrier violation by %p (barrier %p)", uid, activeBarriers[0].owner);
            return 1;
        endfunction

    endclass



    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Frontend
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function automatic Mword fetchLineBase(input Mword adr);
        return adr & ~(4*FETCH_WIDTH-1);
    endfunction;


    function automatic OpSlotAF clearBeforeStart(input OpSlotAF st, input Mword expectedTarget);
        OpSlotAF res = st;
        Mword expectedTargetFloor = expectedTarget;
        logic anyFound = 0;
        expectedTargetFloor[1:0] = 0;

        foreach (res[i]) begin
            logic active = res[i].active && !$isunknown(res[i].adr) && (res[i].adr >= expectedTargetFloor);
            
            res[i].active = active;
            res[i].first = active & !anyFound;

            anyFound |= active;
        end

        return res;       
    endfunction


    function automatic OpSlotAF clearAfterBranch(input OpSlotAF st, input int branchSlot);
        OpSlotAF res = st;

        if (branchSlot == -1) return res;

        foreach (res[i])
            if (i > branchSlot) res[i].active = 0;

        return res;        
    endfunction


    function automatic FrontStage makeStage_IP(input Mword target, input logic on);
        FrontStage res = DEFAULT_FRONT_STAGE;
        Mword baseAdr = fetchLineBase(target);
        logic already = 0;
        Mword targetFloor = target;
        targetFloor[1:0] = 0;

        res.active = on;
        res.status = CR_HIT;
        res.vadr = target;

        foreach (res.arr[i]) begin
            Mword adr = baseAdr + 4*i;
            logic elemActive = !$isunknown(target) && (adr >= targetFloor) && !already;  
            res.arr[i] = '{elemActive, -1, adr, 'x, 0, 0, 0, 'x};
        end
        
        return res;
    endfunction



    function automatic FrontStage getFrontStageF2(input FrontStage fs, input Mword expectedTarget);
        FrontStage res = fs;

        logic predictions[FETCH_WIDTH] = '{default: 0}; // TODO: should be provided by BP

        logic branches[FETCH_WIDTH] = '{default: 0};
        logic unconditional[FETCH_WIDTH] = '{default: 0};
        logic predictedTaken[FETCH_WIDTH] = '{default: 0};

        OpSlotAF arrayF2 = clearBeforeStart(fs.arr, expectedTarget);

        if (!fs.active) return DEFAULT_FRONT_STAGE;

        foreach (fs.arr[i]) begin
            AbstractInstruction ins = decodeAbstract(fs.arr[i].bits);
            branches[i] = isBranchIns(ins);
            unconditional[i] = isBranchAlwaysIns(ins);
            predictedTaken[i] = arrayF2[i].active && ((branches[i] && predictions[i]) || unconditional[i]);
        end

        begin
            int firstTaken[$] = predictedTaken.find_first_index with (item === 1);

            if (firstTaken.size() != 0) begin
                arrayF2 = clearAfterBranch(arrayF2, firstTaken[0]);
                arrayF2[firstTaken[0]].takenBranch = 1;
            end
        end

        res.padr = 'x;
        res.arr = arrayF2;

        return res;
    endfunction


    function automatic Mword TMP_trgFromArr(input FrontStage fs);
        Mword target = fetchLineBase(fs.vadr) + 4*FETCH_WIDTH;
        
        foreach (fs.arr[i]) begin
            if (fs.arr[i].takenBranch) begin
                AbstractInstruction ins = decodeAbstract(fs.arr[i].bits);
                target = fs.arr[i].adr + Mword'(ins.sources[1]);
                break;
            end
        end

        return target;
    endfunction


    function automatic Mbyte TMP_predictionFromArr(input FrontStage fs);
        logic anyBranch = 0;

        foreach (fs.arr[i]) begin
            if (fs.arr[i].branch) anyBranch = 1;
            if (fs.arr[i].takenBranch) return TMP_bpEncode(i);
        end

        return anyBranch ? 0 : 'z;
    endfunction



    function automatic FrontStage makeStageUnc_IP(input Mword target, input logic on, input Mword prevAdr, input logic guardPageCross);
        FrontStage res = DEFAULT_FRONT_STAGE;
        logic pageCross = (getPageBaseM(target) !== getPageBaseM(prevAdr));

        res.active = on && !(guardPageCross && pageCross);
        res.status = CR_HIT;
        res.vadr = target;
        res.padr = target;

        res.arr[0] = '{1, -1, target, 'x, 0, 0, 0, 'x};

        return res;
    endfunction


    function automatic FrontStage getFrontStageF2_U(input FrontStage fs, input logic ENABLE_FRONT_BRANCHES);
        FrontStage res = fs;
        OpSlotF slot0 = fs.arr[0];

        AbstractInstruction ins = decodeAbstract(slot0.bits);
        logic takeBranch = fs.active && (fs.status == CR_HIT) && slot0.active && ENABLE_FRONT_BRANCHES && isBranchAlwaysIns(ins);

        if (takeBranch) slot0.predictedTarget = slot0.adr + Mword'(ins.sources[1]);
        else slot0.predictedTarget = slot0.adr + 4;

        slot0.takenBranch = takeBranch;

        res.padr = 'x;
        res.arr[0] = slot0;

        return res;
    endfunction


    //////////////////////////////////////////////////////////////////////
    // Core general
    //////////////////////////////////////////////////////////////////////


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


        // For routing to IQs
        typedef struct {
            logic active;
            UopId uid;
        } TMP_Uop;

        localparam TMP_Uop TMP_UOP_NONE = '{0, UID_NONE};


        typedef struct {
            TMP_Uop regular[RENAME_WIDTH];
            TMP_Uop multiply[RENAME_WIDTH];
            TMP_Uop branch[RENAME_WIDTH];
            TMP_Uop idivider[RENAME_WIDTH];
            TMP_Uop float[RENAME_WIDTH];
            TMP_Uop fdivider[RENAME_WIDTH];
            TMP_Uop mem[RENAME_WIDTH];
            TMP_Uop storeData[RENAME_WIDTH];
        } RoutedUops;

        localparam RoutedUops DEFAULT_ROUTED_UOPS = '{
            regular: '{default: TMP_UOP_NONE},
            multiply: '{default: TMP_UOP_NONE},
            branch: '{default: TMP_UOP_NONE},
            idivider: '{default: TMP_UOP_NONE},
            float: '{default: TMP_UOP_NONE},
            fdivider: '{default: TMP_UOP_NONE},
            mem: '{default: TMP_UOP_NONE},
            storeData: '{default: TMP_UOP_NONE}
        };


        // DCache specific

        typedef struct {
            logic req;
            Mword adr;
            Dword padr;
            Mword value;
            AccessSize size;
            logic uncached;
        } MemWriteInfo;

        localparam MemWriteInfo EMPTY_WRITE_INFO = '{0, 'x, 'x, 'x, SIZE_NONE, 'x};


        typedef struct {
            logic active;
            CacheReadStatus status;
            logic lock;
            Mword data;
        } DataCacheOutput;

        localparam DataCacheOutput EMPTY_DATA_CACHE_OUTPUT = '{
            0,
            CR_INVALID,
            'x,
            'x
        };

        typedef struct {
            logic valid;
            integer way;
            Dword tag;
            logic locked;
            Mword value;
        } ReadResult;


endpackage
