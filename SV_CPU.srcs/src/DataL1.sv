
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;


module DataL1(
            input logic clk,
            input MemWriteInfo TMP_writeReqs[2],
            output Translation translationsOut[N_MEM_PORTS],
            output DataCacheOutput readOut[N_MEM_PORTS]
);

    // TLB
    localparam int DATA_TLB_SIZE = 32;
    localparam logic DONT_TRANSLATE = 1; // TMP

    localparam int WAY_SIZE = 4096;
    localparam int BLOCKS_PER_WAY = WAY_SIZE/BLOCK_SIZE;

    typedef Translation TranslationA[N_MEM_PORTS];

    Translation translations_T[N_MEM_PORTS];

    Translation translations_Reg[N_MEM_PORTS] = '{default: DEFAULT_TRANSLATION};
    AccessDesc accessDescs_Reg[N_MEM_PORTS] = '{default: DEFAULT_ACCESS_DESC};


        typedef struct {
            logic valid;
            Mword value;
        } ReadResult;

        ReadResult readResultsWay0[N_MEM_PORTS];
        ReadResult readResultsWay1[N_MEM_PORTS];


    typedef Mbyte DataBlock[BLOCK_SIZE];

    typedef logic LogicA[N_MEM_PORTS];
    typedef Mword MwordA[N_MEM_PORTS];
    typedef Dword DwordA[N_MEM_PORTS];
    
    LogicA dataFillEnA, tlbFillEnA;
    DwordA dataFillPhysA;
    MwordA tlbFillVirtA;

    UncachedSubsystem uncachedSubsystem(clk, TMP_writeReqs);
    DataFillEngine dataFillEngine(clk, translations_Reg, dataFillEnA, dataFillPhysA);
    DataFillEngine#(Mword, 11) tlbFillEngine(clk, translations_Reg, tlbFillEnA, tlbFillVirtA);

    typedef DataCacheBlock DataWay[BLOCKS_PER_WAY];
    DataCacheBlock blocksWay0[BLOCKS_PER_WAY];
    DataCacheBlock blocksWay1[BLOCKS_PER_WAY];

    localparam Mbyte CLEAN_BLOCK[BLOCK_SIZE] = '{default: 0};

    function automatic void initBlocksWay0();
        foreach (blocksWay0[i]) begin
            Mword vadr = i*BLOCK_SIZE;
            Dword padr = vadr;

            blocksWay0[i] = new();
            blocksWay0[i].valid = 1;
            blocksWay0[i].vbase = vadr;
            blocksWay0[i].pbase = padr;
            blocksWay0[i].array = '{default: 0};
        end
    endfunction

    function automatic void initBlocksWay1();
        blocksWay1 = '{default: null};
    endfunction


    // CAREFUL: below only for addresses in the range for data miss tests 
    DataBlock filledBlocks[Mword]; // Set of blocks in "force data miss" region which are "filled" and will not miss again 
    // CAREFUL: below only for addresses in the range for TLB miss tests 
    Translation filledMappings[Mword]; // Set of blocks in "force data miss" region which are "filled" and will not miss again 


    // Simple array for simple test cases, without blocks, transaltions etc
    Mbyte staticContent[PAGE_SIZE]; // So far this corresponds to way 0


    function automatic logic isUncachedRange(input Mword adr);
        return adr >= uncachedSubsystem.UNCACHED_BASE && adr < uncachedSubsystem.UNCACHED_BASE + $size(uncachedSubsystem.uncachedArea);
    endfunction

    function automatic logic isStaticDataRange(input Mword adr);
        return adr < $size(staticContent);
    endfunction

    function automatic logic isStaticTlbRange(input Mword adr);        
        return isUncachedRange(adr) // TEMP: uncached region is mapped by default
                || adr < 'h80000; // TEMP: Let's give 1M for static mappings
    endfunction


    task automatic reset();
            initBlocksWay0();
            initBlocksWay1();

        staticContent = '{default: 0};
        
        accessDescs_Reg <= '{default: DEFAULT_ACCESS_DESC};
        translations_Reg <= '{default: DEFAULT_TRANSLATION};
        readOut = '{default: EMPTY_DATA_CACHE_OUTPUT};


        filledBlocks.delete();
        
        filledMappings.delete();
        
        
        dataFillEngine.resetBlockFills();
        tlbFillEngine.resetBlockFills();

        uncachedSubsystem.uncachedArea = '{default: 0};
        uncachedSubsystem.UNC_reset();
    endtask



    ////////////////////////////////////
    // Specific write & read functions

    function automatic void writeToStaticRangeW(input Mword adr, input Mword val);
        PageWriter#(Word, 4)::writeTyped(staticContent, adr, val);
    endfunction

    function automatic void writeToStaticRangeB(input Mword adr, input Mbyte val);
        PageWriter#(Mbyte, 1)::writeTyped(staticContent, adr, val);
    endfunction

    function automatic Mword readWordStatic(input Mword adr);
        return PageWriter#(Word, 4)::readTyped(staticContent, adr);
    endfunction

    function automatic Mword readByteStatic(input Mword adr);
        return Mword'(PageWriter#(Mbyte, 1)::readTyped(staticContent, adr));
    endfunction


    function automatic void writeToDynamicRangeW(input Mword adr, input Mword val);
        localparam int ACCESS_SIZE = 4;
        
        Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
        PhysicalAddressLow physLow = adr % BLOCK_SIZE;

        Mbyte wval[ACCESS_SIZE] = {>>{val}};
        filledBlocks[physBlockBase][physLow +: ACCESS_SIZE] = wval;
    endfunction

    function automatic void writeToDynamicRangeB(input Mword adr, input Mbyte val);
        localparam int ACCESS_SIZE = 1;
        
        Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
        PhysicalAddressLow physLow = adr % BLOCK_SIZE;

        Mbyte wval[ACCESS_SIZE] = {>>{val}};
        filledBlocks[physBlockBase][physLow +: ACCESS_SIZE] = wval;
    endfunction


    function automatic Mword readWordDynamic(input DataBlock block, input int offset);
        localparam int ACCESS_SIZE = 4;

        Mbyte chosenWord[ACCESS_SIZE] = block[offset +: ACCESS_SIZE];
        Mword wval = {>>{chosenWord}};

        return (wval);
    endfunction

    function automatic Mword readByteDynamic(input DataBlock block, input int offset);
        localparam int ACCESS_SIZE = 1;

        Mbyte chosenWord[ACCESS_SIZE] = block[offset +: ACCESS_SIZE];
        Mbyte wval = {>>{chosenWord}};

        return (wval);
    endfunction

    /////////////////////////////////////////////////////////////////////////////
    // General read functions

    function automatic Mword readFromStaticRange(input Mword adr, input AccessSize size);
        if (size == SIZE_1) return readByteStatic(adr);
        else if (size == SIZE_4) return readWordStatic(adr);
        else $error("Wrong access size");

        return 'x;
    endfunction

    function automatic Mword readFromDynamicRange(input Mword adr, input AccessSize size);        
        Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
        DataBlock block = filledBlocks[physBlockBase];
        PhysicalAddressLow physLow = adr % BLOCK_SIZE;

        if (size == SIZE_1) return readByteDynamic(block, physLow);
        else if (size == SIZE_4) return readWordDynamic(block, physLow);
        else $error("Wrong access size");

        return 'x;
    endfunction


    
    task automatic doCachedWrite(input MemWriteInfo wrInfo);
        Mword adr = wrInfo.adr;
        Dword padr = wrInfo.padr;
        Mword val = wrInfo.value;

        if (!wrInfo.req) return;
        if (wrInfo.uncached) begin
            return;
        end

        if (isStaticDataRange(adr)) begin
            if (wrInfo.size == SIZE_1) writeToStaticRangeB(adr, val);
            if (wrInfo.size == SIZE_4) writeToStaticRangeW(adr, val);
        end
        else begin 
            if (wrInfo.size == SIZE_1) writeToDynamicRangeB(adr, val);
            if (wrInfo.size == SIZE_4) writeToDynamicRangeW(adr, val);
        end

        // Cache array:
        begin
            AccessInfo aInfo = analyzeAccess(wrInfo.padr, wrInfo.size);
            logic written0 = tryWriteWay(blocksWay0, aInfo, wrInfo);
            logic written1 = tryWriteWay(blocksWay1, aInfo, wrInfo);
        end

    endtask


    function automatic logic tryWriteWay(ref DataWay way, input AccessInfo aInfo, input MemWriteInfo wrInfo);
        DataCacheBlock block = way[aInfo.block];
        Dword accessPbase = getBlockBaseD(wrInfo.padr);

        if (block != null && accessPbase === block.pbase) begin
            way[aInfo.block].writeWord(aInfo.blockOffset, wrInfo.value);
            return 1;
        end
        return 0;
    endfunction


    ///////////////////////////////


    ////////////////////////////////////
    // Presence & allocation function 
    //
    function automatic logic isPhysPresent(input Mword adr);
        Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;
        return isUncachedRange(adr) || isStaticDataRange(adr) || filledBlocks.exists(physBlockBase);
    endfunction    

    function automatic logic isTlbPresent(input Mword adr);
        Mword pageBase = (adr/PAGE_SIZE)*PAGE_SIZE;
        return isStaticTlbRange(adr) || filledMappings.exists(pageBase);
    endfunction

    function automatic void allocInDynamicRange(input Mword adr);
        Mword physBlockBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;        
        filledBlocks[physBlockBase] = '{default: 0};
        
            tryFillWay(blocksWay1, adr);
    endfunction


    function automatic logic tryFillWay(ref DataWay way, input Mword adr);
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



    function automatic void allocInTlb(input Mword adr);
        Translation DUMMY;
        Mword pageBase = (adr/PAGE_SIZE)*PAGE_SIZE;
        
        filledMappings[pageBase] = DUMMY;            
    endfunction



    function automatic Translation translateAddress(input EffectiveAddress adr);
        Translation res;

        if ($isunknown(adr)) return res;

        if (!isTlbPresent(adr)) begin
            res.present = 0;
            return res;
        end

        // TMP: in "mapping always present" range:
        res.present = 1; // Obviously
        res.desc = '{allowed: 1, canRead: 1, canWrite: 1, canExec: 1, cached: 1};
        res.phys = {adrHigh(adr), adrLow(adr)};

        // TMP: uncached rnge
        if (isUncachedRange(adr))
            res.desc.cached = 0;

        return res;
    endfunction


    function automatic TranslationA getTranslations();
        TranslationA res = '{default: DEFAULT_TRANSLATION};

        foreach (theExecBlock.accessDescs[p]) begin
            AccessDesc aDesc = theExecBlock.accessDescs[p];
            if (!aDesc.active || $isunknown(aDesc.vadr)) continue;
            res[p] = translateAddress(aDesc.vadr);
        end
        return res;
    endfunction



    function automatic LogicA dataFillEnables();
        LogicA res = '{default: 0};
        foreach (readOut[p]) begin
            if (readOut[p].status == CR_TAG_MISS) begin
                res[p] = 1;
            end
        end
        return res;
    endfunction

    function automatic DwordA dataFillPhysical();
        DwordA res = '{default: 'x};
        foreach (readOut[p]) begin
            res[p] = translations_Reg[p].phys;
        end
        return res;
    endfunction


    function automatic LogicA tlbFillEnables();
        LogicA res = '{default: 0};
        foreach (readOut[p]) begin
            if (readOut[p].status == CR_TLB_MISS) begin
                res[p] = 1;
            end
        end
        return res;
    endfunction

    function automatic MwordA tlbFillVirtual();
        MwordA res = '{default: 'x};
        foreach (readOut[p]) begin
            res[p] = accessDescs_Reg[p].vadr;
        end
        return res;
    endfunction


    always_comb dataFillEnA = dataFillEnables();
    always_comb dataFillPhysA = dataFillPhysical();
    always_comb tlbFillEnA = tlbFillEnables();
    always_comb tlbFillVirtA = tlbFillVirtual();



    always_comb translations_T = getTranslations();

    assign translationsOut = translations_T;



    function automatic DataCacheOutput doReadAccess(input AccessInfo aInfo, input Translation tr, input AccessDesc aDesc);
        DataCacheOutput res;        
        
        if (aDesc.uncachedReq) begin end
        else if (aDesc.uncachedCollect) begin // Completion of uncached read
            res = '{1, CR_HIT, tr.desc, uncachedSubsystem.uncachedOutput};
        end
        else if (aDesc.sys) begin end
        else if (!tr.present) begin // TLB miss
            res.status = CR_TLB_MISS;
        end
        else if (!isPhysPresent(tr.phys)) begin // data miss
           res = '{1, CR_TAG_MISS, tr.desc, 'x};
        end
        else begin
            res = '{1, CR_HIT, tr.desc, 'x};
            if (isUncachedRange(tr.phys)) begin end
            else if (tr.phys <= $size(staticContent)) // Read from small array
                res.data = readFromStaticRange(tr.phys, aInfo.size);
            else
                res.data = readFromDynamicRange(tr.phys, aInfo.size);
        end

        return res;
    endfunction


    task automatic handleReads();
        accessDescs_Reg <= '{default: DEFAULT_ACCESS_DESC};
        translations_Reg <= '{default: DEFAULT_TRANSLATION};
        readOut <= '{default: EMPTY_DATA_CACHE_OUTPUT};

        foreach (theExecBlock.accessDescs[p]) begin
            AccessDesc aDesc = theExecBlock.accessDescs[p];
            Mword vadr = aDesc.vadr;

            readResultsWay0[p] <= '{'z, 'x};
            readResultsWay1[p] <= '{'z, 'x};

            if (!aDesc.active || $isunknown(vadr)) continue;
            else begin
                AccessInfo acc = analyzeAccess(vadr, aDesc.size);
                Translation tr = translations_T[p];
                DataCacheOutput thisResult = doReadAccess(acc, tr, aDesc);
                
                accessDescs_Reg[p] <= aDesc;
                translations_Reg[p] <= tr;
                readOut[p] <= thisResult;
                
                // Cache arr
                begin
                    ReadResult result0 = readWay(blocksWay0, acc, tr);
                    ReadResult result1 = readWay(blocksWay1, acc, tr);

                    readResultsWay0[p] <= result0;
                    readResultsWay1[p] <= result1;
                end

            end
        end

    endtask


    function automatic ReadResult readWay(input DataWay way, input AccessInfo aInfo, input Translation tr);
        DataCacheBlock block = way[aInfo.block];
        Dword accessPbase = getBlockBaseD(tr.phys);
        logic hit0 = (block != null && accessPbase === block.pbase);
        Mword val0 = block == null ? 'x : block.readWord(aInfo.blockOffset);                    

        return '{hit0, val0};
    endfunction



    always @(posedge clk) begin
        handleReads();

        if (dataFillEngine.notifyFill) allocInDynamicRange(dataFillEngine.notifiedAdr);
        if (tlbFillEngine.notifyFill) allocInTlb(tlbFillEngine.notifiedAdr);

        doCachedWrite(TMP_writeReqs[0]);
    end

endmodule

