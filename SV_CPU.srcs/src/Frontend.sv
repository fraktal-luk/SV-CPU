
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;

import CacheDefs::*;


module Frontend(ref InstructionMap insMap, input logic clk, input EventInfo branchEventInfo, input EventInfo lateEventInfo);

    localparam logic FETCH_SINGLE = 0;
    localparam logic ENABLE_FRONT_BRANCHES = 1;


    localparam int FQ_SLACK = 3;    // Free space needed to accept cached fetch - accounts for pipeline between PC and FQ (stages 0, 1, 2)

    
    localparam int MAX_STAGE_UNCACHED = 4 + 12;
    // Free space in UFQ needed to allow uncached fetch: must account for the pipeline between PC and UFQ (+1 for branch detection stage)
    localparam int UFQ_SLACK = MAX_STAGE_UNCACHED + 1;
    localparam int UFQ_SIZE = UFQ_SLACK + 20;



    logic FETCH_UNC;
    logic fetchAllowCa;


    FrontStage fetchQueue[$:FETCH_QUEUE_SIZE];
    FrontStage uncachedFetchQueue[$:UFQ_SIZE];
    int fqSize = 0, ufqSize = 0;
    FrontStage stageRename0 = DEFAULT_FRONT_STAGE; //'{default: EMPTY_SLOT_F};

    Mword expectedTargetF2 = 'x;
    FrontStage finalFetchStage, finalFetchStageUncached;
    FrontStage stageIpSig, stageUncIpSig;

        logic fetchEnable; // DB
        Mword fetchAdr; // DB


        logic chk, chk_2, chk_3, chk_4;




    assign FETCH_UNC = !AbstractCore.CurrentConfig.enableMmu;

    assign fetchAllowCa = (fqSize < FETCH_QUEUE_SIZE - FQ_SLACK);

    // GENERAL
    assign fetchEnable = FETCH_UNC ? stageUncIpSig.active : stageIpSig.active;
    assign fetchAdr = FETCH_UNC ? stageUncIpSig.vadr : fetchLineBase(stageIpSig.vadr);


    /////////////////////////////////////
    // CACHED

    generate
        FrontStage stageFetch2 = DEFAULT_FRONT_STAGE;

        InstructionCacheOutput cacheOut;
        InstructionL1 instructionCache(clk, stage_IP.active, fetchLineBase(stage_IP.vadr), cacheOut);

        FrontStage stage_IP = DEFAULT_FRONT_STAGE, stageFetch0 = DEFAULT_FRONT_STAGE, stageFetch1 = DEFAULT_FRONT_STAGE;

        logic frontRedCa, frontRedOnMiss, groupMismatchF2;

        assign groupMismatchF2 = (fetchLineBase(stageFetch1.arr[0].adr) !== fetchLineBase(expectedTargetF2));
        assign frontRedCa = stageFetch1.active && groupMismatchF2;
        assign frontRedOnMiss = (stageFetch1.active && stageFetch1.status inside {CR_TLB_MISS, CR_TAG_MISS}) && !frontRedCa;
            // ^ We don't handle the miss if it's not on the predicted path - it would be discarded even if not missed
        
        assign stageIpSig = stage_IP;
        assign finalFetchStage = stageFetch2;

        always @(posedge clk) begin
            // Move to common part
            assert (!stage_IP.active || !stageUnc_IP.active) else $fatal(2, "2 fetchers active together");

            runCached();
        end

        task automatic runCached();
            if (lateEventInfo.redirect || branchEventInfo.redirect) begin
                flushFrontendBeforeF2();
                stage_IP <= makeStage_IP(redirectedTarget(), !FETCH_UNC, FETCH_SINGLE);

                expectedTargetF2 <= redirectedTarget();
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
    
            stageFetch1 <= setCacheResponse(stageFetch0, cacheOut, instructionCache.translationSig.padr);
            stageFetch2 <= getFrontStageF2(stageFetch1, expectedTargetF2);

            if (stageFetch1.active) begin
                assert (!$isunknown(expectedTargetF2)) else $fatal(2, "expectedTarget not set");
                expectedTargetF2 <= getNextTargetF2(stageFetch1, expectedTargetF2);
            end
        endtask


        task automatic flushFrontendBeforeF2();
            markKilledFrontStage(stage_IP.arr);
            markKilledFrontStage(stageFetch0.arr);
            markKilledFrontStage(stageFetch1.arr);
           
            stage_IP <= DEFAULT_FRONT_STAGE;
            stageFetch0 <= DEFAULT_FRONT_STAGE;
            stageFetch1 <= DEFAULT_FRONT_STAGE;

            markKilledFrontStage(stageFetch2.arr);
            stageFetch2 <= DEFAULT_FRONT_STAGE;
        endtask    

        function automatic FrontStage makeStage_IP(input Mword target, input logic on, input logic SINGLE);
            FrontStage res = DEFAULT_FRONT_STAGE;
            Mword baseAdr = fetchLineBase(target);
            logic already = 0;

            res.active = on;
            res.status = CR_HIT;
            res.vadr = target;

            foreach (res.arr[i]) begin
                Mword adr = baseAdr + 4*i;
                logic elemActive = !$isunknown(target) && (adr >= target) && !already;
                
                if (SINGLE && elemActive) already = 1; 
                
                res.arr[i] = '{elemActive, -1, adr, 'x, 0, 'x};
            end
            
            return res;
        endfunction


        function automatic FrontStage setCacheResponse(input FrontStage stage, input InstructionCacheOutput cacheOut, input Dword padr);
            OpSlotAF arr = stage.arr;
            FrontStage resFS = '{stage.active, cacheOut.status, PE_NONE, stage.vadr, padr, arr};
            ProgramEvent pe = PE_NONE;

            if ((stage.vadr % 4) != 0) pe = PE_FETCH_UNALIGNED_ADDRESS;
            else if (cacheOut.status == CR_INVALID) pe = PE_FETCH_INVALID_ADDRESS;
            else if (cacheOut.status == CR_UNCACHED) pe = PE_FETCH_DISALLOWED_ACCESS;
            else if (cacheOut.status == CR_TLB_MISS) pe = PE_FETCH_TLB_MISS;
            else if (cacheOut.status == CR_NOT_ALLOWED) pe = PE_FETCH_DISALLOWED_ACCESS;
            else if (cacheOut.status == CR_TAG_MISS) pe = PE_FETCH_CACHE_MISS;

            resFS.evt = pe;

            if (!stage.active) return DEFAULT_FRONT_STAGE;

            if (resFS.evt != PE_NONE) return resFS;

            foreach (arr[i]) begin
                Word realBits = cacheOut.words[i];

                if (arr[i].active) begin // Verify correct fetch
                    Translation tr = AbstractCore.retiredEmul.translateProgramAddress(arr[i].adr);
                    Word memBits = AbstractCore.programMem.fetch(tr.padr);
    
                    assert (realBits === memBits) else $fatal(2, "Bits fetched at %d not same: %p, %p", arr[i].adr, realBits, memBits);
                end
                
                arr[i].bits = realBits;
            end
            
            resFS.arr = arr;

            return resFS;
        endfunction


        function automatic FrontStage getFrontStageF2(input FrontStage fs, input Mword expectedTarget);
            FrontStage res = fs;
            OpSlotAF arrayF2 = clearBeforeStart(fs.arr, expectedTarget);

            int brSlot = scanBranches(arrayF2);

            if (!fs.active) return DEFAULT_FRONT_STAGE;

            arrayF2 = clearAfterBranch(arrayF2, brSlot);

            // Set prediction info
            if (brSlot != -1) arrayF2[brSlot].takenBranch = 1;

            res.padr = 'x;
            res.arr = arrayF2;

            return res;
        endfunction

        function automatic Mword getNextTargetF2(input FrontStage fs, input Mword expectedTarget);
            // If no taken branches, increment base adr. Otherwise get taken target
            OpSlotAF res = clearBeforeStart(fs.arr, expectedTarget);
            Mword adr = res[FETCH_WIDTH-1].adr + 4;
            
            if (!fs.active) return 'x;

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

    endgenerate


    ////////////////////////////////////
    // UNC

    UncachedFetchUnit uncachedUnit(clk);

    generate
        logic uncachedOn;

        FrontStage stageFetch2_U = DEFAULT_FRONT_STAGE;

        InstructionCacheOutput uncachedOut;
        InstructionUncached instructionUncached(clk, stageUnc_IP.active, stageUnc_IP.vadr, uncachedOut);

        FrontStage stageUnc_IP = DEFAULT_FRONT_STAGE, stageFetchUnc0 = DEFAULT_FRONT_STAGE, stageFetchUnc1 = DEFAULT_FRONT_STAGE;
        FrontStage stageFetchUncArr[2:MAX_STAGE_UNCACHED] = '{default: DEFAULT_FRONT_STAGE};
        FrontStage stageFetchUncLast;

        Mword expectedTargetF2_U;
        logic frontRedUnc;


        assign uncachedOn = FETCH_UNC; // UP in


        assign stageFetchUncLast = stageFetchUncArr[MAX_STAGE_UNCACHED];

        assign frontRedUnc = stageFetch2_U.active && stageFetch2_U.arr[0].takenBranch;
        assign expectedTargetF2_U = stageFetch2_U.arr[0].predictedTarget;

            assign stageUncIpSig = stageUnc_IP; // UP out
            assign finalFetchStageUncached = stageFetch2_U; // UP out


        always @(posedge clk) begin
            runUncached();
        end


        task automatic runUncached();
            if (lateEventInfo.redirect || branchEventInfo.redirect) begin
                flushUncachedPipe();
                stageUnc_IP <= makeStageUnc_IP(redirectedTarget(), uncachedOn, stageUnc_IP.vadr, 0);
            end
            else if (frontRedUnc) begin
                flushUncachedPipe();
                stageUnc_IP <= makeStageUnc_IP(expectedTargetF2_U, uncachedOn, stageUnc_IP.vadr, 1);
            end
            else begin
                fetchNormalUncached();
            end

            // If stopped by page cross guard, and pipeline becomes empty, it means that fetching is no longer specultive and can be resumed
            if (uncachedOn
                    && //stageEmptyAF(stageRename0.arr) // TODO: check for .active, not .arr?
                    stageRenamed0Empty()
                    //&& fqSize == 0
                    && fqEmpty()
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
            stageFetchUncArr[2] <= stageFetchUnc1;
            stageFetchUncArr[3:MAX_STAGE_UNCACHED] <= stageFetchUncArr[2:MAX_STAGE_UNCACHED-1];

            stageFetch2_U <= getFrontStageF2_U(stageFetchUncLast);
        endtask


        task automatic flushUncachedPipe();
            markKilledFrontStage(stageUnc_IP.arr);
            markKilledFrontStage(stageFetchUnc0.arr);
            markKilledFrontStage(stageFetchUnc1.arr);
            
            stageUnc_IP <= DEFAULT_FRONT_STAGE;
            stageFetchUnc0 <= DEFAULT_FRONT_STAGE;
            stageFetchUnc1 <= DEFAULT_FRONT_STAGE;

            foreach (stageFetchUncArr[i]) markKilledFrontStage(stageFetchUncArr[i].arr);
            stageFetchUncArr <= '{default: DEFAULT_FRONT_STAGE};

            markKilledFrontStage(stageFetch2_U.arr);
            stageFetch2_U <= DEFAULT_FRONT_STAGE;
        endtask


        function automatic FrontStage setUncachedResponse(input FrontStage stage, input InstructionCacheOutput uncachedOut);
            OpSlotAF arr = EMPTY_STAGE;
            FrontStage resFS = '{stage.active, uncachedOut.status, PE_NONE, stage.vadr, stage.vadr, stage.arr};
            ProgramEvent pe = PE_NONE;

            if ((stage.vadr % 4) != 0) pe = PE_FETCH_UNALIGNED_ADDRESS;
            else if (!physicalAddressValid(stage.vadr)) pe = PE_FETCH_INVALID_ADDRESS;

            resFS.evt = pe;

            if (!stage.active) return DEFAULT_FRONT_STAGE;                 

            if (resFS.evt != PE_NONE) return resFS;


            if (uncachedOut.status == CR_HIT) begin // Verify correct fetch
                Word bits = AbstractCore.programMem.fetch(stage.arr[0].adr);
                assert (bits === uncachedOut.words[0]) else $fatal(2, "Not this");
            end
            arr[0] = stage.arr[0];
            arr[0].bits = uncachedOut.words[0];

            resFS.arr = arr;

            return resFS;
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


        function automatic FrontStage getFrontStageF2_U(input FrontStage fs);
            FrontStage res = fs;
            OpSlotF slot0 = fs.arr[0];

            AbstractInstruction ins = decodeAbstract(slot0.bits);
            logic takeBranch = fs.active && (fs.status == CR_HIT) && slot0.active && ENABLE_FRONT_BRANCHES && isBranchAlwaysIns(ins);

            if (takeBranch) slot0.predictedTarget = slot0.adr + Mword'(ins.sources[1]);
            else slot0.predictedTarget = slot0.adr + 4;

            slot0.takenBranch = takeBranch;

            res.padr = 'x;
            res.arr[0] = slot0;

            return res;
        endfunction


        function automatic logic frontUncachedEmpty();
            if (stageFetchUnc0.active || stageFetchUnc1.active) return 0;

            foreach (stageFetchUncArr[i])
                if (stageFetchUncArr[i].active) return 0;

            return !stageFetch2_U.active && !stageUnc_IP.active
                && ufqEmpty();
        endfunction

    endgenerate


   ////////////////////////////////

    always @(posedge clk) begin
        runDownstream();
    end


    task automatic runDownstream();
        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
            flushFrontendFromF2();       
        end
        else performPostF2();

        fqSize <= fetchQueue.size();
        ufqSize <= uncachedFetchQueue.size();
    endtask


    task automatic performPostF2();
        if (!FETCH_UNC && finalFetchStage.active) begin
            assert (fetchQueue.size() < FETCH_QUEUE_SIZE) else $fatal(2, "Writing to full FetchQueue");
            fetchQueue.push_back(finalFetchStage);
        end
        else if (FETCH_UNC) begin
            if (finalFetchStageUncached.active) begin
                assert (uncachedFetchQueue.size() <= UFQ_SIZE - UFQ_SLACK) else $fatal(2, "Writing to full UncachedFetchQueue");
                uncachedFetchQueue.push_back(finalFetchStageUncached);
            end

            if (ufqSize > 0 && FETCH_UNC && fetchAllowCa) begin // fetchAllowCa can be relaxed to having 1 free slot in FQ
                FrontStage tmp;
                assert (fetchQueue.size() < FETCH_QUEUE_SIZE) else $fatal(2, "Writing to full FetchQueue");
                tmp = readFromUFQ();
                fetchQueue.push_back(tmp);
            end
        end

        begin
            FrontStage tmp = readFromFQ();
            stageRename0 <= tmp;
        end
    endtask


    task automatic flushFrontendFromF2();
        foreach (fetchQueue[i])
            markKilledFrontStage(fetchQueue[i].arr);
        fetchQueue.delete();

        // Unc
        foreach (uncachedFetchQueue[i])
            markKilledFrontStage(uncachedFetchQueue[i].arr);
        uncachedFetchQueue.delete();

        markKilledFrontStage(stageRename0.arr);
        stageRename0 <= DEFAULT_FRONT_STAGE;//'{default: EMPTY_SLOT_F};
    endtask


    function automatic int scanBranches(input OpSlotAF st);
        OpSlotAF res = st;
        int branchSlot = -1;
        Mword takenTargets[FETCH_WIDTH] = '{default: 'x};
        logic constantBranches[FETCH_WIDTH] = '{default: 'x};
        logic predictedBranches[FETCH_WIDTH] = '{default: 'x};
        
        // Decode branches and decide if taken.
        foreach (res[i]) begin
            AbstractInstruction ins = decodeAbstract(res[i].bits);
            constantBranches[i] = 0;
            
            if (ENABLE_FRONT_BRANCHES && isBranchImmIns(ins)) begin
                takenTargets[i] = res[i].adr + Mword'(ins.sources[1]);
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
                branchSlot = i;
                break;
            end
        end
 
        return branchSlot;
    endfunction



    // FUTURE: split along with split between FETCH_WIDTH and RENAME_WIDTH
    task automatic markKilledFrontStage(ref OpSlotAF stage);
        foreach (stage[i])
            if (stage[i].active) putMilestoneF(stage[i].id, InstructionMap::FlushFront);
    endtask

    function automatic Mword redirectedTarget();
        if (lateEventInfo.redirect)         return lateEventInfo.target;
        else if (branchEventInfo.redirect)  return branchEventInfo.target;
        else return 'x;
    endfunction


    function automatic FrontStage readFromFQ();
        // fqSize is written in prev cycle, so new items must wait at least a cycle in FQ
        if (fqSize > 0 && AbstractCore.renameAllow)
            return fetchQueue.pop_front();
        else
            return DEFAULT_FRONT_STAGE;
    endfunction

    function automatic FrontStage readFromUFQ();
        assert (ufqSize > 0) else $fatal(2, "Reading from UFQ: empty!");
        return uncachedFetchQueue.pop_front();
    endfunction


    function automatic logic fqEmpty();
        return fqSize == 0;
    endfunction

    function automatic logic ufqEmpty();
        return ufqSize == 0;
    endfunction

    function automatic logic stageRenamed0Empty();
        return !stageRename0.active;
    endfunction

endmodule
