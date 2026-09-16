
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

    // Basic stuff

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


        typedef enum {
            ES_BEGIN,

            ES_OK,

            ES_UNALIGNED,            
            ES_UNCACHED_1, ES_UNCACHED_2,

            ES_BARRIER_1,
            ES_AQ_REL_1,

            ES_SQ_MISS, ES_DATA_MISS, ES_TLB_MISS,
            ES_CANT_FORWARD,
            
            ES_INSTANT_REPLAY,
            ES_LOWER_DONE,

            ES_ILLEGAL, ES_INVALID, ES_NONEXISTENT,

            ES_REFETCH, // cause refetch

            ES_FP_INVALID, ES_FP_DIV0, ES_FP_OVERFLOW, ES_FP_UNDERFLOW, ES_FP_INEXACT,
            ES_FP_OV_INEXACT, ES_FP_UND_INEXACT
        } ExecStatus;

        typedef enum {
            BS_NONE,
            BS_NORMAL, // accepts renamed ops
            BS_WAIT,   // event to handle is present, don't accept new ops
            BS_HANDLING // event processing ongoing
        } BackendState;


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



    function automatic logic needsReplay(input ExecStatus status);
        return status inside {ES_SQ_MISS, ES_UNCACHED_1, ES_UNCACHED_2,  ES_DATA_MISS,  ES_TLB_MISS, ES_BARRIER_1, ES_AQ_REL_1, ES_LOWER_DONE, ES_INSTANT_REPLAY};
    endfunction


    // 1 use in main core
    function automatic UopName decodeUop(input AbstractInstruction ins);
        if (ins.def.o == O_fetchError) return UOP_ctrl_fetchError;
        if (ins.def.o == O_fpDisabled) return UOP_ctrl_fp_disabled;
        if (ins.def.o == O_fail) $error("fail op:\n%p", ins);

        assert (OP_DECODING_TABLE.exists(ins.mnemonic)) else $fatal(2, "what instruction is this?? %p", ins.mnemonic);
        return OP_DECODING_TABLE[ins.mnemonic];
    endfunction




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


    function logic regsAccept(input int nI, input int nF);
        return nI > RENAME_WIDTH && nF > RENAME_WIDTH;
    endfunction

    function logic bcQueueAccepts(input int k);
        return k <= BC_QUEUE_SIZE - 2*FETCH_WIDTH; // 2 stages + FETCH_QUEUE entries, FETCH_WIDTH each
    endfunction


            // TODO: unneeded because UopId can represent empty
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


        typedef struct {
            UopId regular[RENAME_WIDTH];
            UopId multiply[RENAME_WIDTH];
            UopId branch[RENAME_WIDTH];
            UopId idivider[RENAME_WIDTH];
            UopId float[RENAME_WIDTH];
            UopId fdivider[RENAME_WIDTH];
            UopId mem[RENAME_WIDTH];
            UopId storeData[RENAME_WIDTH];
        } RoutedUops_N;

        localparam RoutedUops_N DEFAULT_ROUTED_UOPS_N = '{
            regular: '{default: UID_NONE},
            multiply: '{default: UID_NONE},
            branch: '{default: UID_NONE},
            idivider: '{default: UID_NONE},
            float: '{default: UID_NONE},
            fdivider: '{default: UID_NONE},
            mem: '{default: UID_NONE},
            storeData: '{default: UID_NONE}
        };


        /////////////////////////////////////////////////////////////////////////////////
        // Mem
        /////////////////////////////////////////////////////////////////////////////////

            // Transfer size in bytes
            typedef enum {
                SIZE_NONE = 0,
                SIZE_1 = 1,
                SIZE_4 = 4,
                SIZE_8 = 8,
                SIZE_INS_LINE = FETCH_WIDTH*4  // DEPENDS on fetch width
            } AccessSize;


            function automatic AccessSize getTransactionSize(input UopName uname);
                if (uname inside {UOP_mem_ldib, UOP_mem_stib}) return SIZE_1;
                else if (uname inside {UOP_mem_ldid, UOP_mem_stid, UOP_mem_ldfd, UOP_mem_stfd}) return SIZE_8;
                else if (isMemUop(uname)) return SIZE_4;
                else return SIZE_NONE;
            endfunction


            // Needed for frontend and data subsystem (implem)
            typedef enum {
                CR_UNCACHED,
                CR_INVALID, // Address illegal
                CR_TLB_MISS,
                CR_NOT_ALLOWED,
                CR_TAG_MISS,
                CR_HIT
            } CacheReadStatus;


            typedef enum { // (implem)
                MC_NONE,
                MC_NORMAL,
                MC_BARRIER,
                MC_UNCACHED,
                MC_AQ_REL,
                MC_SYS,

                MC_UPPER_B // block cross replay
                //MC_UPPER_P  // page cross replay
            } MemClass;


            typedef struct {   // (implem)
                InsId owner;
                Mword adr;
                Mword val;
                Mword adrAny;
                Dword padr;
                AccessSize size;
                logic barrierF;
            } Transaction;

            localparam Transaction EMPTY_TRANSACTION = '{-1, 'x, 'x, 'x, 'x, SIZE_NONE, 'x};



        //typedef Translation TranslationA[N_MEM_PORTS];




            // TODO: integrate into AccessDesc?
            typedef struct {
                Dword vadr;
                AccessSize size;
                int blockIndex;
                int blockOffset;
                logic unaligned;
                logic blockCross;
                logic pageCross;
            } AccessInfo;

        localparam AccessInfo DEFAULT_ACCESS_INFO = '{
            vadr: 'x,
            size: SIZE_NONE,
            blockIndex: -1,
            blockOffset: -1,
            unaligned: 'x,
            blockCross: 'x,
            pageCross: 'x 
        };


        // Widely used
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

                // Mword vadr;
                // AccessSize size;
                // int blockIndex;
                // int blockOffset;
                // logic unaligned;
                // logic blockCross;
                // logic pageCross;
            AccessInfo info;

            int shift; // Applies to block-crossing: bytes to shift at combining
        } AccessDesc;

        localparam AccessDesc DEFAULT_ACCESS_DESC = '{0, 0, 'z, 'z, 'z, 'z, 'z, 'z, 'z, DEFAULT_ACCESS_INFO, /*'z, SIZE_NONE, -1, -1, 'z, 'z, 'z,*/ 0};


        function automatic AccessInfo analyzeAccess(input Dword adr, input AccessSize accessSize);
            AccessInfo res;

            Dword aLow = adr % WAY_SIZE;
            int block = aLow / BLOCK_SIZE;
            int blockOffset = aLow % BLOCK_SIZE;

            if ($isunknown(adr)) return DEFAULT_ACCESS_INFO;

            res.vadr = adr;
            res.size = accessSize;
            
            res.blockIndex = block;
            res.blockOffset = blockOffset;
            
            res.unaligned = (aLow % accessSize) > 0;
            res.blockCross = (blockOffset + accessSize) > BLOCK_SIZE;
            res.pageCross = (aLow + accessSize) > PAGE_SIZE;

            return res;
        endfunction



        ////////////////////////////////////
        // Dep on BLOCK_SIZE   -  to CacheDefs?

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



            // DCache specific

            // Widely used
            typedef struct {
                logic req;
                Mword adr;
                Dword padr;
                Mword value;
                AccessSize size;
                logic uncached;
            } MemWriteInfo;

            localparam MemWriteInfo EMPTY_WRITE_INFO = '{0, 'x, 'x, 'x, SIZE_NONE, 'x};

            // Widely used
            typedef struct {
                logic active;
                CacheReadStatus status;
                logic lock;
                Mword data;
            } DataCacheOutput;

            localparam DataCacheOutput EMPTY_DATA_CACHE_OUTPUT = '{
                0, CR_INVALID, 'x, 'x
            };

        ////////////////////////////////////////////////////////////////////


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



        function automatic logic anyActiveB(input OpSlotAB s);
            foreach (s[i]) if (s[i].active) return 1;
            return 0;
        endfunction



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


endpackage
