
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import EmulationDefs::*;

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
    //DataCacheBlock blocksWay0[BLOCKS_PER_WAY];
    //DataCacheBlock blocksWay1[BLOCKS_PER_WAY];
    DataWay blocksWay0;
    DataWay blocksWay1;

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



        Translation TMP_tlb[Mword];
        Translation TMP_tlbL2[Mword];

        Translation translationTableL1[DATA_TLB_SIZE]; // DB

        
        function automatic void DB_fillTranslations();
            int i = 0;
            translationTableL1 = '{default: DEFAULT_TRANSLATION};
            foreach (TMP_tlb[a]) begin
                translationTableL1[i] = TMP_tlb[a];
                i++;
            end
        endfunction


    task automatic reset();
        accessDescs_Reg <= '{default: DEFAULT_ACCESS_DESC};
        translations_Reg <= '{default: DEFAULT_TRANSLATION};
        readOut = '{default: EMPTY_DATA_CACHE_OUTPUT};

        dataFillEngine.resetBlockFills();
        tlbFillEngine.resetBlockFills();

        uncachedSubsystem.UNC_reset();        
    endtask



    task automatic prefetchForTest();
        DataLineDesc cachedDesc = '{allowed: 1, canRead: 1, canWrite: 1, canExec: 0, cached: 1};
        DataLineDesc uncachedDesc = '{allowed: 1, canRead: 1, canWrite: 1, canExec: 0, cached: 0};

        Translation physPage0 = '{present: 1, vadr: 0, desc: cachedDesc, padr: 0};
        Translation physPage1 = '{present: 1, vadr: PAGE_SIZE, desc: cachedDesc, padr: 4096};
        Translation physPage2000 = '{present: 1, vadr: 'h2000, desc: cachedDesc, padr: 'h2000};
        Translation physPage20000000 = '{present: 1, vadr: 'h20000000, desc: cachedDesc, padr: 'h20000000};
        Translation physPageUnc = '{present: 1, vadr: 'h80000000, desc: uncachedDesc, padr: 'h80000000};

        TMP_tlb = '{0: physPage0, 1: physPage1, 'h2000: physPage2000, 'h80000000: physPageUnc};
        TMP_tlbL2 = '{'h20000000: physPage20000000};

        DB_fillTranslations();

        initBlocksWay0();
        initBlocksWay1(); 
    endtask 


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
        DataCacheBlock block = way[aInfo.block];
        Dword accessPbase = getBlockBaseD(wrInfo.padr);

        if (block != null && accessPbase === block.pbase) begin
            if (aInfo.size == SIZE_1) way[aInfo.block].writeByte(aInfo.blockOffset, wrInfo.value);
            if (aInfo.size == SIZE_4) way[aInfo.block].writeWord(aInfo.blockOffset, wrInfo.value);
            return 1;
        end
        return 0;
    endfunction


    ////////////////////////////////////
    // Presence & allocation functions 
    //
    function automatic void allocInDynamicRange(input Dword adr);
        tryFillWay(blocksWay1, adr);
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



    function automatic void allocInTlb(input Mword adr);
        Translation DUMMY;
        Mword pageBase = adr;
            
        assert (TMP_tlbL2.exists(pageBase)) else $error("Filling TLB but such mapping unknown: %x", pageBase);
        
        //translationVadrsL1[TMP_tlb.size()] = pageBase;
        translationTableL1[TMP_tlb.size()] =  TMP_tlbL2[pageBase];
        TMP_tlb[pageBase] = TMP_tlbL2[pageBase];
    endfunction



    function automatic Translation translateAddress(input EffectiveAddress adr);
        Translation res = DEFAULT_TRANSLATION;
        Mword vbase = getPageBaseM(adr);

        if ($isunknown(adr)) return res;

        if (!TMP_tlb.exists(vbase)) begin
            res.present = 0;
            return res;
        end

        res = TMP_tlb[vbase];
        res.padr = {adrHigh(res.padr), adrLow(adr)};

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
            res[p] = getBlockBaseD(translations_Reg[p].padr);
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
            res[p] = getPageBaseM(accessDescs_Reg[p].vadr);
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
            res = '{1, CR_TLB_MISS, tr.desc, 'x};
        end
        else if (!tr.desc.cached) begin // Just detected uncached access, tr.desc indicates uncached
            res = '{1, CR_HIT, tr.desc, 'x};  // TODO: introduce CR_UNCACHED to use here?
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

    
    // TODO: support for block crossing and page crossing accesses
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
                AccessInfo acc = analyzeAccess(Dword'(vadr), aDesc.size);
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
        DataCacheBlock block = way[aInfo.block];
        Dword accessPbase = getBlockBaseD(tr.padr);

        if (block == null) return '{0, 'x};

        begin
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

