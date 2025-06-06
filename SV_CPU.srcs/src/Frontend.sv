
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;

import CacheDefs::*;


module Frontend(ref InstructionMap insMap, input logic clk, input EventInfo branchEventInfo, input EventInfo lateEventInfo);

        localparam logic FETCH_SINGLE = 0;//1;
        localparam logic FETCH_UNC = 0;
            logic chk, chk_2;


    typedef Word FetchGroup[FETCH_WIDTH];
    typedef OpSlotF FetchStage[FETCH_WIDTH];
    localparam FetchStage EMPTY_STAGE = '{default: EMPTY_SLOT_F};
    
    localparam logic ENABLE_FRONT_BRANCHES = 1;


    logic fetchEnable;
    Mword fetchAdr;
    InstructionCacheOutput cacheOut;

    assign fetchEnable = FETCH_UNC ? stageUnc_IP.active : stage_IP.active;
    assign fetchAdr = FETCH_UNC ? fetchLineBase(stageUnc_IP.adr) : fetchLineBase(stage_IP.adr);


    int fqSize = 0;

   
    typedef struct {
        logic active;
        Mword adr;
        FetchStage arr;
    } FrontStage;
    
    localparam FrontStage DEFAULT_FRONT_STAGE = '{0, 'x, EMPTY_STAGE};


    FrontStage stage_IP = DEFAULT_FRONT_STAGE, stageUnc_IP = DEFAULT_FRONT_STAGE;
    FetchStage fetchStage0 = EMPTY_STAGE, fetchStage1 = EMPTY_STAGE, fetchStage2 = EMPTY_STAGE;
    FetchStage fetchStageUnc0 = EMPTY_STAGE, fetchStageUnc1 = EMPTY_STAGE, fetchStageUnc2 = EMPTY_STAGE, fetchStageUnc3 = EMPTY_STAGE, fetchStageUnc4 = EMPTY_STAGE;
    FetchStage fetchStageSelected1;
    Mword expectedTargetF2 = 'x;
    FetchStage fetchQueue[$:FETCH_QUEUE_SIZE];


    int fetchCtr = 0; // TODO: incremented by FETCH_WIDTH, but should be by 1 when fetching mode is single instruction 
    OpSlotAF stageRename0 = '{default: EMPTY_SLOT_F};

    logic frontRed;


    InstructionL1 instructionCache(clk, fetchEnable, fetchAdr, cacheOut);


//      How to handle:
//        CR_INVALID,    continue in pipeline, cause exception
//            CR_NOT_MAPPED, // continue, exception
//        CR_TLB_MISS
//        CR_TAG_MISS,       treat as empty?  >> if so, must ensure that later fetch outputs are also ignored: otherwise we can omit a group and accept subsequent ones :((
//                          better answer: cause redirect to missed address; maybe deactivate fetch block until line is filled?
//        CR_HIT,        continue in pipeline; if desc says not executable then cause exception
//        CR_MULTIPLE    cause (async?) error
//

    assign fetchStageSelected1 = FETCH_UNC ? fetchStageUnc4 : fetchStage1;

    assign frontRed = anyActiveFetch(fetchStageSelected1) && (fetchLineBase(fetchStageSelected1[0].adr) !== fetchLineBase(expectedTargetF2));



    always @(posedge AbstractCore.clk) begin
        if (lateEventInfo.redirect || branchEventInfo.redirect)
            redirectFront();
        else
            fetchAndEnqueue();

        fqSize <= fetchQueue.size();
    end

    task automatic redirectF2();
        flushFrontendBeforeF2();
 
        stage_IP <= makeStage_IP(expectedTargetF2, !FETCH_UNC, FETCH_SINGLE);
        stageUnc_IP <= makeStage_IP(expectedTargetF2, FETCH_UNC, 1);

        incFetchCounter();   
    endtask

    task automatic incFetchCounter();
        if (FETCH_SINGLE) fetchCtr <= fetchCtr + 1;
        else fetchCtr <= fetchCtr + FETCH_WIDTH;
    endtask





    // FUTURE: introduce fetching by 1 instrution? (for unchached access)
    task automatic fetchNormal();
        if (AbstractCore.fetchAllow && stage_IP.active) begin
            Mword nextTrg = fetchLineBase(stage_IP.adr) + FETCH_WIDTH*4;
            if (FETCH_SINGLE) nextTrg = stage_IP.adr + 4;
            stage_IP <= makeStage_IP(nextTrg, stage_IP.active, FETCH_SINGLE);

            incFetchCounter();   
        end
        else if (AbstractCore.fetchAllow && stageUnc_IP.active) begin
            Mword nextTrg = stageUnc_IP.adr + 4;
            stageUnc_IP <= makeStage_IP(nextTrg, stageUnc_IP.active, 1);

            incFetchCounter();
        end
        

        if (stage_IP.active && AbstractCore.fetchAllow) begin
            fetchStage0 <= stage_IP.arr;
        end
        else if (stageUnc_IP.active && AbstractCore.fetchAllow) begin
            fetchStage0 <= stageUnc_IP.arr;
        end
        else begin
            fetchStage0 <= EMPTY_STAGE;
        end

        fetchStage1 <= setWords(fetchStage0, cacheOut);

            if (stageUnc_IP.active && AbstractCore.fetchAllow) fetchStageUnc0 <= stageUnc_IP.arr;
            else fetchStageUnc0 <= EMPTY_STAGE;

            fetchStageUnc1 <= setWords(fetchStageUnc0, cacheOut);
            fetchStageUnc2 <= fetchStageUnc1;
            fetchStageUnc3 <= fetchStageUnc2;
            fetchStageUnc4 <= fetchStageUnc3;
    endtask


    task automatic fetchAndEnqueue();
        if (frontRed)
            redirectF2();
        else
            fetchNormal();

        performF2();

        if (anyActiveFetch(fetchStage2)) fetchQueue.push_back(fetchStage2);

        stageRename0 <= readFromFQ();
    endtask


    task automatic performF2();
        FetchStage f1var = fetchStageSelected1;

        if (frontRed) begin
            fetchStage2 <= EMPTY_STAGE;
            return;
        end

        fetchStage2 <= getStageF2(f1var, expectedTargetF2);

        if (anyActiveFetch(f1var)) begin
            expectedTargetF2 <= getNextTargetF2(f1var, expectedTargetF2);
        end
    endtask


    task automatic redirectFront();
        Mword target;

        flushFrontend();

        if (lateEventInfo.redirect)         target = lateEventInfo.target;
        else if (branchEventInfo.redirect)  target = branchEventInfo.target;
        else $fatal(2, "Should never get here");

        stage_IP <= makeStage_IP(target, !FETCH_UNC, FETCH_SINGLE);
        stageUnc_IP <= makeStage_IP(target, FETCH_UNC, 1);

        incFetchCounter();   
        
        expectedTargetF2 <= target;
    endtask


    task automatic flushFrontendBeforeF2();
        markKilledFrontStage(stage_IP.arr);
            markKilledFrontStage(stageUnc_IP.arr);
        markKilledFrontStage(fetchStage0);
        markKilledFrontStage(fetchStage1);
          markKilledFrontStage(fetchStageUnc0);
          markKilledFrontStage(fetchStageUnc1);
          markKilledFrontStage(fetchStageUnc2);
          markKilledFrontStage(fetchStageUnc3);
          markKilledFrontStage(fetchStageUnc4);
       // ipStage <= EMPTY_STAGE;
            stage_IP <= DEFAULT_FRONT_STAGE;
            stageUnc_IP <= DEFAULT_FRONT_STAGE;
            
          fetchStageUnc0 <= EMPTY_STAGE;
          fetchStageUnc1 <= EMPTY_STAGE;
          fetchStageUnc2 <= EMPTY_STAGE;
          fetchStageUnc3 <= EMPTY_STAGE;
          fetchStageUnc4 <= EMPTY_STAGE;
            
            
        fetchStage0 <= EMPTY_STAGE;
        fetchStage1 <= EMPTY_STAGE;
    endtask    

    task automatic flushFrontendFromF2();
        markKilledFrontStage(fetchStage2);
        markKilledFrontStage(stageRename0);

        fetchStage2 <= EMPTY_STAGE;
        expectedTargetF2 <= 'x;

        foreach (fetchQueue[i])
            markKilledFrontStage(fetchQueue[i]);

        fetchQueue.delete();

        stageRename0 <= '{default: EMPTY_SLOT_F};
    endtask


    task automatic flushFrontend();
        flushFrontendBeforeF2();
        flushFrontendFromF2();   
    endtask


    function automatic OpSlotAF readFromFQ();
        // fqSize is written in prev cycle, so new items must wait at least a cycle in FQ
        if (fqSize > 0 && AbstractCore.renameAllow)
            return fetchQueue.pop_front();
        else
            return '{default: EMPTY_SLOT_F};
    endfunction


    function automatic FetchStage clearBeforeStart(input FetchStage st, input Mword expectedTarget);
        FetchStage res = st;

        foreach (res[i])
            res[i].active = !$isunknown(res[i].adr) && (res[i].adr >= expectedTarget);
        
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
        
        Mword nextAdr = res[$size(st)-1].adr + 4;
        int branchSlot = -1;
        
        Mword takenTargets[$size(st)] = '{default: 'x};
        logic active[$size(st)] = '{default: 'x};
        logic constantBranches[$size(st)] = '{default: 'x};
        logic predictedBranches[$size(st)] = '{default: 'x};
        
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


    function automatic FetchStage TMP_getStageF2(input FetchStage st, input Mword expectedTarget);
        FetchStage res = st;

        if (!anyActiveFetch(st)) return res;
        
        assert (!$isunknown(expectedTarget)) else $fatal(2, "expectedTarget not set");
        
        res = clearBeforeStart(res, expectedTarget);        

        return res;
    endfunction
    

    function automatic Mword TMP_getNextTarget(inout FetchStage st, input Mword expectedTarget);
        FetchStage res = TMP_getStageF2(st, expectedTarget);
        
        Mword adr = res[$size(st)-1].adr + 4;
        
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


    function automatic FetchStage getStageF2(input FetchStage st, input Mword expectedTarget);
        FetchStage res = TMP_getStageF2(st, expectedTarget);
 
        int brSlot = scanBranches(res);
        
        res = clearAfterBranch(res, brSlot);
        
        // Set prediction info
        if (brSlot != -1) begin
            res[brSlot].takenBranch = 1;
        end
        
        return res;
    endfunction
    
    
    function automatic Mword getNextTargetF2(input FetchStage st, input Mword expectedTarget);
        // If no taken branches, increment base adr. Otherwise get taken target
        return TMP_getNextTarget(st, expectedTarget);
    endfunction


    function automatic logic anyActiveFetch(input FetchStage s);
        foreach (s[i]) if (s[i].active) return 1;
        return 0;
    endfunction
    
    // FUTURE: split along with split between FETCH_WIDTH and RENAME_WIDTH
    task automatic markKilledFrontStage(ref FetchStage stage);
        foreach (stage[i])
            if (stage[i].active) putMilestoneF(stage[i].id, InstructionMap::FlushFront);
    endtask


    function automatic FetchStage setWords(input FetchStage s, input InstructionCacheOutput cacheOut);
        FetchStage res = s;
        foreach (res[i]) begin
            Word realBits = cacheOut.words[i];

            if (res[i].active) begin
                Word bits = AbstractCore.programMem.fetch(res[i].adr);
                assert (realBits === bits) else $fatal(2, "Bits fetched at %d not same: %p, %p", res[i].adr, realBits, bits);
            end
            
            res[i].bits = realBits;
        end
        return res;
    endfunction



    function automatic FrontStage makeStage_IP(input Mword target, input logic on, input logic SINGLE);
        FrontStage res = DEFAULT_FRONT_STAGE;
        Mword baseAdr = fetchLineBase(target);
        logic already = 0;
        
        res.active = on;
        res.adr = target;
        
        for (int i = 0; i < $size(res.arr); i++) begin
            Mword adr = baseAdr + 4*i;
            logic elemActive = !$isunknown(target) && (adr >= target) && !already;
            
            if (SINGLE && elemActive) already = 1; 
            
            res.arr[i] = '{elemActive, -1, adr, 'x, 0, 'x};
        end
        
        return res;
    endfunction

endmodule
