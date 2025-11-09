
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

    Translation translationSig = DEFAULT_TRANSLATION;

    Translation tr_Reg[1];

    InstructionCacheOutput readOutCached, readOutUncached;



    typedef InstructionCacheBlock InsWay[BLOCKS_PER_WAY];
    InsWay blocksWay0;
    InsWay blocksWay1;
    InsWay blocksWay2;
    InsWay blocksWay3;

//    typedef struct {
//        logic valid;
//        Dword tag;
//        FetchLine value;
//    } ReadResult;


    typedef logic LogicA[1];
    typedef Mword MwordA[1];
    typedef Dword DwordA[1];


    AccessDesc aDesc_T;

    LogicA blockFillEnA, tlbFillEnA;


    DataTlb#(.WIDTH(1)) tlb(clk, '{0: aDesc_T}, tlbFillEngine.notifyFill, tlbFillEngine.notifiedTr);

    DataFillEngine#(1, 14) blockFillEngine(clk, blockFillEnA, tr_Reg);
    DataFillEngine#(1, 11) tlbFillEngine(clk, tlbFillEnA, tr_Reg);


    always_comb aDesc_T = getAccessDesc_I(readAddress);
    assign tr_Reg[0] = translationSig;
    assign readOut = readOutCached;


    always @(posedge clk) begin
        doCacheAccess();

        if (blockFillEngine.notifyFill) begin
            allocInDynamicRange(blockFillEngine.notifiedTr.padr);
        end
    end


    task automatic doCacheAccess();
        AccessDesc aDesc = getAccessDesc_I(readAddress);
        begin
            Translation tr = tlb.translationsH[0];

            ReadResult_I result0 = readWay_I(blocksWay0, aDesc);
            ReadResult_I result1 = readWay_I(blocksWay1, aDesc);
            ReadResult_I result2 = readWay_I(blocksWay2, aDesc);
            ReadResult_I result3 = readWay_I(blocksWay3, aDesc);

            ReadResult_I result0m = matchWay_I(result0, aDesc, tr);
            ReadResult_I result1m = matchWay_I(result1, aDesc, tr);
            ReadResult_I result2m = matchWay_I(result2, aDesc, tr);
            ReadResult_I result3m = matchWay_I(result3, aDesc, tr);
 
            translationSig <= tr;

            readOutCached <= readCache(readEn, tr, result0m, result1m, result2m, result3m);
        end
    endtask

    

    
    function automatic ReadResult_I matchWay_I(input ReadResult_I rr, input AccessDesc aDesc, input Translation tr);
        ReadResult_I res = rr;
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


    function automatic ReadResult_I selectWay_I(input ReadResult_I res0, input ReadResult_I res1, input ReadResult_I res2, input ReadResult_I res3);
        if (res0.valid === 1) return res0; 
        if (res1.valid === 1) return res1; 
        if (res2.valid === 1) return res2; 
        return res3;
    endfunction


    function automatic InstructionCacheOutput readCache(input logic readEnable, input Translation tr, input ReadResult_I res0, input ReadResult_I res1, input ReadResult_I res2, input ReadResult_I res3);
        InstructionCacheOutput res = EMPTY_INS_CACHE_OUTPUT;
        ReadResult_I selected = selectWay_I(res0, res1, res2, res3);
        
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
        tlb.preloadTlbForTest(AbstractCore.globalParams.preloadedInsTlbL1, AbstractCore.globalParams.preloadedInsTlbL2);
        
        foreach (AbstractCore.globalParams.preloadedInsWays[i])
            copyToWay(AbstractCore.globalParams.preloadedInsWays[i]);
    endfunction


    task automatic reset();
        readOutUncached <= EMPTY_INS_CACHE_OUTPUT;
        readOutCached <= EMPTY_INS_CACHE_OUTPUT;

        blocksWay0 = '{default: null};
        blocksWay1 = '{default: null};
        blocksWay2 = '{default: null};
        blocksWay3 = '{default: null};
        
        tlb.resetTlb();
        
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




module InstructionCacheArray(
    input logic clk

);



    
    InsWay blocksWay0;
    InsWay blocksWay1;
    InsWay blocksWay2;
    InsWay blocksWay3;




    typedef logic LogicA[1];
    typedef Mword MwordA[1];
    typedef Dword DwordA[1];


    // Read interfaces
    generate
        genvar j;
        for (j = 0; j < 1; j++) begin: rdInterface
            ReadResult_I ar0 = '{0, 'x, '{default: 'x}}, ar1 = '{0, 'x, '{default: 'x}};

            task automatic readArray();
                AccessDesc aDesc;// = theExecBlock.accessDescs_E0[j];
                ar0 <= readWay_I(blocksWay0, aDesc);
                ar1 <= readWay_I(blocksWay1, aDesc);
            endtask

            always @(negedge clk) begin
                readArray();
            end
        end
    endgenerate


    // Filling
//    function automatic void allocInDynamicRange(input Dword adr);
//        tryFillWay(blocksWay1, adr);
//    endfunction
    
    // Write
//    task automatic doCachedWrite(input MemWriteInfo wrInfo);
//        if (!wrInfo.req || wrInfo.uncached) return;

//     //   void'(tryWriteWay(blocksWay0, wrInfo));
//     //   void'(tryWriteWay(blocksWay1, wrInfo));
//    endtask


    // Init/DB
    task automatic resetArray();
        blocksWay0 = '{default: null};
        blocksWay1 = '{default: null};
    endtask

    function automatic void preloadArrayForTest(); 
        //foreach (AbstractCore.globalParams.preloadedDataWays[i])
        //    copyToWay(AbstractCore.globalParams.preloadedDataWays[i]);
    endfunction

    // CAREFUL: this sets all data to default values
    function automatic void copyToWay(Dword pageAdr);
        Dword pageBase = getPageBaseD(pageAdr);

//        case (pageBase)
//            0:              initBlocksWay(blocksWay0, 0);
//            PAGE_SIZE:      initBlocksWay(blocksWay1, PAGE_SIZE);
//            default: $error("Incorrect page to init cache: %x", pageBase);
//        endcase
    endfunction




    always @(posedge clk) begin
//        if (dataFillEngine.notifyFill) begin
//            allocInDynamicRange(dataFillEngine.notifiedTr.padr);
//        end

        //doCachedWrite(writeReqs[0]);
    end

endmodule

