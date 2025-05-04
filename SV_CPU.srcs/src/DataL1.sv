
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
    //DataBlock filledBlocks[Mword]; // Set of blocks in "force data miss" region which are "filled" and will not miss again 
    // CAREFUL: below only for addresses in the range for TLB miss tests 
    Translation filledMappings[Mword]; // Set of blocks in "force data miss" region which are "filled" and will not miss again 


    // Simple array for simple test cases, without blocks, transaltions etc
            Mbyte staticContent[PAGE_SIZE]; // So far this corresponds to way 0


    function automatic logic isUncachedRange(input Mword adr);
        return adr >= uncachedSubsystem.UNCACHED_BASE && adr < uncachedSubsystem.UNCACHED_BASE + $size(uncachedSubsystem.uncachedArea);
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
        
        filledMappings.delete();

        dataFillEngine.resetBlockFills();
        tlbFillEngine.resetBlockFills();

        uncachedSubsystem.uncachedArea = '{default: 0};
        uncachedSubsystem.UNC_reset();
    endtask


            
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


    function automatic Mword readSized(input Mword val, input AccessSize size);
        if (size == SIZE_1) begin
            Mbyte byteVal = val;
            return Mword'(byteVal);
        end
        else if (size == SIZE_4) return val;
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

        // Cache array:
        begin
            AccessInfo aInfo = analyzeAccess(wrInfo.padr, wrInfo.size);
            logic written0 = tryWriteWay(blocksWay0, aInfo, wrInfo);
            logic written1 = tryWriteWay(blocksWay1, aInfo, wrInfo);
        end

    endtask


    function automatic logic tryWriteWay(ref DataWay way, input AccessInfo aInfo, input MemWriteInfo wrInfo);
        // TODO: may cross blocks
        DataCacheBlock block = way[aInfo.block];
        Dword accessPbase = getBlockBaseD(wrInfo.padr);

        if (block != null && accessPbase === block.pbase) begin
            if (aInfo.size == SIZE_1) way[aInfo.block].writeByte(aInfo.blockOffset, wrInfo.value);
            if (aInfo.size == SIZE_4) way[aInfo.block].writeWord(aInfo.blockOffset, wrInfo.value);
            return 1;
        end
        return 0;
    endfunction


    ///////////////////////////////


    ////////////////////////////////////
    // Presence & allocation functions 
    //
    function automatic logic isTlbPresent(input Mword adr);
        Mword pageBase = (adr/PAGE_SIZE)*PAGE_SIZE;
        return isStaticTlbRange(adr) || filledMappings.exists(pageBase);
    endfunction

    function automatic void allocInDynamicRange(input Mword adr);
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



    function automatic DataCacheOutput doReadAccess(input AccessInfo aInfo, input Translation tr, input AccessDesc aDesc, input logic hit0, input logic hit1, input Mword arrayValue);
        DataCacheOutput res;        
        
        if (aDesc.uncachedReq) begin end
        else if (aDesc.uncachedCollect) begin // Completion of uncached read
            res = '{1, CR_HIT, tr.desc, uncachedSubsystem.uncachedOutput};
        end
        else if (aDesc.sys) begin end
        else if (!tr.present) begin // TLB miss
            res.status = CR_TLB_MISS;
        end
        else if (isUncachedRange(tr.phys)) begin // Just detected uncached access, tr.desc indicates uncached
            // TODO: change above condiiton to desc field check
            res = '{1, CR_HIT, tr.desc, 'x};
        end
        else if (!hit0 && !hit1) begin // data miss
           res = '{1, CR_TAG_MISS, tr.desc, 'x};
        end
        else begin
            Mword readValue = readSized(arrayValue, aInfo.size);
            res = '{1, CR_HIT, tr.desc, readValue};
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

                ReadResult result0 = readWay(blocksWay0, acc, tr);
                ReadResult result1 = readWay(blocksWay1, acc, tr);

                DataCacheOutput thisResult = doReadAccess(acc, tr, aDesc, result0.valid, result1.valid, selectWay(result0, result1));

                accessDescs_Reg[p] <= aDesc;
                translations_Reg[p] <= tr;
                readOut[p] <= thisResult;

                // Cache arr
                    readResultsWay0[p] <= result0;
                    readResultsWay1[p] <= result1;

            end
        end

    endtask


    function automatic ReadResult readWay(input DataWay way, input AccessInfo aInfo, input Translation tr);
        // TODO: may cross blocks
        
        DataCacheBlock block = way[aInfo.block];
        Dword accessPbase = getBlockBaseD(tr.phys);
        
        if (block == null) return '{0, 'x};

        begin
            // TODO: handle all possible sizes
            logic hit0 = (accessPbase === block.pbase);
            Mword val0 = aInfo.size == SIZE_1 ? block.readByte(aInfo.blockOffset) : block.readWord(aInfo.blockOffset);                    

                if (aInfo.blockCross) begin
                    $error("Read crossing block at %x", aInfo.adr);
                end

            return '{hit0, val0};
        end
    endfunction


    function automatic Mword selectWay(input ReadResult res0, input ReadResult res1);
        return res0.valid ? res0.value : res1.value;
    endfunction



    always @(posedge clk) begin
        handleReads();

        if (dataFillEngine.notifyFill) allocInDynamicRange(dataFillEngine.notifiedAdr);
        if (tlbFillEngine.notifyFill) allocInTlb(tlbFillEngine.notifiedAdr);

        doCachedWrite(TMP_writeReqs[0]);
    end

endmodule

