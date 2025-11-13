
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;

import CacheDefs::*;


module Frontend(ref InstructionMap insMap, input logic clk, input EventInfo branchEventInfo, input EventInfo lateEventInfo);

    localparam logic FETCH_SINGLE = 0;

    typedef Word FetchGroup[FETCH_WIDTH];
    typedef OpSlotF FetchStage[FETCH_WIDTH];
    localparam FetchStage EMPTY_STAGE = '{default: EMPTY_SLOT_F};
    
    localparam logic ENABLE_FRONT_BRANCHES = 1;


    localparam int MAX_STAGE_UNCACHED = 4;



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

    assign FETCH_UNC = !AbstractCore.CurrentConfig.enableMmu;



    logic fetchAllowCa;

    logic fetchEnable;
    Mword fetchAdr;

    // Free space needed to accept cached fetch - accounts for pipeline between PC and FQ (stages 0, 1, 2)
    localparam int FQ_SLACK = 3;


//    // Helper (inline it?)
//    function logic fetchQueueAccepts(input int k);
//        // TODO: careful about numbers accounting for pipe lengths! 
//        return k < FETCH_QUEUE_SIZE - FQ_SLACK; // stages between IP stage and FQ?
//    endfunction
    


    FrontStage stageIpSig, stageUncIpSig;

    Mword expectedTargetF2 = 'x, expectedTargetF2_U = 'x;
    FetchStage fetchQueue[$:FETCH_QUEUE_SIZE];
    
    // Free space in UFQ needed to allow uncached fetch: must account for the pipeline between PC and UFQ (+1 for branch detection stage)
    localparam int UFQ_SLACK = MAX_STAGE_UNCACHED + 1;
    
    localparam int UFQ_SIZE = UFQ_SLACK + 20;
    FetchStage uncachedFetchQueue[$:UFQ_SIZE];

    int fqSize = 0, ufqSize = 0;

    OpSlotAF stageRename0 = '{default: EMPTY_SLOT_F};


    FrontStage stageFetch2 = DEFAULT_FRONT_STAGE, stageFetch2_U = DEFAULT_FRONT_STAGE;
    FrontStage stageFetch1sig, stageFetchUncLast;


        assign fetchAllowCa = (fqSize < FETCH_QUEUE_SIZE - FQ_SLACK);

 
        // UNC
        logic frontRedUnc;
        assign frontRedUnc = stageFetch2_U.active && stageFetch2_U.arr[0].takenBranch;

        // CACHED
        logic frontRedCa, frontRedOnMiss, groupMismatchF2;
        assign groupMismatchF2 = (fetchLineBase(stageFetch1sig.arr[0].adr) !== fetchLineBase(expectedTargetF2));
        assign frontRedCa = stageFetch1sig.active && groupMismatchF2;
        assign frontRedOnMiss = (stageFetch1sig.active && stageFetch1sig.status inside {CR_TLB_MISS, CR_TAG_MISS}) && !frontRedCa;
            // ^ We don't handle the miss if it's not on the predicted path - it would be discarded even if not missed

        // GENERAL
        assign fetchEnable = FETCH_UNC ? stageUncIpSig.active : stageIpSig.active;
        assign fetchAdr = FETCH_UNC ? fetchLineBase(stageUncIpSig.vadr) : fetchLineBase(stageIpSig.vadr);


    /////////////////////////////////////
    // CACHED

    generate
        InstructionCacheOutput cacheOut;
        InstructionL1 instructionCache(clk, stageIpSig.active, fetchLineBase(stageIpSig.vadr), cacheOut);

        FrontStage stage_IP = DEFAULT_FRONT_STAGE, stageFetch0 = DEFAULT_FRONT_STAGE, stageFetch1 = DEFAULT_FRONT_STAGE;
    
        assign stageIpSig = stage_IP;
        assign stageFetch1sig = stageFetch1;
        
        
        always @(posedge AbstractCore.clk) begin
            assert (!stage_IP.active || !stageUnc_IP.active) else $fatal(2, "2 fetchers active together");
            runCached();
        end
    
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
    
            if (fetchAllowCa && stage_IP.active) begin
                stage_IP <= makeStage_IP(nextTrg, stage_IP.active, FETCH_SINGLE);
                stageFetch0 <= stage_IP;
            end
            else
                stageFetch0 <= DEFAULT_FRONT_STAGE;
    
            stageFetch1 <= setCacheResponse(stageFetch0, cacheOut);
        endtask
    
    
        task automatic flushFrontendBeforeF2();
            markKilledFrontStage(stage_IP.arr);
            markKilledFrontStage(stageFetch0.arr);
            markKilledFrontStage(stageFetch1.arr);
           
            stage_IP <= DEFAULT_FRONT_STAGE;
            stageFetch0 <= DEFAULT_FRONT_STAGE;
            stageFetch1 <= DEFAULT_FRONT_STAGE;
        endtask    
    
        // ONE USE
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
            // TODO: set padr
            return '{stage.active, cachedOut.status, stage.vadr, 'x, setWords(stage.active, cachedOut.status, stage.arr, cachedOut)};
        endfunction
    
    endgenerate





    ////////////////////////////////////
    // UNC

    generate
        InstructionCacheOutput uncachedOut;
        InstructionUncached instructionUncached(clk, stageUncIpSig.active, stageUncIpSig.vadr, uncachedOut);

    
        FrontStage stageUnc_IP = DEFAULT_FRONT_STAGE;
        
        
        FrontStage stageFetchUnc0 = DEFAULT_FRONT_STAGE,
                   stageFetchUnc1 = DEFAULT_FRONT_STAGE;//, stageFetchUnc2 = DEFAULT_FRONT_STAGE, stageFetchUnc3 = DEFAULT_FRONT_STAGE, stageFetchUnc4 = DEFAULT_FRONT_STAGE;
        FrontStage stageFetchUncArr[2:MAX_STAGE_UNCACHED] = '{default: DEFAULT_FRONT_STAGE};

        assign stageUncIpSig = stageUnc_IP;
        assign stageFetchUncLast = stageFetchUncArr[MAX_STAGE_UNCACHED];


        always @(posedge AbstractCore.clk) begin
        
               // assert (stageFetchUncArr[2] === stageFetchUnc2) else $error("2 nt");
              //  assert (stageFetchUncArr[4] === stageFetchUnc4) else $error("4 nt");
        
            runUncached();
        end





        task automatic runUncached();
            if (lateEventInfo.redirect || branchEventInfo.redirect) begin
                flushUncachedPipe();
                stageUnc_IP <= makeStageUnc_IP(redirectedTarget(), FETCH_UNC, stageUnc_IP.vadr, 0);
            end
            else if (frontRedUnc) begin
                flushUncachedPipe();
                stageUnc_IP <= makeStageUnc_IP(expectedTargetF2_U, FETCH_UNC, stageUnc_IP.vadr, 1);
            end
            else begin
                fetchNormalUncached();
            end
            
            // If stopped by page cross guard, and pipeline becomes empty, it means that fetching is no longer specultive and can be resumed
            if (FETCH_UNC
                    && stageEmptyAF(stageRename0)
                    && fqSize == 0
                    
                    && AbstractCore.pipesEmpty()
                    && frontUncachedEmpty()
            ) begin
                stageUnc_IP.active <= 1; // Resume fetching after miss
            end
        endtask

        task automatic fetchNormalUncached();
            if (stageUnc_IP.active && ufqSize < UFQ_SLACK) begin
                stageUnc_IP <= makeStageUnc_IP(stageUnc_IP.vadr + 4, stageUnc_IP.active, stageUnc_IP.vadr, 1);
                stageFetchUnc0 <= stageUnc_IP;
            end
            else
                stageFetchUnc0 <= DEFAULT_FRONT_STAGE;

            stageFetchUnc1 <= setUncachedResponse(stageFetchUnc0, uncachedOut);
//                stageFetchUnc2 <= stageFetchUnc1;
//                stageFetchUnc3 <= stageFetchUnc2;
//                stageFetchUnc4 <= stageFetchUnc3;
            
            stageFetchUncArr[2] <= stageFetchUnc1; 
            stageFetchUncArr[3:MAX_STAGE_UNCACHED] <= stageFetchUncArr[2:MAX_STAGE_UNCACHED-1];
            
        endtask

        task automatic flushUncachedPipe();
            markKilledFrontStage(stageUnc_IP.arr);
            markKilledFrontStage(stageFetchUnc0.arr);
            markKilledFrontStage(stageFetchUnc1.arr);
//                markKilledFrontStage(stageFetchUnc2.arr);
//                markKilledFrontStage(stageFetchUnc3.arr);
//                markKilledFrontStage(stageFetchUnc4.arr);
            
            stageUnc_IP <= DEFAULT_FRONT_STAGE;
            stageFetchUnc0 <= DEFAULT_FRONT_STAGE;
            stageFetchUnc1 <= DEFAULT_FRONT_STAGE;
//                stageFetchUnc2 <= DEFAULT_FRONT_STAGE;
//                stageFetchUnc3 <= DEFAULT_FRONT_STAGE;
//                stageFetchUnc4 <= DEFAULT_FRONT_STAGE;
            
            foreach (stageFetchUncArr[i]) markKilledFrontStage(stageFetchUncArr[i].arr);
            stageFetchUncArr <= '{default: DEFAULT_FRONT_STAGE};
        endtask


        // ONE USE
        function automatic FetchStage setWordsUnc(input FetchStage s, input InstructionCacheOutput uncachedOut);
            FetchStage res = EMPTY_STAGE;
            if (!s[0].active) return EMPTY_STAGE; 

            if (uncachedOut.status == CR_HIT) begin
                Word bits = AbstractCore.programMem.fetch(s[0].adr);
                assert (bits === uncachedOut.words[0]) else $fatal(2, "Not this");
            end
            res[0] = s[0];
            res[0].bits = uncachedOut.words[0];
            
            return res;
        endfunction

        function automatic FrontStage setUncachedResponse(input FrontStage stage, input InstructionCacheOutput uncachedOut);            
            return '{stage.active, uncachedOut.status, stage.vadr, stage.vadr, setWordsUnc(stage.arr, uncachedOut)};
        endfunction

        function automatic FrontStage makeStageUnc_IP(input Mword target, input logic on, input Mword prevAdr, input logic guardPageCross);
            FrontStage res = DEFAULT_FRONT_STAGE;

            logic pageCross = (getPageBaseM(target) !== getPageBaseM(prevAdr));

            res.active = on && !(guardPageCross && pageCross);
            res.status = CR_HIT;
            res.vadr = target;
            res.padr = target;

            res.arr[0] = '{1, -1, target, 'x, 0, 'x};
            
            return res;
        endfunction


            function automatic logic frontUncachedEmpty();
                if (stageFetchUnc0.active || stageFetchUnc1.active) return 0;
            
                foreach (stageFetchUncArr[i])
                    if (stageFetchUncArr[i].active) return 0;
                
                return
                    ufqSize == 0
                && !stageFetch2_U.active
                
                   // && !stageFetchUnc4.active
                   // && !stageFetchUnc3.active
                   // && !stageFetchUnc2.active
                //&& !stageFetchUnc1.active
                //&& !stageFetchUnc0.active
                && !stageUnc_IP.active;
            endfunction
    endgenerate
    

   //////////////////////////
   ////////////////////////////////




    always @(posedge AbstractCore.clk) begin
        runDownstream();
    end


    task automatic runDownstream();
        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
            flushFrontendFromF2();       
            expectedTargetF2 <= redirectedTarget();
        end
        else begin
            performF2();
            performF2_Unc();
            performPostF2();
        end

        fqSize <= fetchQueue.size();
            ufqSize <= uncachedFetchQueue.size();
    endtask


    task automatic performF2();
        if (frontRedCa || frontRedOnMiss) begin
            stageFetch2 <= DEFAULT_FRONT_STAGE;
            return;
        end

        stageFetch2 <= getFrontStageF2(stageFetch1, expectedTargetF2);

        if (stageFetch1.active) begin
            assert (!$isunknown(expectedTargetF2)) else $fatal(2, "expectedTarget not set");
            expectedTargetF2 <= getNextTargetF2(stageFetch1, expectedTargetF2);
        end
        // If previous stage is empty, expectedTargetF2 stays unchanged 
    endtask

    task automatic performF2_Unc();
        if (frontRedUnc) begin
            stageFetch2_U <= DEFAULT_FRONT_STAGE;
            return;
        end

        stageFetch2_U <= getFrontStageF2_U(stageFetchUncLast);

        if (stageFetchUncLast.active)
            expectedTargetF2_U <= getNextTargetF2_U(stageFetchUncLast);
        else
           expectedTargetF2_U <= 'x;
    endtask


    task automatic performPostF2();
        if (stageFetch2.active && !FETCH_UNC) begin
            assert (fetchQueue.size() < FETCH_QUEUE_SIZE) else $fatal(2, "Writing to full FetchQueue");
            fetchQueue.push_back(stageFetch2.arr);
        end
        else if (FETCH_UNC) begin
            if (stageFetch2_U.active) begin
                assert (uncachedFetchQueue.size() <= UFQ_SIZE - UFQ_SLACK) else $fatal(2, "Writing to full UncachedFetchQueue");
                uncachedFetchQueue.push_back(stageFetch2_U.arr);
            end

            if (ufqSize > 0 && FETCH_UNC && fetchAllowCa) begin // fetchAllowCa can be relaxed to having 1 free slot in FQ 
                assert (fetchQueue.size() < FETCH_QUEUE_SIZE) else $fatal(2, "Writing to full FetchQueue");
                fetchQueue.push_back(readFromUFQ());
            end
        end

        stageRename0 <= readFromFQ();
    endtask

    task automatic flushFrontendFromF2();
        markKilledFrontStage(stageFetch2.arr);
        expectedTargetF2 <= 'x;
        stageFetch2 <= DEFAULT_FRONT_STAGE;

        // Unc
        markKilledFrontStage(stageFetch2_U.arr);
        expectedTargetF2_U <= 'x;
        stageFetch2_U <= DEFAULT_FRONT_STAGE;
        //

        foreach (fetchQueue[i])
            markKilledFrontStage(fetchQueue[i]);

        fetchQueue.delete();

        // Unc
        foreach (uncachedFetchQueue[i])
            markKilledFrontStage(uncachedFetchQueue[i]);

        uncachedFetchQueue.delete();
        // 


        markKilledFrontStage(stageRename0);

        stageRename0 <= '{default: EMPTY_SLOT_F};
    endtask




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
        if (brSlot != -1) arrayF2[brSlot].takenBranch = 1;
       
        return '{fs.active, fs.status, fs.vadr, 'x, arrayF2};
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



    function automatic FrontStage getFrontStageF2_U(input FrontStage fs);
        FetchStage arrayF2 = fs.arr;
        
        int brSlot = scanBranches(arrayF2);
                    
        // Set prediction info
        if (brSlot != -1) arrayF2[brSlot].takenBranch = 1;

        return '{fs.active, fs.status, fs.vadr, 'x, arrayF2};
    endfunction

    function automatic Mword getNextTargetF2_U(input FrontStage fs);
        FetchStage res = fs.arr;
        Mword adr = res[0].adr + 4;

        if (res[0].active) begin
            AbstractInstruction ins = decodeAbstract(res[0].bits);
            
            if (ENABLE_FRONT_BRANCHES && isBranchImmIns(ins)) begin
                if (isBranchAlwaysIns(ins)) begin
                    adr = res[0].adr + Mword'(ins.sources[1]);
                end
            end
        end

        return adr;
    endfunction

///////////////////////////////


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

    function automatic OpSlotAF readFromUFQ();
        assert (ufqSize > 0) else $fatal(2, "Reading from UFQ: empty!");
        return uncachedFetchQueue.pop_front();
    endfunction


endmodule
