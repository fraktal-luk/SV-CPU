
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
    DataFillEngine dataFillEngine(clk, dataFillEnA, dataFillPhysA);
    DataFillEngine#(Mword, 11) tlbFillEngine(clk, tlbFillEnA, tlbFillVirtA);

    typedef DataCacheBlock DataWay[BLOCKS_PER_WAY];

    DataWay blocksWay0;
    DataWay blocksWay1;

    localparam DataBlock CLEAN_BLOCK = '{default: 0};

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

    function automatic void copyToWay(Dword pageAdr);
        Dword pageBase = getPageBaseD(pageAdr);
        
        case (pageBase)
            0:              initBlocksWay(blocksWay0, 0);
            PAGE_SIZE:      initBlocksWay(blocksWay1, PAGE_SIZE);
//            2*PAGE_SIZE:    initBlocksWay(blocksWay2, 2*PAGE_SIZE);
//            3*PAGE_SIZE:    initBlocksWay(blocksWay3, 3*PAGE_SIZE);
            default: $error("Incorrect page to init cache: %x", pageBase);
        endcase
    endfunction


    Translation TMP_tlbL1[$];
    Translation TMP_tlbL2[$];

    Translation translationTableL1[DATA_TLB_SIZE]; // DB


    function automatic void DB_fillTranslations();
        int i = 0;
        translationTableL1 = '{default: DEFAULT_TRANSLATION};
        foreach (TMP_tlbL1[a]) begin
            translationTableL1[i] = TMP_tlbL1[a];
            i++;
        end
    endfunction


    task automatic reset();
        accessDescs_Reg <= '{default: DEFAULT_ACCESS_DESC};
        translations_Reg <= '{default: DEFAULT_TRANSLATION};
        readOut <= '{default: EMPTY_DATA_CACHE_OUTPUT};
            
        TMP_tlbL1.delete();
        TMP_tlbL2.delete();
        DB_fillTranslations();
        
        blocksWay0 = '{default: null};
        blocksWay1 = '{default: null};

        dataFillEngine.resetBlockFills();
        tlbFillEngine.resetBlockFills();

        uncachedSubsystem.UNC_reset();
    endtask



    function automatic void preloadForTest();
        TMP_tlbL1 = AbstractCore.globalParams.preloadedDataTlbL1;
        TMP_tlbL2 = AbstractCore.globalParams.preloadedDataTlbL2;
        DB_fillTranslations();

        //foreach (AbstractCore.globalParams.copiedDataPages[i])
        //    copyPageToContent(AbstractCore.globalParams.copiedDataPages[i]);
        
        foreach (AbstractCore.globalParams.preloadedDataWays[i])
            copyToWay(AbstractCore.globalParams.preloadedDataWays[i]);
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
        Translation found[$] = TMP_tlbL2.find with (item.vadr === getPageBaseM(adr));  
            
        assert (found.size() > 0) else $error("NOt prent in TLB L2");
        
        translationTableL1[TMP_tlbL1.size()] = found[0];
        TMP_tlbL1.push_back(found[0]);
    endfunction


    function automatic Translation translateAddress(input Mword adr);    
        Translation res = DEFAULT_TRANSLATION;
        Mword vbase = getPageBaseM(adr);

        Translation found[$] = TMP_tlbL1.find with (item.vadr == getPageBaseM(adr));

        if ($isunknown(adr)) return DEFAULT_TRANSLATION;
        //if (!AbstractCore.globalParams.enableMmu) return '{present: 1, vadr: adr, desc: '{1, 1, 1, 1, 0}, padr: adr};
        if (!AbstractCore.CurrentConfig.enableMmu) return '{present: 1, vadr: adr, desc: '{1, 1, 1, 1, 0}, padr: adr};

        assert (found.size() <= 1) else $fatal(2, "multiple hit in itlb\n%p", TMP_tlbL1);

        if (found.size() == 0) begin
            res.vadr = adr; // It's needed because TLB fill is based on this adr
            return res;
        end 

        res = found[0];

        res.vadr = adr;
        res.padr = adr + res.padr - getPageBaseM(adr);

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
            res = '{1, CR_UNCACHED, tr.desc, 'x};
        end
        else if (!tr.desc.canRead) begin // TEMPORRY, need to discern reads and writes
            res = '{1, CR_NOT_ALLOWED, tr.desc, 'x};
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

    
    // FUTURE: support for block crossing and page crossing accesses
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

