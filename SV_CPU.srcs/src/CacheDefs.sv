

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

    localparam int PAGE_SIZE = 4096;


    class PageWriter#(type Elem = Mbyte, int ESIZE = 1, int BASE = 0);
        static
        function automatic void writeTyped(ref Mbyte arr[PAGE_SIZE], input Mword adr, input Elem val);
            Mbyte wval[ESIZE] = {>>{val}};
            arr[(adr - BASE) +: ESIZE] = wval;
        endfunction
        
        static
        function automatic Elem readTyped(ref Mbyte arr[PAGE_SIZE], input Mword adr);                
            Mbyte chosen[ESIZE] = arr[(adr - BASE) +: ESIZE];
            Elem wval = {>>{chosen}};
            return wval;
        endfunction
    endclass


    // Write buffer
    // TODO: replace with SQ entry struct?
    typedef struct {
        logic active;
        InsId mid;
        logic cancel;
        logic sys;
        logic uncached;
        Mword adr;
        Dword padr;
        Mword val;
        AccessSize size;
    } StoreQueueEntry;

    localparam StoreQueueEntry EMPTY_SQE = '{0, -1, 0, 'x, 'x, 'x, 'x, 'x, SIZE_NONE};

    typedef struct {
        logic req;
        Mword adr;
        Dword padr;
        Mword value;
        AccessSize size;
        logic uncached;
    } MemWriteInfo;
    
    localparam MemWriteInfo EMPTY_WRITE_INFO = '{0, 'x, 'x, 'x, SIZE_NONE, 'x};


   
//////////////////
// Cache specific

    typedef Dword EffectiveAddress;


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

    function automatic BlockBaseD blockBaseD(input Dword adr);
        return adr[$size(Dword)-1:BLOCK_OFFSET_BITS];
    endfunction

    
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

    function automatic Dword getPageBaseD(input Dword adr);
        Dword res = adr;
        res[V_INDEX_BITS-1:0] = 0;
        return res;
    endfunction

    function automatic Mword getPageBaseM(input Mword adr);
        Mword res = adr;
        res[V_INDEX_BITS-1:0] = 0;
        return res;
    endfunction


    typedef struct {
        EffectiveAddress adr;
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



      // Mem uop packet:
      //  general - id, poison, status?
      //    transaction description:
      //      - basic part: static type of transfer (load/store, 'system', aq-rel, nontemporal?), size, vadr 
      //      - translation (and adr check?): page present, page desc (includes access rights and 'cached'), padr
      //       - status considerations: unaligned, block cross, page cross, error(kind?)/refetch  -- most can be derived from 'basic part'
      //      - data: present or not (or multiple hit?), value 
     

     // basic info
     typedef struct {
        logic active;

        logic sys;
        logic store;
        logic uncachedReq;
        logic uncachedCollect;
        logic uncachedStore;
        
         // FUTURE: access rights of this uop?
        AccessSize size;
        Mword vadr;
        logic unaligned;
        logic blockCross;
        logic pageCross;
     } AccessDesc;

    localparam AccessDesc DEFAULT_ACCESS_DESC = '{0, 'z, 'z, 'z, 'z, 'z, SIZE_NONE, 'z, 'z, 'z, 'z};


    typedef struct {
        logic present; // TLB hit
        DataLineDesc desc;
        Dword phys; // TODO: rename to 'padr'
    } Translation;

    localparam Translation DEFAULT_TRANSLATION = '{
        present: 0,
        desc: DEFAULT_DATA_LINE_DESC,
        phys: 'x
    };




    function automatic AccessInfo analyzeAccess(input EffectiveAddress adr, input AccessSize accessSize);
        AccessInfo res;
        
        VirtualAddressLow aLow = adrLow(adr);
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


    class DataCacheBlock;
        logic valid;
        Mword vbase;
        Dword pbase;
        Mbyte array[BLOCK_SIZE];
        
        function automatic Word readWord(input int offset);
            localparam int ACCESS_SIZE = 4;
            
            if (offset + ACCESS_SIZE - 1 > BLOCK_SIZE) begin
                Mbyte chosenWord[ACCESS_SIZE] = '{default: 'x};
                Word wval;

                // Read byte by byte                
                foreach (chosenWord[i]) begin
                    if (offset + i >= BLOCK_SIZE) break;
                    chosenWord[i] = array[offset + i];
                end 
                
                wval = {>>{chosenWord}};
                  //  $error("extArray read %x", wval);
                return (wval);
            end
            begin
                Mbyte chosenWord[ACCESS_SIZE] = array[offset +: ACCESS_SIZE];
                Word wval = {>>{chosenWord}};
                return (wval);
            end
        endfunction


        function automatic void writeWord(input int offset, input Word value);
            localparam int ACCESS_SIZE = 4;
            
            if (offset + ACCESS_SIZE - 1 > BLOCK_SIZE) begin
                // Write byte by byte
                Mbyte wval[ACCESS_SIZE] = {>>{value}};
                
                foreach (wval[i]) begin
                    if (offset + i >= BLOCK_SIZE) break;
                    array[offset + i] = wval[i];
                end
            end
            begin
                Mbyte wval[ACCESS_SIZE] = {>>{value}};
                array[offset +: ACCESS_SIZE] = wval;
            end
        endfunction
    endclass


endpackage
