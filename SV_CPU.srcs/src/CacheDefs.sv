

package CacheDefs;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    
    import AbstractSim::*;
    import Insmap::*;


    typedef Word FetchGroup_N[FETCH_WIDTH];

    typedef enum {
        CR_INVALID, // Address illegal
            CR_NOT_MAPPED, // page table walk finds no mapping entry
        CR_TLB_MISS,
        CR_TAG_MISS,
        CR_HIT,
        CR_MULTIPLE
    } CacheReadStatus;
    
    typedef struct {
        logic allowed;
    } InstructionLineDesc;
    
    typedef struct {
        logic allowed;
            logic canRead;
            logic canWrite;
            logic canExec;
            logic cached;
    } DataLineDesc;

    localparam DataLineDesc DEFAULT_DATA_LINE_DESC = '{0, 0, 0, 0, 0};

    typedef struct {
        logic active;
        CacheReadStatus status;
        InstructionLineDesc desc;        
        FetchGroup_N words;
    } InstructionCacheOutput;
    
    localparam InstructionCacheOutput EMPTY_INS_CACHE_OUTPUT = '{
        0,
        CR_INVALID,
        '{0},
        '{default: 'x}
    };
    

    typedef struct {
        logic active;
        CacheReadStatus status;
        DataLineDesc desc;        
        Mword data;
    } DataCacheOutput;
    
    localparam DataCacheOutput EMPTY_DATA_CACHE_OUTPUT = '{
        0,
        CR_INVALID,
        DEFAULT_DATA_LINE_DESC,
        'x
    };



//////////////////


    typedef struct {
        logic active;
            logic store;            
            logic uncachedReq;
        Mword adr;
        AccessSize size;
    } DataReadReq;

    localparam DataReadReq EMPTY_READ_REQ = '{0, 0, 0, 'x, SIZE_NONE};


    // Write buffer
    // TODO: eplace with SQ entry struct?
    typedef struct {
        logic active;
        InsId mid;
        logic cancel;
        logic sys;
        logic uncached;
        Mword adr;
        Mword val;
        AccessSize size;
    } StoreQueueEntry;

    localparam StoreQueueEntry EMPTY_SQE = '{0, -1, 0, 'x, 'x, 'x, 'x, SIZE_NONE};

    typedef struct {
        logic req;
        Mword adr;
        Mword value;
        AccessSize size;
        logic uncached;
    } MemWriteInfo;
    
    localparam MemWriteInfo EMPTY_WRITE_INFO = '{0, 'x, 'x, SIZE_NONE, 'x};


   
//////////////////
// Cache specific

    typedef Dword EffectiveAddress;

    localparam int PAGE_SIZE = 4096;

    localparam int V_INDEX_BITS = 12;
    localparam int V_ADR_HIGH_BITS = $size(EffectiveAddress) - V_INDEX_BITS;
    
    typedef logic[V_INDEX_BITS-1:0] VirtualAddressLow;
    typedef logic[$size(EffectiveAddress)-1:V_INDEX_BITS] VirtualAddressHigh;

    localparam int PHYS_ADR_BITS = 40;

    typedef logic[PHYS_ADR_BITS-1:V_INDEX_BITS] PhysicalAddressHigh;
    typedef VirtualAddressLow PhysicalAddressLow;

    // Caches
    localparam int BLOCK_SIZE = 64;
    
    localparam int BLOCK_OFFSET_BITS = $clog2(BLOCK_SIZE);
    
    typedef logic[$size(EffectiveAddress)-1:BLOCK_OFFSET_BITS] BlockBaseD;
    
    localparam int WAY_SIZE = 4096; // TODO: specific for each cache?
    
    
    
    localparam int BLOCKS_PER_WAY = WAY_SIZE/BLOCK_SIZE;    

    function automatic VirtualAddressLow adrLow(input EffectiveAddress adr);
        return adr[V_INDEX_BITS-1:0];
    endfunction

    function automatic VirtualAddressHigh adrHigh(input EffectiveAddress adr);
        return adr[$size(EffectiveAddress)-1:V_INDEX_BITS];
    endfunction

    function automatic BlockBaseD blockBaseD(input EffectiveAddress adr);
        return adr[$size(EffectiveAddress)-1:BLOCK_OFFSET_BITS];
    endfunction


    typedef struct {
        EffectiveAddress adr;
        AccessSize size;
        VirtualAddressHigh aHigh;
        VirtualAddressLow aLow;
        int block;
        int blockOffset;
        logic unaligned;
        logic blockCross;
        logic pageCross;
    } AccessInfo;

    localparam AccessInfo DEFAULT_ACCESS_INFO = '{
        adr: 'x,
        size: SIZE_NONE,
        aHigh: 'x,
        aLow: 'x,
        block: -1,
        blockOffset: -1,
        unaligned: 'x,
        blockCross: 'x,
        pageCross: 'x 
    };


    typedef struct {
        logic present; // TLB hit
        VirtualAddressHigh vHigh;
        PhysicalAddressHigh pHigh;
            Mword phys;
        DataLineDesc desc;
    } Translation;

    localparam Translation DEFAULT_TRANSLATION = '{
        present: 0,
        vHigh: 'x,
        pHigh: 'x,
            phys: 'x,
        desc: DEFAULT_DATA_LINE_DESC
    };



    function automatic AccessInfo analyzeAccess(input EffectiveAddress adr, input AccessSize accessSize);
        AccessInfo res;
        
        VirtualAddressLow aLow = adrLow(adr);
        VirtualAddressHigh aHigh = adrHigh(adr);
        
        int block = aLow / BLOCK_SIZE;
        int blockOffset = aLow % BLOCK_SIZE;
        int byteSize = accessSize;
        
        if ($isunknown(adr)) return DEFAULT_ACCESS_INFO;

        res.aHigh = aHigh;
        res.aLow = aLow;        
        res.adr = adr;
        res.size = accessSize;
        
        res.block = block;
        res.blockOffset = blockOffset;
        
        res.unaligned = (aLow % byteSize) > 0;
        res.blockCross = (blockOffset + byteSize) > BLOCK_SIZE;
        res.pageCross = (aLow + byteSize) > PAGE_SIZE;

        return res;
    endfunction


endpackage
