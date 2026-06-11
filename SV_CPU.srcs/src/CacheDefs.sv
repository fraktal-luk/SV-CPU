
package CacheDefs;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    import EmulationMemories::*;
    import EmulationDefs::*;
    
    import AbstractSim::*;
    import Insmap::*;




    class DataCacheBlock;
        logic valid;
        Dword pbase;
        logic lock;
        Mbyte array[BLOCK_SIZE];

        // @endian
        function automatic Dword readDword(input int offset);
            localparam int ACCESS_SIZE = 8;
            
            assert (offset >= 0 && offset < BLOCK_SIZE) else $fatal("Block offset outside block");

            if (offset + ACCESS_SIZE - 1 >= BLOCK_SIZE) begin
                Mbyte lastDword[ACCESS_SIZE] = array[BLOCK_SIZE-ACCESS_SIZE : BLOCK_SIZE-1];
                Mbyte pastDword[ACCESS_SIZE] = '{default: 'x};
                Mbyte crossingQword[2*ACCESS_SIZE] = {lastDword, pastDword}; 
                int internalOffset = offset - (BLOCK_SIZE-ACCESS_SIZE);
                Mbyte chosenDword[ACCESS_SIZE] = crossingQword[internalOffset +: ACCESS_SIZE];
                Dword wval = {<<8{chosenDword}};
                return (wval);
            end
            begin
                Mbyte chosenDword[ACCESS_SIZE] = array[offset +: ACCESS_SIZE];
                Dword wval = {<<8{chosenDword}};
                return (wval);
            end
        endfunction

        // @endian
        function automatic Mword readWord(input int offset);
            Dword tmp = readDword(offset);
            return Word'(tmp >> 0 * 32);
        endfunction

        // @endian
        function automatic Mword readByte(input int offset);
            Dword tmp = readDword(offset);
            return Mbyte'(tmp >> 0 * 8*7);
        endfunction

        // @endian
        function automatic void writeDword(input int offset, input Dword value, input Dword mask);
            localparam int ACCESS_SIZE = 8;
            Mbyte val[ACCESS_SIZE] = {<<8{value}};
            Mbyte msk[ACCESS_SIZE] = {<<8{mask}};
            
            foreach (val[i]) begin
                if (offset + i >= BLOCK_SIZE) break;
                if (msk[i] != 0) array[offset + i] = val[i];
            end
        endfunction

        // @endian
        function automatic void writeWord(input int offset, input Word value);
            Dword val = value;
            Dword mask =  'hffffffff;
            writeDword(offset, val, mask);
            return;
        endfunction

        // @endian
        function automatic void writeByte(input int offset, input Mbyte value);
            Dword val = value;
            Dword mask = 'hff;
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
            Mword val0 = 'x;

            case (aDesc.size)    
                SIZE_1: val0 = block.readByte(aDesc.blockOffset);
                SIZE_4: val0 = block.readWord(aDesc.blockOffset);
                SIZE_8: val0 = block.readDword(aDesc.blockOffset);
                default: ;
            endcase

            return '{1, -1, tag0, block.getLock(), val0};
        end
    endfunction

    function automatic ReadResult selectWayResultArray(input Translation tr, input ReadResult results[]);
        Dword trBase = getBlockBaseD(tr.padr);
        ReadResult res = '{0, -1, 'x, 'x, 'x};

        foreach (results[i]) begin
            if (results[i].valid && getBlockBaseD(results[i].tag) === trBase) begin
                res = results[i];
                res.way = i;
                return res;
            end
        end

        return res;
    endfunction

    function automatic void lockInWay(input DataCacheBlock way[], input AccessDesc aDesc);
        DataCacheBlock block = way[aDesc.blockIndex];
        if (block == null) return;
        if (block.getLock()) block.clearLock(); // If already locked, clear it and fail locking
        else block.setLock();
    endfunction

    function automatic void unlockInWay(input DataCacheBlock way[], input AccessDesc aDesc);
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
        if (wrInfo.size == SIZE_8) block.writeDword(offset, wrInfo.value, 'hffffffffffffffff);
        return 1;
    endfunction


    function automatic logic tryFillWay(ref DataWay way, input Dword adr, input SparseDataMemory mem);
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
        block.array = mem.readBlock(adr);

        return 1;
    endfunction


    function automatic void initBlocksWay(ref DataWay way, input Dword baseVadr, input SparseDataMemory dataMem);
        foreach (way[i]) begin
            Dword padr = baseVadr + i*BLOCK_SIZE;

            DataCacheBlock newBlock = new();

            way[i] = newBlock;
            newBlock.valid = 1;
            newBlock.pbase = padr;
            newBlock.lock = 0;

            if (dataMem.usedBlocks.exists(padr)) begin
                foreach (newBlock.array[a])
                    newBlock.array[a] = dataMem.readByte(i*BLOCK_SIZE + a);
            end
            else
                newBlock.array = '{default: 0};
        end
    endfunction


    // @endian
    function automatic WordArray readWayContent(input DataWay way);
        WordArray res = new [1024];
        foreach (way[i]) begin
            for (int wi = 0; wi < BLOCK_SIZE/4; wi++)
                res[BLOCK_SIZE/4 * i + wi] = {<<8{way[i].array[4*wi +: 4]}};
        end

        return res;       
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
            FetchLine val0 = block.readLine(aDesc.blockOffset);                    
            if (aDesc.blockCross) $error("Read crossing block at %x", aDesc.vadr);
            return '{1, block.pbase, val0};
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
