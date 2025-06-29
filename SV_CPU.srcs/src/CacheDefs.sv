

package CacheDefs;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    import EmulationDefs::*;
    
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
        logic active;
        CacheReadStatus status;
        //InstructionLineDesc desc;
        DataLineDesc desc;       
        FetchGroup_N words;
    } InstructionCacheOutput;
    
    localparam InstructionCacheOutput EMPTY_INS_CACHE_OUTPUT = '{
        0,
        CR_INVALID,
        DEFAULT_DATA_LINE_DESC,
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
    
    localparam int WAY_SIZE = 4096; // FUTURE: specific for each cache?
    
    
    
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




    function automatic AccessInfo analyzeAccess(input Dword adr, input AccessSize accessSize);
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

        function automatic Word readByte(input int offset);
            localparam int ACCESS_SIZE = 1;
            
            if (offset + ACCESS_SIZE - 1 > BLOCK_SIZE) begin
                Mbyte chosenWord[ACCESS_SIZE] = '{default: 'x};
                Mbyte wval;

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
                Mbyte wval = {>>{chosenWord}};
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
        
        function automatic void writeByte(input int offset, input Mbyte value);
            localparam int ACCESS_SIZE = 1;
            
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

//                PageWriter#(Word, 4)::writeTyped(staticContent, adr, val);
//                PageWriter#(Mbyte, 1)::writeTyped(staticContent, adr, val);
        
//                return PageWriter#(Word, 4)::readTyped(staticContent, adr);
//                return Mword'(PageWriter#(Mbyte, 1)::readTyped(staticContent, adr));

    typedef Word FetchLine[FETCH_WIDTH];


    class InstructionCacheBlock;
        logic valid;
        Mword vbase;
        Dword pbase;
        Word array[BLOCK_SIZE/4];
    
       
        function automatic Word readWord(input int offset);            
            assert (offset % 4 == 0) else $error("Trying to read unaligned icache: %x", offset);
            
            return array[offset/4];
        endfunction        


        function automatic FetchLine readLine(input int offset);            
            assert (offset % (FETCH_WIDTH*4) == 0) else $error("Trying to read unaligned icache: %x", offset);
            
            return array[(offset/4) +: FETCH_WIDTH];
        endfunction
   
    endclass



endpackage
