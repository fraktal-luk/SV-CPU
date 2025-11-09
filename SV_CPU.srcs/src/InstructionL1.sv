
import Base::*;
import InsDefs::*;
import Asm::*;
import EmulationDefs::*;
import EmulationMemories::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;


module InstructionL1(
                input logic clk,
                
                input logic readEn,
                input Mword readAddress,
                output InstructionCacheOutput readOut
              );

    Translation TMP_tlbL1[$], TMP_tlbL2[$];

    Translation translationTableL1[32]; // DB

    Translation translationSig = DEFAULT_TRANSLATION;

    Translation tr_Reg[1];

    InstructionCacheOutput readOutCached, readOutUncached;
    

        assign tr_Reg[0] = translationSig;

    typedef InstructionCacheBlock InsWay[BLOCKS_PER_WAY];
    InsWay blocksWay0;
    InsWay blocksWay1;
    InsWay blocksWay2;
    InsWay blocksWay3;

    typedef struct {
        logic valid;
        Dword tag;
        FetchLine value;
    } ReadResult;


    typedef logic LogicA[1];
    typedef Mword MwordA[1];
    typedef Dword DwordA[1];

    LogicA blockFillEnA, tlbFillEnA;

    DataFillEngine#(1, 14) blockFillEngine(clk, blockFillEnA, tr_Reg);
    DataFillEngine#(1, 11) tlbFillEngine(clk, tlbFillEnA, tr_Reg);

    assign readOut = readOutCached;

    always @(posedge clk) begin
        doCacheAccess();

        if (blockFillEngine.notifyFill) begin
            allocInDynamicRange(blockFillEngine.notifiedTr.padr);
        end
        if (tlbFillEngine.notifyFill) begin
            allocInTlb(tlbFillEngine.notifiedTr.vadr);
        end
    end

    
    task automatic doCacheAccess();
        AccessDesc aDesc = getAccessDesc_I(readAddress);
        begin
            Translation tr = translateAddress(aDesc, TMP_tlbL1, AbstractCore.CurrentConfig.enableMmu); // TODO: always mmu because uncached fetch has different unit?

            ReadResult result0 = readWay_I(blocksWay0, aDesc);
            ReadResult result1 = readWay_I(blocksWay1, aDesc);
            ReadResult result2 = readWay_I(blocksWay2, aDesc);
            ReadResult result3 = readWay_I(blocksWay3, aDesc);

            ReadResult result0m = matchWay_I(result0, aDesc, tr);
            ReadResult result1m = matchWay_I(result1, aDesc, tr);
            ReadResult result2m = matchWay_I(result2, aDesc, tr);
            ReadResult result3m = matchWay_I(result3, aDesc, tr);
 
            //assert (result0m === result0) else $error("diffread0\n%p\n%p", result0m, result0);
            //assert (result1m === result1) else $error("diffread1\n%p\n%p", result1m, result1);
            //assert (result2m === result2) else $error("diffread2\n%p\n%p", result2m, result2);
            //assert (result3m === result3) else $error("diffread3\n%p\n%p", result3m, result3);

            translationSig <= tr;

            readOutCached <= readCache(readEn, tr, result0m, result1m, result2m, result3m);
        end
    endtask


    function automatic ReadResult readWay_I(input InsWay way, input AccessDesc aDesc);
        InstructionCacheBlock block = way[aDesc.blockIndex];

        if (block == null) return '{0, 'x, '{default: 'x}};
        begin
            logic hit0 = 1;//(accessPbase === block.pbase);
            FetchLine val0 = block.readLine(aDesc.blockOffset);                    
            if (aDesc.blockCross) $error("Read crossing block at %x", aDesc.vadr);
            return '{hit0, block.pbase, val0};
        end
    endfunction

    function automatic ReadResult matchWay_I(input ReadResult rr, input AccessDesc aDesc, input Translation tr);
        ReadResult res = rr;
        Dword accessPbase = getBlockBaseD(tr.padr);       
        logic hit0 = (accessPbase === rr.tag);
        
        res.valid &= hit0;
        return res;
    endfunction


        function automatic AccessDesc getAccessDesc_I(input Mword adr);
            AccessDesc res;
            AccessInfo aInfo = analyzeAccess(adr, SIZE_INS_LINE);
    
            res.active = 1;
    
            res.size = SIZE_INS_LINE;
    
            res.store = 1;//isStoreUop(uname);
            res.sys = 0;//isLoadSysUop(uname) || isStoreSysUop(uname);
            res.uncachedReq = 0;//(p.status == ES_UNCACHED_1) && !res.store;
            res.uncachedCollect = 0;//(p.status == ES_UNCACHED_2) && !res.store;
            res.uncachedStore = 0;//(p.status == ES_UNCACHED_2) && res.store;
            
            res.vadr = adr;
            
            res.blockIndex = aInfo.block;
            res.blockOffset = aInfo.blockOffset;
    
            res.unaligned = aInfo.unaligned;
            res.blockCross = aInfo.blockCross;
            res.pageCross = aInfo.pageCross;
        
            return res;
        endfunction


    function automatic ReadResult selectWay(input ReadResult res0, input ReadResult res1, input ReadResult res2, input ReadResult res3);
        if (res0.valid === 1) return res0; 
        if (res1.valid === 1) return res1; 
        if (res2.valid === 1) return res2; 
        return res3;
    endfunction 


    function automatic InstructionCacheOutput readCache(input logic readEnable, input Translation tr, input ReadResult res0, input ReadResult res1, input ReadResult res2, input ReadResult res3);
        InstructionCacheOutput res = EMPTY_INS_CACHE_OUTPUT;
        ReadResult selected = selectWay(res0, res1, res2, res3);
        
        if (!readEnable) return res;

        if (!tr.present)          res.status = CR_TLB_MISS; // TLB miss
        else if (!tr.desc.cached) res.status = CR_UNCACHED; // Not cached
        else if (!selected.valid) res.status = CR_TAG_MISS; // Miss
        else begin         // Hit
            res.status = CR_HIT;
            res.words = selected.value;
        end
        
        res.active = 1;
        res.desc = tr.desc;
        
        return res;
    endfunction


    /////////////////////////
    // Filling

    function automatic void allocInDynamicRange(input Dword adr);
        tryFillWay(blocksWay3, adr);
    endfunction


    function automatic logic tryFillWay(ref InsWay way, input Dword adr);
        AccessInfo aInfo = analyzeAccess(adr, SIZE_1); // Dummy size
        InstructionCacheBlock block = way[aInfo.block];
        Dword fillPbase = getBlockBaseD(adr);
        Dword fillPageBase = getPageBaseD(adr);
        PageBasedProgramMemory::Page page = AbstractCore.programMem.getPage(fillPageBase);

        if (block != null) begin
            $error("Block already filled at %x", fillPbase);
            return 0;
        end

        way[aInfo.block] = new();
        way[aInfo.block].valid = 1;
        way[aInfo.block].pbase = fillPbase;
        way[aInfo.block].array = page[(fillPbase-fillPageBase)/4 +: BLOCK_SIZE/4];

        return 1;
    endfunction



    function automatic void allocInTlb(input Mword adr);
        Translation found[$] = TMP_tlbL2.find with (item.vadr === getPageBaseM(adr));  
            
        assert (found.size() > 0) else $error("NOt prent in TLB L2");
        
        translationTableL1[TMP_tlbL1.size()] = found[0];
        TMP_tlbL1.push_back(found[0]);
    endfunction


    // Initialization and DB

    function automatic void initBlocksWay(ref InsWay way, input Mword baseVadr);
        Dword basePadr = baseVadr;

        PageBasedProgramMemory::Page page = AbstractCore.programMem.getPage(basePadr);

        foreach (way[i]) begin
            Mword vadr = baseVadr + i*BLOCK_SIZE;
            Dword padr = vadr;

            way[i] = new();
            way[i].valid = 1;
            way[i].vbase = vadr;
            way[i].pbase = padr;
            way[i].array = page[(padr-basePadr)/4 +: BLOCK_SIZE/4];
        end
    endfunction

    function automatic void copyToWay(Dword pageAdr);
        Dword pageBase = getPageBaseD(pageAdr);
        
        case (pageBase)
            0:              initBlocksWay(blocksWay0, 0);
            PAGE_SIZE:      initBlocksWay(blocksWay1, PAGE_SIZE);
            2*PAGE_SIZE:    initBlocksWay(blocksWay2, 2*PAGE_SIZE);
            3*PAGE_SIZE:    initBlocksWay(blocksWay3, 3*PAGE_SIZE);
            default: $error("Incorrect page to init cache: %x", pageBase);
        endcase
    endfunction



    function automatic void preloadForTest();
        TMP_tlbL1 = AbstractCore.globalParams.preloadedInsTlbL1;
        TMP_tlbL2 = AbstractCore.globalParams.preloadedInsTlbL2;
        DB_fillTranslations();
        
        foreach (AbstractCore.globalParams.preloadedInsWays[i])
            copyToWay(AbstractCore.globalParams.preloadedInsWays[i]);
    endfunction

    function automatic void DB_fillTranslations();
        int i = 0;
        translationTableL1 = '{default: DEFAULT_TRANSLATION};
        foreach (TMP_tlbL1[a]) begin
            translationTableL1[i] = TMP_tlbL1[a];
            i++;
        end
    endfunction


    task automatic reset();
        readOutUncached <= EMPTY_INS_CACHE_OUTPUT;
        readOutCached <= EMPTY_INS_CACHE_OUTPUT;

        TMP_tlbL1.delete();
        TMP_tlbL2.delete();
        translationTableL1 = '{default: DEFAULT_TRANSLATION};

        blocksWay0 = '{default: null};
        blocksWay1 = '{default: null};
        blocksWay2 = '{default: null};
        blocksWay3 = '{default: null};
        
        blockFillEngine.resetBlockFills();
        tlbFillEngine.resetBlockFills();
    endtask




    always_comb blockFillEnA = dataMakeEnables();
    always_comb tlbFillEnA = tlbMakeEnables();
/////////////////////////////////////////////////


        function automatic LogicA dataMakeEnables();
            LogicA res = '{default: 0};
            res[0] = (readOutCached.status == CR_TAG_MISS);
            return res;
        endfunction

        function automatic LogicA tlbMakeEnables();
            LogicA res = '{default: 0};
            res[0] = (readOutCached.status == CR_TLB_MISS);
            return res;
        endfunction

endmodule



module InstructionUncached(
                input logic clk,                
                input logic readEnUnc,
                input Mword readAddressUnc,
                output InstructionCacheOutput readOutUnc
              );

    InstructionCacheOutput readOutUncached;

    assign readOutUnc = readOutUncached;


    always @(posedge clk) begin
        readOutUncached <= readUncached(readEnUnc, Dword'(readAddressUnc));
    end

    // TODO: make more general memory read definitions, no to use InstructionCacheOutput for uncached
    function automatic InstructionCacheOutput readUncached(input logic readEnable, input Dword adr);
        InstructionCacheOutput res = EMPTY_INS_CACHE_OUTPUT;

        if (!readEnable) return res;

        if (!physicalAddressValid(adr) || (adr % 4 != 0)) begin
            res.status = CR_INVALID;
        end
        else begin
            res.status = CR_HIT; // Although uncached, this status prevents from handling read as error in frontend
            res.words = '{0: AbstractCore.programMem.fetch(adr), default: 'x};
        end

        res.active = 1;
        res.desc = '{1, 1, 1, 1, 0};

        return res;
    endfunction

endmodule


module InstructionTlb(
    input logic clk
);

endmodule


module InstructionCacheArray(
    input logic clk
);

endmodule

