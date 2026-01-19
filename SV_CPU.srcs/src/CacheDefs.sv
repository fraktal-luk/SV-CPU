
package CacheDefs;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    import EmulationMemories::*;
    import EmulationDefs::*;
    
    import AbstractSim::*;
    import Insmap::*;


    // Impl specific
    localparam int BLOCK_SIZE = 64;
    localparam int BLOCK_OFFSET_BITS = $clog2(BLOCK_SIZE);
    localparam int WAY_SIZE = 4096; // FUTURE: specific for each cache?
    localparam int BLOCKS_PER_WAY = WAY_SIZE/BLOCK_SIZE;    




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

    localparam AccessDesc DEFAULT_ACCESS_DESC = '{0, 'z, 'z, 'z, 'z, 'z, 'z, 'z, SIZE_NONE, 'z, -1, -1, 'z, 'z, 'z};


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

        Dword aLow = //adrLowD(adr);
                     adr % WAY_SIZE;
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


    class DataCacheBlock;
        logic valid;
        //Mword vbase;
        Dword pbase;
        logic lock;
        Mbyte array[BLOCK_SIZE];

        function automatic Dword readDword(input int offset);
            localparam int ACCESS_SIZE = 8;
            
            assert (offset >= 0 && offset < BLOCK_SIZE) else $fatal("Block offset outside block");

            if (offset + ACCESS_SIZE - 1 >= BLOCK_SIZE) begin
                Mbyte lastDword[ACCESS_SIZE] = array[BLOCK_SIZE-ACCESS_SIZE : BLOCK_SIZE-1];
                Mbyte pastDword[ACCESS_SIZE] = '{default: 'x};
                Mbyte crossingQword[2*ACCESS_SIZE] = {lastDword, pastDword}; 
                int internalOffset = offset - (BLOCK_SIZE-ACCESS_SIZE);
                Mbyte chosenDword[ACCESS_SIZE] = crossingQword[internalOffset +: ACCESS_SIZE];
                Dword wval = {>>{chosenDword}};
                return (wval);
            end
            begin
                Mbyte chosenDword[ACCESS_SIZE] = array[offset +: ACCESS_SIZE];
                Dword wval = {>>{chosenDword}};
                return (wval);
            end
        endfunction

        function automatic Mword readWord(input int offset);
            Dword tmp = readDword(offset);
            return Word'(tmp >> 32);
        endfunction

        function automatic Mword readByte(input int offset);
            Dword tmp = readDword(offset);
            return Mbyte'(tmp >> 8*7);
        endfunction


        function automatic void writeDword(input int offset, input Dword value, input Dword mask);
            localparam int ACCESS_SIZE = 8;
            Mbyte val[ACCESS_SIZE] = {>>{value}};
            Mbyte msk[ACCESS_SIZE] = {>>{mask}};
            
            foreach (val[i]) begin
                if (offset + i >= BLOCK_SIZE) break;
                if (msk[i] != 0) array[offset + i] = val[i];
            end
        endfunction

        function automatic void writeWord(input int offset, input Word value);
            Dword val = {value,         32'h00000000};
            Dword mask =        'hffffffff00000000;
            writeDword(offset, val, mask);
            return;
        endfunction

        function automatic void writeByte(input int offset, input Mbyte value);
            Dword val = {value,   56'h00000000000000};
            Dword mask =        'hff00000000000000;
            writeDword(offset, val, mask);
            return;
        endfunction


        function automatic logic getLock();
            return lock;
        endfunction

        function automatic void setLock();
            lock = 1;
        endfunction

        function automatic void clearLock();
            lock = 0;
        endfunction

    endclass



    localparam Mbyte CLEAN_BLOCK[BLOCK_SIZE] = '{default: 0};

    typedef DataCacheBlock DataWay[BLOCKS_PER_WAY];


    function automatic ReadResult readWay(input DataCacheBlock way[], input AccessDesc aDesc);
        DataCacheBlock block = way[aDesc.blockIndex];

        if (block == null) return '{0, -1, 'x, 'x, 'x};
        else begin
            Dword tag0 = block.pbase;
            Mword val0 = aDesc.size == SIZE_1 ? block.readByte(aDesc.blockOffset) : block.readWord(aDesc.blockOffset);    
            return '{1, -1, tag0, block.getLock(), val0};
        end
    endfunction

    function automatic ReadResult selectWayResult(input ReadResult res0, input ReadResult res1, input Translation tr);
        Dword trBase = getBlockBaseD(tr.padr);
        ReadResult res = '{0, -1, 'x, 'x, 'x};
        if (res0.valid && getBlockBaseD(res0.tag) === trBase) begin
            res = res0;
            res.way = 0;
        end
        if (res1.valid && getBlockBaseD(res1.tag) === trBase) begin
            res = res1;
            res.way = 1;
        end
        return res;
    endfunction

    function automatic void TMP_lockWay(input DataCacheBlock way[], input AccessDesc aDesc);
        DataCacheBlock block = way[aDesc.blockIndex];

        if (block == null) return;

        if (block.getLock()) block.clearLock(); // If already locked, clear it and fail locking
        else block.setLock();
    endfunction

    function automatic void TMP_unlockWay(input DataCacheBlock way[], input AccessDesc aDesc);
        DataCacheBlock block = way[aDesc.blockIndex];
        if (block == null) return;
        block.clearLock(); // If already locked, clear it and fail locking
    endfunction


    function automatic logic tryWriteWay(ref DataWay way, input MemWriteInfo wrInfo);
        DataCacheBlock block = way[getBlockIndex(wrInfo.padr)];
        Dword accessPbase = getBlockBaseD(wrInfo.padr);
        int offset = wrInfo.padr - accessPbase;

        if (block == null || block.pbase !== accessPbase) return 0;

        if (wrInfo.size == SIZE_1) block.writeByte(offset, wrInfo.value);
        if (wrInfo.size == SIZE_4) block.writeWord(offset, wrInfo.value);
        return 1;
    endfunction

    function automatic logic tryFillWay(ref DataWay way, input Dword adr);
        int blockIndex = getBlockIndex(adr);

        DataCacheBlock block = way[blockIndex];
        Dword fillPbase = getBlockBaseD(adr);

        if (block != null) begin
            $error("Block already filled at %x", fillPbase);
            return 0;
        end

        block = new();

        way[blockIndex] = block;

        block.valid = 1;
        block.pbase = fillPbase;
        block.lock = 0;
        block.array = '{default: 0};

        return 1;
    endfunction


    function automatic void initBlocksWay(ref DataWay way, input Dword baseVadr);
        foreach (way[i]) begin
            Dword padr = baseVadr + i*BLOCK_SIZE;

            DataCacheBlock newBlock = new();

            way[i] = newBlock;
            newBlock.valid = 1;
            newBlock.pbase = padr;
            newBlock.lock = 0;
            newBlock.array = CLEAN_BLOCK;
        end
    endfunction



    ///////////////////////////////////////////////////////////////
    // ICache specific
    typedef Word FetchGroup[FETCH_WIDTH];

    typedef struct {
        logic active;
        CacheReadStatus status;
        DataLineDesc desc;       
        FetchGroup words;
    } InstructionCacheOutput;
    
    localparam InstructionCacheOutput EMPTY_INS_CACHE_OUTPUT = '{
        0,
        CR_INVALID,
        DEFAULT_DATA_LINE_DESC,
        '{default: 'x}
    };


    typedef Word FetchLine[FETCH_WIDTH];

    class InstructionCacheBlock;
        logic valid;
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


    typedef InstructionCacheBlock InsWay[BLOCKS_PER_WAY];
    
    typedef struct {
        logic valid;
        Dword tag;
        FetchLine value;
    } ReadResult_I;

    function automatic ReadResult_I readWay_I(input InsWay way, input AccessDesc aDesc);
        InstructionCacheBlock block = way[aDesc.blockIndex];

        if (block == null) return '{0, 'x, '{default: 'x}};
        begin
            logic hit0 = 1;
            FetchLine val0 = block.readLine(aDesc.blockOffset);                    
            if (aDesc.blockCross) $error("Read crossing block at %x", aDesc.vadr);
            return '{hit0, block.pbase, val0};
        end
    endfunction

   function automatic logic tryFillWay_I(ref InsWay way, input Dword adr, input PageBasedProgramMemory::Page page);
        int blockIndex = getBlockIndex(adr);
        InstructionCacheBlock block = way[blockIndex];
        Dword fillPbase = getBlockBaseD(adr);
        Dword fillPageBase = getPageBaseD(adr);

        assert (adr === getBlockBaseD(adr)) else $error("Allocating unaligned ins block: %x", adr);

        if (block != null) begin
            $error("Block already filled at %x", fillPbase);
            return 0;
        end

        block = new();

        way[blockIndex] = block;
        block.valid = 1;
        block.pbase = fillPbase;
        block.array = page[(fillPbase-fillPageBase)/4 +: BLOCK_SIZE/4];

        return 1;
    endfunction


    function automatic void initBlocksWay_I(ref InsWay way, input Mword baseVadr, input PageBasedProgramMemory::Page page);
        Dword basePadr = baseVadr;

        foreach (way[i]) begin
            Mword vadr = baseVadr + i*BLOCK_SIZE;
            Dword padr = vadr;
            
            InstructionCacheBlock block = new();

            way[i] = block;

            block.valid = 1;
            block.pbase = padr;
            block.array = page[(padr-basePadr)/4 +: BLOCK_SIZE/4];
        end
    endfunction

endpackage
