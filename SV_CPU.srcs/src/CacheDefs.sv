
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
        CR_NOT_ALLOWED,
        CR_TAG_MISS,
        CR_HIT,
        CR_MULTIPLE,
        CR_UNCACHED
    } CacheReadStatus;
    
    typedef struct {
        logic allowed;
    } InstructionLineDesc;



    typedef struct {
        logic active;
        CacheReadStatus status;
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
        Mword data;
    } DataCacheOutput;

    localparam DataCacheOutput EMPTY_DATA_CACHE_OUTPUT = '{
        0,
        CR_INVALID,
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
    
    typedef Mbyte DataBlock[BLOCK_SIZE];

    
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


     // basic info
     typedef struct {
        logic active;

        logic sys;
        logic store;
        logic uncachedReq;
        logic uncachedCollect;
        logic uncachedStore;

        AccessSize size;
        Mword vadr;
        int blockIndex;
        int blockOffset;
        logic unaligned;
        logic blockCross;
        logic pageCross;
     } AccessDesc;

    typedef struct {
        logic req;
        Mword adr;
        Dword padr;
        Mword value;
        AccessSize size;
        logic uncached;
    } MemWriteInfo;



    localparam AccessInfo DEFAULT_ACCESS_INFO = '{
        adr: 'x,
        size: SIZE_NONE,
        block: -1,
        blockOffset: -1,
        unaligned: 'x,
        blockCross: 'x,
        pageCross: 'x 
    };
    localparam AccessDesc DEFAULT_ACCESS_DESC = '{0, 'z, 'z, 'z, 'z, 'z, SIZE_NONE, 'z, -1, -1, 'z, 'z, 'z};
    localparam MemWriteInfo EMPTY_WRITE_INFO = '{0, 'x, 'x, 'x, SIZE_NONE, 'x};



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

                foreach (chosenWord[i]) begin
                    if (offset + i >= BLOCK_SIZE) break;
                    chosenWord[i] = array[offset + i];
                end 
                
                wval = {>>{chosenWord}};
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

                foreach (chosenWord[i]) begin
                    if (offset + i >= BLOCK_SIZE) break;
                    chosenWord[i] = array[offset + i];
                end 
                
                wval = {>>{chosenWord}};
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

    function automatic Mword readSized(input Mword val, input AccessSize size);
        if (size == SIZE_1) begin
            Mbyte byteVal = val;
            return Mword'(byteVal);
        end
        else if (size == SIZE_4) return val;
        else $error("Wrong access size");

        return 'x;
    endfunction



    localparam DataBlock CLEAN_BLOCK = '{default: 0};


    typedef struct {
        logic valid;
        Dword tag;
        Mword value;
    } ReadResult_N;

    typedef DataCacheBlock DataWay[BLOCKS_PER_WAY];

    function automatic ReadResult_N readWay(input DataCacheBlock way[], input AccessDesc aDesc);
        DataCacheBlock block = way[aDesc.blockIndex];

        if (block == null) return '{0, 'x, 'x};
        else begin
            Dword tag0 = block.pbase;
            Mword val0 = aDesc.size == SIZE_1 ? block.readByte(aDesc.blockOffset) : block.readWord(aDesc.blockOffset);

            if (aDesc.blockCross) $error("Read crossing block at %x", aDesc.vadr);
            return '{1, tag0, val0};
        end
    endfunction


    function automatic ReadResult_N selectWayResult(input ReadResult_N res0, input ReadResult_N res1, input Translation tr);
        Dword trBase = getBlockBaseD(tr.padr);
        if (res0.valid && getBlockBaseD(res0.tag) === trBase) return res0;
        if (res1.valid && getBlockBaseD(res1.tag) === trBase) return res1;
        return '{0, 'x, 'x};
    endfunction



    function automatic logic tryWriteWay(ref DataWay way, input MemWriteInfo wrInfo);
        AccessInfo aInfo = analyzeAccess(wrInfo.padr, wrInfo.size);
        DataCacheBlock block = way[aInfo.block];
        Dword accessPbase = getBlockBaseD(wrInfo.padr);

        if (block != null && accessPbase === block.pbase) begin
            if (aInfo.size == SIZE_1) way[aInfo.block].writeByte(aInfo.blockOffset, wrInfo.value);
            if (aInfo.size == SIZE_4) way[aInfo.block].writeWord(aInfo.blockOffset, wrInfo.value);
            return 1;
        end
        return 0;
    endfunction

    function automatic logic tryFillWay(ref DataWay way, input Dword adr);
        AccessInfo aInfo = analyzeAccess(adr, SIZE_1); // Dummy size
        DataCacheBlock block = way[aInfo.block];
        Dword fillPbase = getBlockBaseD(adr);

        if (block != null) begin
            $error("Block already filled at %x", fillPbase);
            return 0;
        end

        way[aInfo.block] = new();
        way[aInfo.block].valid = 1;
        way[aInfo.block].pbase = fillPbase;
        way[aInfo.block].array = '{default: 0};

        return 1;
    endfunction


    function automatic void initBlocksWay(ref DataWay way, input Mword baseVadr);
        foreach (way[i]) begin
            Mword vadr = baseVadr + i*BLOCK_SIZE;
            Dword padr = vadr;

            way[i] = new();
            way[i].valid = 1;
            way[i].vbase = vadr;
            way[i].pbase = padr;
            way[i].array = CLEAN_BLOCK;
        end
    endfunction

    typedef Translation TranslationA[N_MEM_PORTS];


endpackage
