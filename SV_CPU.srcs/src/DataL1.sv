
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
            input MemWriteInfo writeReqs[2],
            output Translation translationsOut[N_MEM_PORTS],
            output DataCacheOutput readOut[N_MEM_PORTS]
);

    // TLB
    localparam int DATA_TLB_SIZE = 32;

    localparam int BLOCKS_PER_WAY = WAY_SIZE/BLOCK_SIZE;

    typedef Translation TranslationA[N_MEM_PORTS];

    Translation translations_T[N_MEM_PORTS];

    typedef struct {
        logic valid;
        Mword value;
    } ReadResult;

    // TODO: review the type definition
    LogicA dataFillEnA, tlbFillEnA;

    UncachedSubsystem uncachedSubsystem(clk, writeReqs);
    DataFillEngine#(Dword, N_MEM_PORTS, 14) dataFillEngine(clk, dataFillEnA, theExecBlock.dcacheTranslations_E1);
    DataFillEngine#(Mword, N_MEM_PORTS, 11) tlbFillEngine(clk, tlbFillEnA, theExecBlock.dcacheTranslations_E1);

    typedef DataCacheBlock DataWay[BLOCKS_PER_WAY];

    DataWay blocksWay0;
    DataWay blocksWay1;

    localparam DataBlock CLEAN_BLOCK = '{default: 0};


    Translation TMP_tlbL1[$];
    Translation TMP_tlbL2[$];

    Translation translationTableL1[DATA_TLB_SIZE]; // DB


    task automatic doCachedWrite(input MemWriteInfo wrInfo);
        if (!wrInfo.req || wrInfo.uncached) return;

        void'(tryWriteWay(blocksWay0, wrInfo));
        void'(tryWriteWay(blocksWay1, wrInfo));
    endtask

    ////////////////////
    // translation
    
    function automatic Translation translateAddress(input Mword adr);    
        Translation res = DEFAULT_TRANSLATION;
        Translation found[$] = TMP_tlbL1.find with (item.vadr == getPageBaseM(adr));

        if ($isunknown(adr)) return DEFAULT_TRANSLATION;
        if (!AbstractCore.CurrentConfig.enableMmu) return '{present: 1, vadr: adr, desc: '{1, 1, 1, 1, 0}, padr: adr};

        assert (found.size() <= 1) else $fatal(2, "multiple hit in itlb\n%p", TMP_tlbL1);

        if (found.size() == 0) begin
            res.vadr = adr; // It's needed because TLB fill is based on this adr
            return res;
        end

        res = found[0];

        res.vadr = adr;
        res.padr = res.padr + (adr - getPageBaseM(adr));

        return res;
    endfunction


    function automatic TranslationA getTranslations();
        TranslationA res = '{default: DEFAULT_TRANSLATION};

        foreach (res[p]) begin
            AccessDesc aDesc = theExecBlock.accessDescs_E0[p];
            if (!aDesc.active || $isunknown(aDesc.vadr)) continue;
            res[p] = translateAddress(aDesc.vadr);
        end
        return res;
    endfunction

    ///////////////////////////////////////////////////

    always_comb translations_T = getTranslations();

    assign translationsOut = translations_T;


    // Main dispatch
    function automatic DataCacheOutput doReadAccess(input Translation tr, input AccessDesc aDesc, input ReadResult readRes);
        DataCacheOutput res;        

        // Actions from replay or sys read (access checks don't apply, no need to lookup TLB) - they are not handled by cache
        if (0) begin end
        else if (aDesc.sys) begin end
        else if (aDesc.uncachedReq) begin end
        else if (aDesc.uncachedCollect) begin // Completion of uncached read              
            if (uncachedSubsystem.readResult.status == CR_HIT) res = '{1, CR_HIT, tr.desc, uncachedSubsystem.readResult.data};
            else if (uncachedSubsystem.readResult.status == CR_INVALID) res = '{1, CR_INVALID, tr.desc, 0};
            else $error("Wrong status returned by uncached");
        end
        else if (aDesc.uncachedStore)
            res = '{1, CR_HIT, tr.desc, 'x};

        // Otherwise check translation
        else if (!virtualAddressValid(aDesc.vadr))
            res = '{1, CR_INVALID, tr.desc, 'x}; // Invalid virtual adr
        else if (!tr.present)
            res = '{1, CR_TLB_MISS, tr.desc, 'x}; // TLB miss
        else if (!tr.desc.canRead)
            res = '{1, CR_NOT_ALLOWED, tr.desc, 'x};
        else if (!tr.desc.canWrite) // TODO: condition should be for stores only
            res = '{1, CR_INVALID, tr.desc, 'x};
        else if (!tr.desc.cached)
            res = '{1, CR_UNCACHED, tr.desc, 'x}; // Just detected uncached access, tr.desc indicates uncached

        // If translation correct and content is cacheable, look at cache results
        else if (!readRes.valid)
            res = '{1, CR_TAG_MISS, tr.desc, 'x};
        else
            res = '{1, CR_HIT, tr.desc, readRes.value};

        return res;
    endfunction


    function automatic ReadResult readWay(input DataWay way, input AccessDesc aDesc, input Translation tr);
        DataCacheBlock block = way[aDesc.blockIndex];
        Dword accessPbase = getBlockBaseD(tr.padr);

        if (block == null) return '{0, 'x};
        else begin
            logic hit0 = (accessPbase === block.pbase);
            Mword val0 = aDesc.size == SIZE_1 ? block.readByte(aDesc.blockOffset) : block.readWord(aDesc.blockOffset);

            if (aDesc.blockCross) $error("Read crossing block at %x", aDesc.vadr);
            return '{hit0, val0};
        end
    endfunction

    function automatic ReadResult selectWayResult(input ReadResult res0, input ReadResult res1);
        return res0.valid ? res0 : res1;
    endfunction


    task automatic handleSingleRead(input int p);
        AccessDesc aDesc = theExecBlock.accessDescs_E0[p];

       // translations_Reg[p] <= DEFAULT_TRANSLATION;
        readOut[p] <= EMPTY_DATA_CACHE_OUTPUT;

        if (!aDesc.active || $isunknown(aDesc.vadr)) return;
        else begin
            Translation tr = translations_T[p];
            // Read all ways of cache with tags
            ReadResult result0 = readWay(blocksWay0, aDesc, tr);
            ReadResult result1 = readWay(blocksWay1, aDesc, tr);
            ReadResult selectedResult = selectWayResult(result0, result1);
            
            DataCacheOutput thisResult = doReadAccess(tr, aDesc, selectedResult);

          //  translations_Reg[p] <= tr;
            readOut[p] <= thisResult;
        end
    endtask


    // FUTURE: support for block crossing and page crossing accesses
    task automatic handleReads();
        foreach (theExecBlock.accessDescs_E0[p]) handleSingleRead(p);
    endtask


/////////
// Filling

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
            
        assert (found.size() > 0) else $error("Not prent in TLB L2");
        
        translationTableL1[TMP_tlbL1.size()] = found[0];
        TMP_tlbL1.push_back(found[0]);
    endfunction

///////////////////////////


/////////////////
// Init and DB
    function automatic void DB_fillTranslations();
        int i = 0;
        translationTableL1 = '{default: DEFAULT_TRANSLATION};
        foreach (TMP_tlbL1[a]) begin
            translationTableL1[i] = TMP_tlbL1[a];
            i++;
        end
    endfunction

    task automatic reset();
       // translations_Reg <= '{default: DEFAULT_TRANSLATION};
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

    // CAREFUL: this sets all data to default values
    function automatic void copyToWay(Dword pageAdr);
        Dword pageBase = getPageBaseD(pageAdr);
        
        case (pageBase)
            0:              initBlocksWay(blocksWay0, 0);
            PAGE_SIZE:      initBlocksWay(blocksWay1, PAGE_SIZE);
            default: $error("Incorrect page to init cache: %x", pageBase);
        endcase
    endfunction

    function automatic void preloadForTest();
        TMP_tlbL1 = AbstractCore.globalParams.preloadedDataTlbL1;
        TMP_tlbL2 = AbstractCore.globalParams.preloadedDataTlbL2;
        DB_fillTranslations();
 
        foreach (AbstractCore.globalParams.preloadedDataWays[i])
            copyToWay(AbstractCore.globalParams.preloadedDataWays[i]);
    endfunction

////////////////////////
    always_comb dataFillEnA = dataFillEnables();
    always_comb tlbFillEnA = tlbFillEnables();

    ////////////////////////////////////
    function automatic LogicA dataFillEnables();
        LogicA res = '{default: 0};
        foreach (readOut[p])
            res[p] = (readOut[p].status == CR_TAG_MISS);
        return res;
    endfunction

    function automatic LogicA tlbFillEnables();
        LogicA res = '{default: 0};
        foreach (readOut[p])
            res[p] = (readOut[p].status == CR_TLB_MISS);
        return res;
    endfunction


    always @(posedge clk) begin
        handleReads();

        if (dataFillEngine.notifyFill) begin
            allocInDynamicRange(dataFillEngine.notifiedTr.padr);
        end
        if (tlbFillEngine.notifyFill) begin
            allocInTlb(tlbFillEngine.notifiedTr.vadr);
        end
    
        doCachedWrite(writeReqs[0]);
    end

endmodule

