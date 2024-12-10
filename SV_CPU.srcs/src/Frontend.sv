
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;


module Frontend(ref InstructionMap insMap, input EventInfo branchEventInfo, input EventInfo lateEventInfo);

    typedef Word FetchGroup[FETCH_WIDTH];
    typedef OpSlotF FetchStage[FETCH_WIDTH];
    localparam FetchStage EMPTY_STAGE = '{default: EMPTY_SLOT_F};


    localparam logic ENABLE_FRONT_BRANCHES = 1;


    int fqSize = 0;

    FetchStage ipStage = EMPTY_STAGE, fetchStage0 = EMPTY_STAGE, fetchStage1 = EMPTY_STAGE, fetchStage2 = EMPTY_STAGE, fetchStage2_A = EMPTY_STAGE;
    Mword expectedTargetF2 = 'x, expectedTargetF2_A = 'x;
    FetchStage fetchQueue[$:FETCH_QUEUE_SIZE];

    int fetchCtr = 0;
    OpSlotAF stageRename0 = '{default: EMPTY_SLOT_F};

    logic frontRed;


    assign frontRed = anyActiveFetch(fetchStage1) && (fetchLineBase(fetchStage1[0].adr) !== fetchLineBase(expectedTargetF2));


    task automatic TMP_cmp();
        foreach (fetchStage0[i]) begin
        //   assert (fetchStage0_A[i].active === fetchStage0[i].active) else $error("not eqq\n%p\n%p", fetchStage0, fetchStage0_A);
        //   assert (!fetchStage0_A[i].active || fetchStage0_A[i] === fetchStage0[i]) else $error("not eq\n%p\n%p", fetchStage0_A[i], fetchStage0[i]);
        end
    endtask


    always @(posedge AbstractCore.clk) begin
                TMP_cmp();


        if (lateEventInfo.redirect || branchEventInfo.redirect)
            redirectFront();
        else
            fetchAndEnqueue();

        fqSize <= fetchQueue.size();
    end

    task automatic redirectF2();
        flushFrontendBeforeF2();
 
        ipStage <= makeIpStage(expectedTargetF2);

        fetchCtr <= fetchCtr + FETCH_WIDTH;   
    endtask

    task automatic fetchNormal();
        if (AbstractCore.fetchAllow) begin
            Mword baseTrg = fetchLineBase(ipStage[0].adr);
            Mword target = baseTrg + 4*FETCH_WIDTH; // TODO: next line predictor

            ipStage <= makeIpStage(target);

            fetchCtr <= fetchCtr + FETCH_WIDTH;
        end

        if (anyActiveFetch(ipStage) && AbstractCore.fetchAllow) begin
            fetchStage0 <= ipStage;
        end
        else begin
            fetchStage0 <= EMPTY_STAGE;
        end

        fetchStage1 <= setWords(fetchStage0, AbstractCore.instructionCacheOut);
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
        FetchStage f1var = fetchStage1;

        if (frontRed) begin
            fetchStage2 <= EMPTY_STAGE;
            fetchStage2_A <= EMPTY_STAGE;
            return;
        end

        fetchStage2 <= getStageF2(f1var, expectedTargetF2);
        fetchStage2_A <= getStageF2(f1var, expectedTargetF2_A);

        if (anyActiveFetch(f1var)) begin
            expectedTargetF2 <= getNextTargetF2(f1var, expectedTargetF2);
            expectedTargetF2_A <= TMP_getNextTarget(f1var, expectedTargetF2);
        end
    endtask


    task automatic redirectFront();
        Mword target;

        flushFrontend();

        if (lateEventInfo.redirect)         target = lateEventInfo.target;
        else if (branchEventInfo.redirect)  target = branchEventInfo.target;
        else $fatal(2, "Should never get here");

        ipStage <= makeIpStage(target);

        fetchCtr <= fetchCtr + FETCH_WIDTH;
        
        expectedTargetF2 <= target;
        expectedTargetF2_A <= target;
    endtask


    task automatic flushFrontendBeforeF2();
        markKilledFrontStage(ipStage);
        markKilledFrontStage(fetchStage0);
        markKilledFrontStage(fetchStage1);

        ipStage <= EMPTY_STAGE;
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
        
        
        if ($time() <= 300) begin
           // $display("adr %d: tr = %p, a = %p, br = %p // %d, [%d] --> %d", res[0].adr, takenTargets, active, constantBranches, -1, lastSlot, nextAdr);
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


    function automatic FetchStage setWords(input FetchStage s, input FetchGroup fg);
        FetchStage res = s;
        foreach (res[i]) begin
            if (res[i].active) begin
                Word bits = fetchInstruction(AbstractCore.dbProgMem, res[i].adr); // DB
                assert (fg[i] === bits) else $fatal(2, "Bits fetched at %d not same: %p, %p", res[i].adr, fg[i], bits);
            end
            
            res[i].bits = fg[i];
        end
        return res;
    endfunction


    function automatic Mword fetchLineBase(input Mword adr);
        return adr & ~(4*FETCH_WIDTH-1);
    endfunction;

    function automatic FetchStage makeIpStage(input Mword target);
        FetchStage res = EMPTY_STAGE;
        Mword baseAdr = fetchLineBase(target);
        Mword adr;
        logic active;
        
        for (int i = 0; i < $size(res); i++) begin
            adr = baseAdr + 4*i;
            active = !$isunknown(target) && (adr >= target);
            res[i] = '{active, -1, adr, 'x, 0, 'x};
        end
        
        return res;
    endfunction

endmodule
