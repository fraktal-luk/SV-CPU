
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
                output InstructionCacheOutput readOut
              );

    Word content[4096];
        Word way0[PAGE_SIZE/4] = '{default: 'x};
        Word way1[PAGE_SIZE/4] = '{default: 'x};
        Word way2[PAGE_SIZE/4] = '{default: 'x};


    Translation TMP_tlbL1[$], TMP_tlbL2[$];

        Translation translationTableL1[32]; // DB


    typedef InstructionCacheBlock InsWay[BLOCKS_PER_WAY];
    InsWay blocksWay0;
    InsWay blocksWay1;
    InsWay blocksWay2;


        typedef struct {
            logic valid;
            FetchLine value;
        } ReadResult;

        ReadResult readResultsWay0;
        ReadResult readResultsWay1;
        ReadResult readResultsWay2;
        ReadResult readResultSelected;

    
    
        function automatic void DB_fillTranslations();
            int i = 0;
            translationTableL1 = '{default: DEFAULT_TRANSLATION};
            foreach (TMP_tlbL1[a]) begin
                translationTableL1[i] = TMP_tlbL1[a];
                i++;
            end
        endfunction


    function automatic void reset();
        way0 = '{default: 'x};
        way1 = '{default: 'x};
        way2 = '{default: 'x};
    endfunction



    function automatic Translation translate(input Mword adr);
        Translation res = DEFAULT_TRANSLATION;
        
        Translation found[$] = TMP_tlbL1.find with (item.vadr == getPageBaseM(adr));
        
        assert (found.size() <= 1) else $fatal(2, "multiple hit in icache");
        
        if (found.size() == 0) return res; 
        
        res = found[0];

        res.vadr = adr;
        res.padr = adr + res.padr - getPageBaseM(adr);

        return res;
    endfunction


    function automatic InstructionCacheOutput readCache(input Mword readAdr);
        Mword truncatedAdr = readAdr & ~(4*FETCH_WIDTH-1);
        InstructionCacheOutput res;
        
        // TODO: determine hit/miss status
        
        foreach (res.words[i]) begin            
            res.active = 1;
            res.status = CR_HIT;
            res.desc = '{1, 1, 1, 1, 1};
            res.words[i] = content[truncatedAdr/4 + i];
        end
        
        return res;
    endfunction

    function automatic InstructionCacheOutput readCache_N(input logic readEnable, input Translation tr, input ReadResult res0, input ReadResult res1, input ReadResult res2);
        InstructionCacheOutput res;
        ReadResult selected = selectWay(res0, res1, res2);
        
        if (!readEnable) return res;
        // TODO: determine hit/miss status
        
        // TLB miss
        if (!tr.present) begin
            res.status = CR_TLB_MISS;
        end
        // Not cached
        else if (!tr.desc.cached) begin
            res.status = CR_HIT; // TODO: introduce CR_UNCACHED to use here?
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
        
        
        res.active = 1;//selected.valid; // ?
        res.desc = tr.desc;
        
        return res;
    endfunction


   
        Translation translation, translationSig;

        InstructionCacheOutput readOutSig, readOutSig_AC;
        InstructionCacheOutput readOut_T;
    
        assign readOutSig = readCache(readAddress);
        always_comb readOutSig_AC = readCache(readAddress);
    

    always @(posedge clk) begin
        doCacheAccess();
    
        translation <= translate(readAddress);
        readOut <= readCache(readAddress);
    end

    
    task automatic doCacheAccess();
        AccessInfo acc = analyzeAccess(Dword'(readAddress), SIZE_4); // TODO: introduce line size as access size?
        Translation tr = translate(readAddress);
        
        ReadResult result0 = readWay(blocksWay0, acc, tr);
        ReadResult result1 = readWay(blocksWay1, acc, tr);
        ReadResult result2 = readWay(blocksWay2, acc, tr);
        
        readResultsWay0 <= result0;
        readResultsWay1 <= result1;
        readResultsWay2 <= result2;
        
        
        readResultSelected <= selectWay(result0, result1, result2);
        
        readOut_T <= readCache_N(readEn, tr, result0, result1, result2);
    endtask

    
    function automatic ReadResult selectWay(input ReadResult res0, input ReadResult res1, input ReadResult res2);
        if (res0.valid === 1) return res0; 
        if (res1.valid === 1) return res1; 
        return res2;
    endfunction 



    // Copy page 0 and page 1 to cache
    function automatic void prefetchForTest();
        DataLineDesc cachedDesc = '{allowed: 1, canRead: 1, canWrite: 1, canExec: 1, cached: 1};
        DataLineDesc uncachedDesc = '{allowed: 1, canRead: 1, canWrite: 1, canExec: 1, cached: 0};

        Translation physPage0 = '{present: 1, vadr: 0, desc: cachedDesc, padr: 0};
        Translation physPage1 = '{present: 1, vadr: PAGE_SIZE, desc: cachedDesc, padr: PAGE_SIZE};
        Translation physPage2 = '{present: 1, vadr: 2*PAGE_SIZE, desc: cachedDesc, padr: 2*PAGE_SIZE};


        PageBasedProgramMemory::Page page = AbstractCore.programMem.getPage(0);
        way0 = page[0+:PAGE_SIZE/4];
        page = AbstractCore.programMem.getPage(PAGE_SIZE);
        way1 = page[0+:PAGE_SIZE/4];
        page = AbstractCore.programMem.getPage(2*PAGE_SIZE);
        way2 = page[0+:PAGE_SIZE/4];
        
            content[0+:1024] = way0;
            content[1024+:1024] = way1;
            content[2048+:1024] = way2;
            
            
            TMP_tlbL1 = '{0: physPage0, 1: physPage1, 2: physPage2};
            DB_fillTranslations();
            
            initBlocksWay(blocksWay0, 0);
            initBlocksWay(blocksWay1, PAGE_SIZE);
            initBlocksWay(blocksWay2, 2*PAGE_SIZE);
    endfunction


        function automatic void prepareForUncachedTest();
            DataLineDesc cachedDesc = '{allowed: 1, canRead: 1, canWrite: 1, canExec: 1, cached: 1};
            DataLineDesc uncachedDesc = '{allowed: 1, canRead: 1, canWrite: 1, canExec: 1, cached: 0};
    
            Translation physPage0 = '{present: 1, vadr: 0, desc: uncachedDesc, padr: 0};
            Translation physPage1 = '{present: 1, vadr: PAGE_SIZE, desc: uncachedDesc, padr: PAGE_SIZE};
            Translation physPage2 = '{present: 1, vadr: 2*PAGE_SIZE, desc: uncachedDesc, padr: 2*PAGE_SIZE};
        
        
            PageBasedProgramMemory::Page page = AbstractCore.programMem.getPage(0);
            way0 = page[0+:PAGE_SIZE/4];
            page = AbstractCore.programMem.getPage(PAGE_SIZE);
            way1 = page[0+:PAGE_SIZE/4];
            page = AbstractCore.programMem.getPage(2*PAGE_SIZE);
            way2 = page[0+:PAGE_SIZE/4];
            
                content[0+:1024] = way0;
                content[1024+:1024] = way1;
                content[2048+:1024] = way2;
                
                
                TMP_tlbL1 = '{0: physPage0, 1: physPage1, 2: physPage2};
                DB_fillTranslations();

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


endmodule
