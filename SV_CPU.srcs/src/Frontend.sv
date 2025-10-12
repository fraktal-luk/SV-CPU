
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;

import CacheDefs::*;


module Frontend(ref InstructionMap insMap, input logic clk, input EventInfo branchEventInfo, input EventInfo lateEventInfo);

    localparam logic FETCH_SINGLE = 0;//1;

    typedef Word FetchGroup[FETCH_WIDTH];
    typedef OpSlotF FetchStage[FETCH_WIDTH];
    localparam FetchStage EMPTY_STAGE = '{default: EMPTY_SLOT_F};
    
    localparam logic ENABLE_FRONT_BRANCHES = 1;

    typedef struct {
        logic active;
        CacheReadStatus status;
        Mword vadr;
        Dword padr;
        FetchStage arr;
    } FrontStage;
    
    localparam FrontStage DEFAULT_FRONT_STAGE = '{0, CR_INVALID, 'x, 'x, EMPTY_STAGE};


        logic chk, chk_2, chk_3, chk_4;

    logic FETCH_UNC;


    logic fetchEnable;//, fetchEnableCached;
    Mword fetchAdr;//, fetchAdrCached;

    FrontStage stageFetchSelected1;


    InstructionCacheOutput cacheOut;
    
    FrontStage stage_IP = DEFAULT_FRONT_STAGE,
               stageFetch0 = DEFAULT_FRONT_STAGE, stageFetch1 = DEFAULT_FRONT_STAGE, stageFetch2 = DEFAULT_FRONT_STAGE, stageFetch2_U = DEFAULT_FRONT_STAGE;

    Mword expectedTargetF2 = 'x, expectedTargetF2_U = 'x;
    FetchStage fetchQueue[$:FETCH_QUEUE_SIZE];
    int fqSize = 0;

    OpSlotAF stageRename0 = '{default: EMPTY_SLOT_F};

    logic frontRed,
          frontRedCa, frontRedOnMiss, blockMismatchF2;

    InstructionL1 instructionCache(clk, stage_IP.active, fetchLineBase(stage_IP.vadr), cacheOut);
    

    assign FETCH_UNC = !AbstractCore.CurrentConfig.enableMmu;



    ///////////////
    // UNCACHED

    // TODO: encapsulate uncached fetching engine; implement a queue to buffer generated fetch addresses; ensure that conditional branches are always predicted not taken when in uncached mode;
    //       implement mechanism to stop fetching when end of 4kB area (mem attr granularity) is reached - to prevent accidental fetching from an area with side effects, and resume fetching
    //       when a instruciton stream is redirected or core pipeline becomes empty (so it is known architecturally that we intend to move forward with sequential fetching)

    InstructionCacheOutput uncachedOut;
    logic frontRedUnc,// wordMismatchF2,  
            frontUncBr;

    FrontStage stageUnc_IP = DEFAULT_FRONT_STAGE,
               stageFetchUnc0 = DEFAULT_FRONT_STAGE, stageFetchUnc1 = DEFAULT_FRONT_STAGE,
               stageFetchUnc2 = DEFAULT_FRONT_STAGE, stageFetchUnc3 = DEFAULT_FRONT_STAGE, stageFetchUnc4 = DEFAULT_FRONT_STAGE;

    InstructionUncached instructionUncached(clk, stageUnc_IP.active, stageUnc_IP.vadr, uncachedOut);


        assign frontUncBr = stageFetch2_U.active && stageFetch2_U.arr[0].takenBranch;

            assign chk = stageFetch2_U.active ^ stageFetch2.active;
             assign chk_2 =       shiftTo0(stageFetch2) === stageFetch2_U;

   assign frontRedUnc = //stageFetchUnc4.active && wordMismatchF2;
                        frontUncBr;
   // assign wordMismatchF2 = (stageFetchUnc4.vadr !== expectedTargetF2);    


    always @(posedge AbstractCore.clk) begin
        runUncached();
    end

    //////////

//      How to handle:
//        CR_INVALID,    continue in pipeline, cause exception
//            CR_NOT_MAPPED, // continue, exception
//        CR_TLB_MISS
//        CR_TAG_MISS,       treat as empty?  >> if so, must ensure that later fetch outputs are also ignored: otherwise we can omit a group and accept subsequent ones :((
//                          better answer: cause redirect to missed address; maybe deactivate fetch block until line is filled?
//        CR_HIT,        continue in pipeline; if desc says not executable then cause exception
//        CR_MULTIPLE    cause (async?) error
//


    assign stageFetchSelected1 = //FETCH_UNC ? stageFetchUnc4 : 
                                    stageFetch1;
    assign frontRed = FETCH_UNC ? frontRedUnc : frontRedCa;

    assign blockMismatchF2 = (fetchLineBase(stageFetch1.arr[0].adr) !== fetchLineBase(expectedTargetF2));
    assign frontRedCa = stageFetch1.active && blockMismatchF2;
    assign frontRedOnMiss = (stageFetch1.active && stageFetch1.status inside {CR_TLB_MISS, CR_TAG_MISS}) && !frontRedCa;
        // ^ We don't handle the miss if it's not on the predicted path - it would be discarded even if not missed


       //assign chk = 0;
       //assign chk_2 = stageFetchSelected1.active;
       //assign chk_3 = chk ^ chk_2;
      // assign chk_4 = ;(anyActiveFetch(fetchStageSelected1, 'z) === stageFetchSelected1.active);


    always @(posedge AbstractCore.clk) begin
        assert (!stage_IP.active || !stageUnc_IP.active) else $fatal(2, "2 fetchers active together");
        
        runCached();
    end


    always @(posedge AbstractCore.clk) begin
        runDownstream();
    end


    assign fetchEnable = FETCH_UNC ? stageUnc_IP.active : stage_IP.active;
    assign fetchAdr = FETCH_UNC ? fetchLineBase(stageUnc_IP.vadr) : fetchLineBase(stage_IP.vadr);




    task automatic runCached();
        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
            flushFrontendBeforeF2();
            stage_IP <= makeStage_IP(redirectedTarget(), !FETCH_UNC, FETCH_SINGLE);
        end
        else if (frontRedCa || frontRedOnMiss) begin
            flushFrontendBeforeF2();
            stage_IP <= makeStage_IP(expectedTargetF2, !FETCH_UNC && !frontRedOnMiss, FETCH_SINGLE);
        end
        else begin
            fetchNormalCached();
        end

        if (instructionCache.tlbFillEngine.notifyFill || instructionCache.blockFillEngine.notifyFill) begin
            if (!FETCH_UNC) stage_IP.active <= 1; // Resume fetching after miss
        end
    endtask


    task automatic fetchNormalCached();
        Mword nextTrg = FETCH_SINGLE ? stage_IP.vadr + 4 : fetchLineBase(stage_IP.vadr) + FETCH_WIDTH*4;

        if (AbstractCore.fetchAllow && stage_IP.active) begin
            stage_IP <= makeStage_IP(nextTrg, stage_IP.active, FETCH_SINGLE);
            stageFetch0 <= stage_IP;
        end
        else
            stageFetch0 <= DEFAULT_FRONT_STAGE;

        stageFetch1 <= setCacheResponse(stageFetch0, cacheOut);
    endtask




    task automatic runDownstream();
        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
            flushFrontendFromF2();       
            expectedTargetF2 <= redirectedTarget();
        end
        else begin
            performF2();
            performPostF2();
        end

        fqSize <= fetchQueue.size();
    endtask


    task automatic performF2();
        if (frontRed || frontRedOnMiss) begin
            stageFetch2 <= DEFAULT_FRONT_STAGE;
                stageFetch2_U <= DEFAULT_FRONT_STAGE;
            return;
        end

        stageFetch2 <= getFrontStageF2(stageFetchSelected1, expectedTargetF2);
            stageFetch2_U <= getFrontStageF2_U(stageFetchUnc4);

        if (stageFetchSelected1.active) begin
            assert (!$isunknown(expectedTargetF2)) else $fatal(2, "expectedTarget not set");
            expectedTargetF2 <= getNextTargetF2(stageFetchSelected1, expectedTargetF2);
        end
        
        if (stageFetchUnc4.active) begin
            expectedTargetF2_U <= getNextTargetF2_U(stageFetchUnc4);//, expectedTargetF2_U);
        end
    endtask


    task automatic performPostF2();
        if (stageFetch2.active && !FETCH_UNC) begin
            assert (fetchQueue.size() < FETCH_QUEUE_SIZE) else $fatal(2, "Writing to full FetchQueue");
            fetchQueue.push_back(stageFetch2.arr);
        end
        else if (stageFetch2_U.active && FETCH_UNC) begin
            assert (fetchQueue.size() < FETCH_QUEUE_SIZE) else $fatal(2, "Writing to full FetchQueue");
            fetchQueue.push_back(stageFetch2_U.arr);
        end

        stageRename0 <= readFromFQ();
    endtask

    task automatic flushFrontendFromF2();
        markKilledFrontStage(stageFetch2.arr);
            markKilledFrontStage(stageFetch2_U.arr);
        markKilledFrontStage(stageRename0);

        expectedTargetF2 <= 'x;
            expectedTargetF2_U <= 'x;

        stageFetch2 <= DEFAULT_FRONT_STAGE;
            stageFetch2_U <= DEFAULT_FRONT_STAGE;

        foreach (fetchQueue[i])
            markKilledFrontStage(fetchQueue[i]);

        fetchQueue.delete();

        stageRename0 <= '{default: EMPTY_SLOT_F};
    endtask


    task automatic flushFrontendBeforeF2();
        markKilledFrontStage(stage_IP.arr);
        markKilledFrontStage(stageFetch0.arr);
        markKilledFrontStage(stageFetch1.arr);
       
        stage_IP <= DEFAULT_FRONT_STAGE;
        stageFetch0 <= DEFAULT_FRONT_STAGE;
        stageFetch1 <= DEFAULT_FRONT_STAGE;
    endtask    


    function automatic FetchStage setWords(input logic active, input CacheReadStatus status, input FetchStage s, input InstructionCacheOutput cacheOut);
        FetchStage res = s;

        if (!active || status != CR_HIT) return res;

        foreach (res[i]) begin
            Word realBits = cacheOut.words[i];

            if (res[i].active) begin
                Translation tr = AbstractCore.retiredEmul.translateProgramAddress(res[i].adr);
                Word bits = AbstractCore.programMem.fetch(tr.padr);

                assert (realBits === bits) else $fatal(2, "Bits fetched at %d not same: %p, %p", res[i].adr, realBits, bits);
            end
            
            res[i].bits = realBits;
        end
        return res;
    endfunction


    function automatic FrontStage setCacheResponse(input FrontStage stage, input InstructionCacheOutput cachedOut);
        FrontStage res;
        
        return '{stage.active, cachedOut.status, stage.vadr, 'x, setWords(stage.active, cachedOut.status, stage.arr, cachedOut)};
    endfunction



    function automatic FetchStage clearBeforeStart(input FetchStage st, input Mword expectedTarget);
        FetchStage res = st;

        foreach (res[i])
            res[i].active = res[i].active && !$isunknown(res[i].adr) && (res[i].adr >= expectedTarget);
        
        return res;       
    endfunction


    function automatic FetchStage clearAfterBranch(input FetchStage st, input int branchSlot);
        FetchStage res = st;
        
        if (branchSlot == -1) return res;
        
        foreach (res[i])
            if (i > branchSlot) res[i].active = 0;

        return res;        
    endfunction



    function automatic int scanBranches(input FetchStage st);
        FetchStage res = st;
        
        Mword nextAdr = res[FETCH_WIDTH-1].adr + 4;
        int branchSlot = -1;
        
        Mword takenTargets[FETCH_WIDTH] = '{default: 'x};
        logic active[FETCH_WIDTH] = '{default: 'x};
        logic constantBranches[FETCH_WIDTH] = '{default: 'x};
        logic predictedBranches[FETCH_WIDTH] = '{default: 'x};
        
        // Decode branches and decide if taken.
        foreach (res[i]) begin
            AbstractInstruction ins = decodeAbstract(res[i].bits);
            active[i] = res[i].active;
            constantBranches[i] = 0;
            
            if (ENABLE_FRONT_BRANCHES && isBranchImmIns(ins)) begin
                Mword trg = res[i].adr + Mword'(ins.sources[1]);
                takenTargets[i] = trg;
                constantBranches[i] = 1;
                predictedBranches[i] = isBranchAlwaysIns(ins);            
            end

            if (isBranchRegIns(ins)) begin
                
            end
            
        end
        
        // Scan for first taken branch
        foreach (res[i]) begin
            if (!res[i].active) continue;
            
            if (constantBranches[i] && predictedBranches[i]) begin
                nextAdr = takenTargets[i];
                branchSlot = i;
                break;
            end
        end
 
        return branchSlot;
    endfunction


    function automatic FetchStage TMP_getStageF2(input FrontStage fs, input Mword expectedTarget);
        if (!fs.active) return fs.arr;
        return clearBeforeStart(fs.arr, expectedTarget);        
    endfunction


    function automatic FrontStage getFrontStageF2(input FrontStage fs, input Mword expectedTarget);
        FetchStage arrayF2 = TMP_getStageF2(fs, expectedTarget);
        int brSlot = scanBranches(arrayF2);
        
        arrayF2 = clearAfterBranch(arrayF2, brSlot);
        
        // Set prediction info
        if (brSlot != -1) begin
            arrayF2[brSlot].takenBranch = 1;
        end
       
        return '{fs.active, fs.status, fs.vadr, 'x, arrayF2};
    endfunction

        
        function automatic FrontStage shiftTo0(input FrontStage fs);
            FetchStage arrayF2 = //TMP_getStageF2(fs, expectedTarget);
                                 fs.arr;
            FetchStage arrNew = '{default: EMPTY_SLOT_F};
            
           
            // TMP: shift to slot 0
            foreach (arrayF2[i])
                if (arrayF2[i].active) begin
                    arrNew[0] = arrayF2[i];
                    break;
                end 
           
            return '{fs.active, fs.status, fs.vadr, 'x, arrNew};
        endfunction


        function automatic FrontStage getFrontStageF2_U(input FrontStage fs);//, input Mword expectedTarget);
            FetchStage arrayF2 = //TMP_getStageF2(fs, expectedTarget);
                                 fs.arr;
            FetchStage arrNew = '{default: EMPTY_SLOT_F};
            
            int brSlot = scanBranches(arrayF2);
            
               // arrayF2 = clearAfterBranch(arrayF2, brSlot);
            
            // Set prediction info
            if (brSlot != -1) begin
                arrayF2[brSlot].takenBranch = 1;
            end
           
            // TMP: shift to slot 0
            foreach (arrayF2[i])
                if (arrayF2[i].active) begin
                    arrNew[0] = arrayF2[i];
                    break;
                end 
           
            return '{fs.active, fs.status, fs.vadr, 'x, arrNew};
        endfunction

 
    
    function automatic Mword getNextTargetF2(input FrontStage fs, input Mword expectedTarget);
        // If no taken branches, increment base adr. Otherwise get taken target
        FetchStage res = TMP_getStageF2(fs, expectedTarget);
        Mword adr = res[FETCH_WIDTH-1].adr + 4;
        
        foreach (res[i]) 
            if (res[i].active) begin
                AbstractInstruction ins = decodeAbstract(res[i].bits);
                
                adr = res[i].adr + 4;   // Last active
                
                if (ENABLE_FRONT_BRANCHES && isBranchImmIns(ins)) begin
                    if (isBranchAlwaysIns(ins)) begin
                        adr = res[i].adr + Mword'(ins.sources[1]);
                        break;
                    end
                end
            end
        
        return adr;
    endfunction

    function automatic Mword getNextTargetF2_U(input FrontStage fs);//, input Mword expectedTarget);
        // If no taken branches, increment base adr. Otherwise get taken target
        FetchStage res = fs.arr;//TMP_getStageF2(fs, expectedTarget);
        Mword adr = res[FETCH_WIDTH-1].adr + 4;
        
        foreach (res[i]) 
            if (res[i].active) begin
                AbstractInstruction ins = decodeAbstract(res[i].bits);
                
                adr = res[i].adr + 4;   // Last active
                
                if (ENABLE_FRONT_BRANCHES && isBranchImmIns(ins)) begin
                    if (isBranchAlwaysIns(ins)) begin
                        adr = res[i].adr + Mword'(ins.sources[1]);
                        break;
                    end
                end
            end
        
        return adr;
    endfunction

   //////////////////////////
   //////////////////////////

        task automatic runUncached();
            if (lateEventInfo.redirect || branchEventInfo.redirect) begin
                flushUncachedPipe();
                stageUnc_IP <= makeStage_IP(redirectedTarget(), FETCH_UNC, 1);
            end
            else if (/*frontRedUnc*/ frontUncBr) begin
                flushUncachedPipe();
                stageUnc_IP <= makeStage_IP(/*expectedTargetF2*/ expectedTargetF2_U, FETCH_UNC, 1);
            end
            else begin
                fetchNormalUncached();
            end
        endtask

        task automatic fetchNormalUncached();
            if (AbstractCore.fetchAllow && stageUnc_IP.active) begin
                stageUnc_IP <= makeStage_IP(stageUnc_IP.vadr + 4, stageUnc_IP.active, 1);
                stageFetchUnc0 <= stageUnc_IP;
            end
            else
                stageFetchUnc0 <= DEFAULT_FRONT_STAGE;

            stageFetchUnc1 <= setUncachedResponse(stageFetchUnc0, uncachedOut);
            stageFetchUnc2 <= stageFetchUnc1;
            stageFetchUnc3 <= stageFetchUnc2;
            stageFetchUnc4 <= stageFetchUnc3;
        endtask

        task automatic flushUncachedPipe();
            markKilledFrontStage(stageUnc_IP.arr);
            markKilledFrontStage(stageFetchUnc0.arr);
            markKilledFrontStage(stageFetchUnc1.arr);
            markKilledFrontStage(stageFetchUnc2.arr);
            markKilledFrontStage(stageFetchUnc3.arr);
            markKilledFrontStage(stageFetchUnc4.arr);
            
            stageUnc_IP <= DEFAULT_FRONT_STAGE;
            stageFetchUnc0 <= DEFAULT_FRONT_STAGE;
            stageFetchUnc1 <= DEFAULT_FRONT_STAGE;
            stageFetchUnc2 <= DEFAULT_FRONT_STAGE;
            stageFetchUnc3 <= DEFAULT_FRONT_STAGE;
            stageFetchUnc4 <= DEFAULT_FRONT_STAGE;
        endtask

        function automatic FetchStage setWordsUnc(input FetchStage s, input InstructionCacheOutput uncachedOut);
            FetchStage res = s, res_N = EMPTY_STAGE;
    
            foreach (res[i]) begin
                if (res[i].active) begin
                    Word bits = AbstractCore.programMem.fetch(res[i].adr);
    
                    assert (bits === uncachedOut.words[0]) else $fatal(2, "Not this");
                    
                    res_N[0] = res[i];
                    res_N[0].bits = uncachedOut.words[0];
                    break;
                end
            end
            
            return res_N;
        endfunction
        
    
        
        function automatic FrontStage setUncachedResponse(input FrontStage stage, input InstructionCacheOutput uncachedOut);
            FrontStage res;
            
            return '{stage.active, uncachedOut.status, stage.vadr, stage.vadr, setWordsUnc(stage.arr, uncachedOut)};
        endfunction
   
   //////////////////////////
   //////////////////////////

    // FUTURE: split along with split between FETCH_WIDTH and RENAME_WIDTH
    task automatic markKilledFrontStage(ref FetchStage stage);
        foreach (stage[i])
            if (stage[i].active) putMilestoneF(stage[i].id, InstructionMap::FlushFront);
    endtask

    function automatic Mword redirectedTarget();
        if (lateEventInfo.redirect)         return lateEventInfo.target;
        else if (branchEventInfo.redirect)  return branchEventInfo.target;
        else return 'x;
    endfunction

    function automatic FrontStage makeStage_IP(input Mword target, input logic on, input logic SINGLE);
        FrontStage res = DEFAULT_FRONT_STAGE;
        Mword baseAdr = fetchLineBase(target);
        logic already = 0;

        res.active = on;
        res.status = CR_HIT;
        res.vadr = target;

        for (int i = 0; i < FETCH_WIDTH; i++) begin
            Mword adr = baseAdr + 4*i;
            logic elemActive = !$isunknown(target) && (adr >= target) && !already;
            
            if (SINGLE && elemActive) already = 1; 
            
            res.arr[i] = '{elemActive, -1, adr, 'x, 0, 'x};
        end
        
        return res;
    endfunction


    function automatic OpSlotAF readFromFQ();
        // fqSize is written in prev cycle, so new items must wait at least a cycle in FQ
        if (fqSize > 0 && AbstractCore.renameAllow)
            return fetchQueue.pop_front();
        else
            return '{default: EMPTY_SLOT_F};
    endfunction

endmodule
