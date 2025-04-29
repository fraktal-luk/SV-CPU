
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


    typedef Translation TranslationA[N_MEM_PORTS];

    Translation translations_T[N_MEM_PORTS];

    Translation translations_Reg[N_MEM_PORTS] = '{default: DEFAULT_TRANSLATION};
    AccessDesc accessDescs_Reg[N_MEM_PORTS] = '{default: DEFAULT_ACCESS_DESC};


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



    // CAREFUL: below only for addresses in the range for data miss tests 
    DataBlock filledBlocks[Mword]; // Set of blocks in "force data miss" region which are "filled" and will not miss again 
    // CAREFUL: below only for addresses in the range for TLB miss tests 
    Translation filledMappings[Mword]; // Set of blocks in "force data miss" region which are "filled" and will not miss again 



    // Simple array for simple test cases, without blocks, transaltions etc
    Mbyte staticContent[PAGE_SIZE]; // So far this corresponds to way 0
    // Data and tag arrays
    PhysicalAddressHigh tagsForWay[BLOCKS_PER_WAY] = '{default: 0}; // tags for each block of way 0



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
        staticContent = '{default: 0};
        tagsForWay = '{default: 0};
        
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

    
    task automatic doWrite(input MemWriteInfo wrInfo);
        Mword adr = wrInfo.adr;
        Dword padr = wrInfo.padr;
        Mword val = wrInfo.value;

        if (!wrInfo.req) return;
        if (wrInfo.uncached) return;


        if (isStaticDataRange(adr)) begin
            if (wrInfo.size == SIZE_1) writeToStaticRangeB(adr, val);
            if (wrInfo.size == SIZE_4) writeToStaticRangeW(adr, val);
        end
        else begin 
            if (wrInfo.size == SIZE_1) writeToDynamicRangeB(adr, val);
            if (wrInfo.size == SIZE_4) writeToDynamicRangeW(adr, val);
        end
    
    endtask

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

    

    task automatic handleReads();
        accessDescs_Reg <= '{default: DEFAULT_ACCESS_DESC};
        translations_Reg <= '{default: DEFAULT_TRANSLATION};
        readOut <= '{default: EMPTY_DATA_CACHE_OUTPUT};

        foreach (theExecBlock.accessDescs[p]) begin
            AccessDesc aDesc = theExecBlock.accessDescs[p];
            Mword vadr = aDesc.vadr;

            if (!aDesc.active || $isunknown(vadr)) continue;
            else begin
                AccessInfo acc = analyzeAccess(vadr, aDesc.size);
                Translation tr = translations_T[p];
                PhysicalAddressHigh wayTag = tagsForWay[acc.block];
                DataCacheOutput thisResult = doReadAccess(acc, tr, aDesc);
                
                accessDescs_Reg[p] <= aDesc;
                translations_Reg[p] <= tr;
                readOut[p] <= thisResult;
            end
        end

    endtask


    always @(posedge clk) begin
        handleReads();

        if (dataFillEngine.notifyFill) allocInDynamicRange(dataFillEngine.notifiedAdr);
        if (tlbFillEngine.notifyFill) allocInTlb(tlbFillEngine.notifiedAdr);

        doWrite(TMP_writeReqs[0]);
    end

endmodule



/*****************************************************************/
module DataFillEngine#(type Key = Dword, parameter int DELAY = 14)
(
    input logic clk,
    
    input Translation translations[N_MEM_PORTS],
        input logic enable[N_MEM_PORTS],
        input Key dataIn[N_MEM_PORTS]
);
    // Fill logic
    logic notifyFill = 0;
    Key notifiedAdr = 'x; // TODO: change to Dword (with RQ)

    int     blockFillCounters[Key]; // Container for request in progress
    Key     readyBlocksToFill[$]; // Queue of request ready for immediate completion 


    task automatic resetBlockFills();
        blockFillCounters.delete();
        readyBlocksToFill.delete();
        notifyFill <= 0;
        notifiedAdr <= 'x;
    endtask


    task automatic handleBlockFills();
        Key adr;

        notifyFill <= 0;
        notifiedAdr <= 'x;

        foreach (blockFillCounters[a]) begin
            if (blockFillCounters[a] == 0) begin
                readyBlocksToFill.push_back(a);
                blockFillCounters[a] = -1;
            end
            else blockFillCounters[a]--;
        end

        if (readyBlocksToFill.size() == 0) return;

        adr = readyBlocksToFill.pop_front();
        blockFillCounters.delete(adr); // 

        notifyFill <= 1;
        notifiedAdr <= adr;
    endtask


    task automatic scheduleBlockFills();
        foreach (enable[p]) begin
            if (enable[p]) begin
                Key padr = dataIn[p];
                scheduleBlockFill(padr);
            end
        end
    endtask

    function automatic void scheduleBlockFill(input Key adr);
        Key physBase = (adr/BLOCK_SIZE)*BLOCK_SIZE;

        if (!blockFillCounters.exists(physBase))
            blockFillCounters[physBase] = DELAY;            
    endfunction


    always @(posedge clk) begin
        handleBlockFills();
        scheduleBlockFills();
    end

endmodule



//**********************************************************************************************************************************//
module UncachedSubsystem(
    input logic clk,
    input MemWriteInfo TMP_writeReqs[2]
);

    typedef struct {
        logic ready = 0;
    
        logic ongoing = 0;
        Mword adr = 'x;
        AccessSize size = SIZE_NONE;

        int counter = -1;
    } UncachedRead;

    UncachedRead uncachedReads[N_MEM_PORTS]; // Should be one (ignore other than [0])

    int uncachedCounter = -1;
    logic uncachedBusy = 0;
    Mword uncachedOutput = 'x;

    localparam Mword UNCACHED_BASE = 'h80000000;
    Mbyte uncachedArea[PAGE_SIZE];



    function automatic void UNC_scheduleUncachedRead(input AccessInfo aInfo);
        uncachedReads[0].ongoing = 1;
        uncachedReads[0].counter = 8;
        uncachedReads[0].adr = aInfo.adr;
        uncachedReads[0].size = aInfo.size;
    endfunction
    
    function automatic void UNC_clearUncachedRead();
        uncachedReads[0].ready = 0;
        uncachedReads[0].adr = 'x;
        uncachedOutput <= 'x;
    endfunction


    function automatic Mword readFromUncachedRange(input Mword adr, input AccessSize size);
        if (size == SIZE_1) return readByteUncached(adr);
        else if (size == SIZE_4) return readWordUncached(adr);
        else $error("Wrong access size");

        return 'x;
    endfunction
    
        function automatic void writeToUncachedRangeW(input Mword adr, input Mword val);
            PageWriter#(Word, 4, UNCACHED_BASE)::writeTyped(uncachedArea, adr, val);
        endfunction
    
        function automatic void writeToUncachedRangeB(input Mword adr, input Mbyte val);
            PageWriter#(Mbyte, 1, UNCACHED_BASE)::writeTyped(uncachedArea, adr, val);
        endfunction
    
        function automatic Mword readWordUncached(input Mword adr);
            return PageWriter#(Word, 4, UNCACHED_BASE)::readTyped(uncachedArea, adr);
        endfunction
    
        function automatic Mword readByteUncached(input Mword adr);
            return Mword'(PageWriter#(Mbyte, 1, UNCACHED_BASE)::readTyped(uncachedArea, adr));
        endfunction

        task automatic UNC_reset();
            uncachedCounter = -1;
            uncachedBusy = 0;
        endtask
    
        task automatic UNC_write(input MemWriteInfo wrInfo);
            Mword adr = wrInfo.adr;
            Dword padr = wrInfo.padr;
            Mword val = wrInfo.value;
            
            uncachedCounter = 15;
            uncachedBusy = 1;
            if (wrInfo.size == SIZE_1) writeToUncachedRangeB(adr, val);
            if (wrInfo.size == SIZE_4) writeToUncachedRangeW(adr, val);
        endtask
    

        // uncached read pipe
        task automatic UNC_handleUncachedData();
            if (uncachedCounter == 0) uncachedBusy = 0;
            if (uncachedCounter >= 0) uncachedCounter--;
            
            if (uncachedReads[0].ongoing) begin
                if (--uncachedReads[0].counter == 0) begin
                    uncachedReads[0].ongoing = 0;
                    uncachedReads[0].ready = 1;
                    uncachedOutput <= readFromUncachedRange(uncachedReads[0].adr, uncachedReads[0].size);
                end
            end

            foreach (theExecBlock.accessDescs[p]) begin
                AccessDesc aDesc = theExecBlock.accessDescs[p];
                Mword vadr = aDesc.vadr;
                if (!aDesc.active || $isunknown(vadr)) continue;
                else begin
                    AccessInfo acc = analyzeAccess(vadr, aDesc.size);
                    if (theExecBlock.accessDescs[p].uncachedReq) UNC_scheduleUncachedRead(acc); // request for uncached read
                    else if (theExecBlock.accessDescs[p].uncachedCollect) UNC_clearUncachedRead();
                end
            end
        endtask


    always @(posedge clk) begin
        UNC_handleUncachedData();        

        if (TMP_writeReqs[0].req && TMP_writeReqs[0].uncached) begin
            UNC_write(TMP_writeReqs[0]);
        end
    end

endmodule
