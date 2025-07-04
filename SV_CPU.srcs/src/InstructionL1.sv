
import Base::*;
import InsDefs::*;
import Asm::*;
import EmulationDefs::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;


module InstructionL1(
                input logic clk,
                
                input logic readEn,
                input Mword readAddress,
                output InstructionCacheOutput readOut,
                
                input logic readEnUnc,
                input Mword readAddressUnc,
                output InstructionCacheOutput readOutUnc
              );

    Word content[4096];

    Translation TMP_tlbL1[$], TMP_tlbL2[$];

    Translation translationTableL1[32]; // DB


    Translation translation = DEFAULT_TRANSLATION;

    InstructionCacheOutput readOutCached, readOutUncached;
    

    typedef InstructionCacheBlock InsWay[BLOCKS_PER_WAY];
    InsWay blocksWay0;
    InsWay blocksWay1;
    InsWay blocksWay2;
    InsWay blocksWay3;

        typedef struct {
            logic valid;
            FetchLine value;
        } ReadResult;


    typedef logic LogicA[N_MEM_PORTS];
    typedef Mword MwordA[N_MEM_PORTS];
    typedef Dword DwordA[N_MEM_PORTS];
    
    LogicA blockFillEnA, tlbFillEnA;
    DwordA blockFillPhysA;
    MwordA tlbFillVirtA;
    
    DataFillEngine blockFillEngine(clk, blockFillEnA, blockFillPhysA);
    DataFillEngine#(Mword, 11) tlbFillEngine(clk, tlbFillEnA, tlbFillVirtA);


    assign readOutUnc = readOutUncached;
    assign readOut = readOutCached;


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
        
        content = '{default: 'x};
        
        blockFillEngine.resetBlockFills();
        tlbFillEngine.resetBlockFills();
    endtask



    function automatic Translation translate(input Mword adr);
        Translation res = DEFAULT_TRANSLATION;

        Translation found[$] = TMP_tlbL1.find with (item.vadr == getPageBaseM(adr));

        if ($isunknown(adr)) return DEFAULT_TRANSLATION;
        if (!AbstractCore.globalParams.enableMmu) return '{present: 1, vadr: adr, desc: '{1, 1, 1, 1, 0}, padr: adr};

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


    function automatic InstructionCacheOutput readCache(input logic readEnable, input Translation tr, input ReadResult res0, input ReadResult res1, input ReadResult res2, input ReadResult res3);
        InstructionCacheOutput res = EMPTY_INS_CACHE_OUTPUT;
        ReadResult selected = selectWay(res0, res1, res2, res3);
        
        if (!readEnable) return res;
        
        // TLB miss
        if (!tr.present) begin
            res.status = CR_TLB_MISS;
        end
        // Not cached
        else if (!tr.desc.cached) begin
            res.status = CR_UNCACHED;
        end
        // Miss
        else if (!selected.valid) begin
            res.status = CR_TAG_MISS;
        end
        // Hit
        else begin
            res.status = CR_HIT;
            res.words = selected.value;
        end
        
        
        res.active = 1;
        res.desc = tr.desc;
        
        return res;
    endfunction


    function automatic InstructionCacheOutput readUncached(input logic readEnable, input Dword adr);
        InstructionCacheOutput res = EMPTY_INS_CACHE_OUTPUT;

        if (!readEnable) return res;
        
        assert (physicalAddressValid(adr)) else $fatal(2, "Wrong fetch");
        
        // TODO: catch invalid adr or nonexistent mem exception
        res.status = CR_HIT; // Although uncached, this status prevents from handling read as error in frontend 

        res.active = 1;
        res.desc = '{1, 1, 1, 1, 0};
        res.words = '{0: content[adr/4], default : 'x};
        
        return res;
    endfunction



    always @(posedge clk) begin
        doCacheAccess();
       
        if (blockFillEngine.notifyFill) allocInDynamicRange(blockFillEngine.notifiedAdr);
        if (tlbFillEngine.notifyFill) allocInTlb(tlbFillEngine.notifiedAdr);
    end
    
    
    
    task automatic doCacheAccess();
        AccessInfo acc = analyzeAccess(Dword'(readAddress), SIZE_INS_LINE);
        Translation tr = translate(readAddress);
        
        ReadResult result0 = readWay(blocksWay0, acc, tr);
        ReadResult result1 = readWay(blocksWay1, acc, tr);
        ReadResult result2 = readWay(blocksWay2, acc, tr);
        ReadResult result3 = readWay(blocksWay3, acc, tr);

        translation <= tr;

        readOutCached <= readCache(readEn, tr, result0, result1, result2, result3);
        
        readOutUncached <= readUncached(readEnUnc, Dword'(readAddressUnc));
    endtask

    
    function automatic ReadResult selectWay(input ReadResult res0, input ReadResult res1, input ReadResult res2, input ReadResult res3);
        if (res0.valid === 1) return res0; 
        if (res1.valid === 1) return res1; 
        if (res2.valid === 1) return res2; 
        return res3;
    endfunction 


    function automatic void copyPageToContent(Dword pageAdr);
        Dword pageBase = getPageBaseD(pageAdr);
        PageBasedProgramMemory::Page page;
        
        if (!AbstractCore.programMem.hasPage(pageBase)) begin
            content[pageBase/4 +: PAGE_SIZE/4] = '{default: 'x};
            return;
        end
        
        page = AbstractCore.programMem.getPage(pageBase);
        content[pageBase/4 +: PAGE_SIZE/4] = page[0 +: PAGE_SIZE/4];
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

        foreach (AbstractCore.globalParams.copiedInsPages[i])
            copyPageToContent(AbstractCore.globalParams.copiedInsPages[i]);
        
        foreach (AbstractCore.globalParams.preloadedInsWays[i])
            copyToWay(AbstractCore.globalParams.preloadedInsWays[i]);
    endfunction


    function automatic void initBlocksWay(ref InsWay way, input Mword baseVadr);
        foreach (way[i]) begin
            Mword vadr = baseVadr + i*BLOCK_SIZE;
            Dword padr = vadr;

            way[i] = new();
            way[i].valid = 1;
            way[i].vbase = vadr;
            way[i].pbase = padr;
            way[i].array = content[vadr/4 +: BLOCK_SIZE/4];
        end
    endfunction


    function automatic ReadResult readWay(input InsWay way, input AccessInfo aInfo, input Translation tr);
        InstructionCacheBlock block = way[aInfo.block];
        Dword accessPbase = getBlockBaseD(tr.padr);

        if (block == null) return '{0, '{default: 'x}};

        begin
            logic hit0 = (accessPbase === block.pbase);
            FetchLine val0 = block.readLine(aInfo.blockOffset);                    

            if (aInfo.blockCross) begin
                $error("Read crossing block at %x", aInfo.adr);
            end

            return '{hit0, val0};
        end
    endfunction


    always_comb blockFillEnA = dataMakeEnables();
    always_comb blockFillPhysA = dataMakePhysical();
    always_comb tlbFillEnA = tlbMakeEnables();
    always_comb tlbFillVirtA = tlbMakeVirtual();


/////////////////////////////////////////////////


        function automatic LogicA dataMakeEnables();
            LogicA res = '{default: 0};
            if (readOutCached.status == CR_TAG_MISS) res[0] = 1;
            return res;
        endfunction
    
        function automatic DwordA dataMakePhysical();
            DwordA res = '{default: 'x};
            res[0] = getBlockBaseD(translation.padr);
            return res;
        endfunction
    
    
        function automatic LogicA tlbMakeEnables();
            LogicA res = '{default: 0};
            if (readOutCached.status == CR_TLB_MISS) res[0] = 1;
            return res;
        endfunction
    
        function automatic MwordA tlbMakeVirtual();
            MwordA res = '{default: 'x};
            res[0] = getPageBaseM(translation.vadr);
            return res;
        endfunction
    


    function automatic void allocInDynamicRange(input Dword adr);
        tryFillWay(blocksWay3, adr);
    endfunction


    function automatic logic tryFillWay(ref InsWay way, input Dword adr);
        AccessInfo aInfo = analyzeAccess(adr, SIZE_1); // Dummy size
        InstructionCacheBlock block = way[aInfo.block];
        Dword fillPbase = getBlockBaseD(adr);

        if (block != null) begin
            $error("Block already filled at %x", fillPbase);
            return 0;
        end

        way[aInfo.block] = new();
        way[aInfo.block].valid = 1;
        way[aInfo.block].pbase = fillPbase;
        way[aInfo.block].array = content[fillPbase/4 +: BLOCK_SIZE/4];

        return 1;
    endfunction



    function automatic void allocInTlb(input Mword adr);
        Translation found[$] = TMP_tlbL2.find with (item.vadr === getPageBaseM(adr));  
            
        assert (found.size() > 0) else $error("NOt prent in TLB L2");
        
        translationTableL1[TMP_tlbL1.size()] = found[0];
        TMP_tlbL1.push_back(found[0]);
    endfunction



endmodule
