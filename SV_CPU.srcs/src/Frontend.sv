
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


    int fqSize = 0;

    FetchStage ipStage = EMPTY_STAGE, fetchStage0 = EMPTY_STAGE, fetchStage1 = EMPTY_STAGE, fetchStage2 = EMPTY_STAGE;
    Mword expectedTargetF2 = 'x;
    FetchStage fetchQueue[$:FETCH_QUEUE_SIZE];

    int fetchCtr = 0;
    OpSlotAF stageRename0 = '{default: EMPTY_SLOT_F};


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


    task automatic fetchAndEnqueue();
        if (AbstractCore.fetchAllow) begin
            Mword baseTrg = fetchLineBase(ipStage[0].adr);
            Mword target = baseTrg + 4*FETCH_WIDTH;

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

        fetchStage2 <= getStageF2(fetchStage1, expectedTargetF2);
        if (anyActiveFetch(fetchStage1)) expectedTargetF2 <= getNextTargetF2(fetchStage1);

        if (anyActiveFetch(fetchStage2)) fetchQueue.push_back(fetchStage2);

        stageRename0 <= readFromFQ();
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
    endtask

    task automatic flushFrontend();
        markKilledFrontStage(ipStage);
        markKilledFrontStage(fetchStage0);
        markKilledFrontStage(fetchStage1);
        markKilledFrontStage(fetchStage2);
        markKilledFrontStage(stageRename0);
       
        ipStage <= EMPTY_STAGE;
        fetchStage0 <= EMPTY_STAGE;
        fetchStage1 <= EMPTY_STAGE;
        fetchStage2 <= EMPTY_STAGE;
        expectedTargetF2 <= 'x;

        foreach (fetchQueue[i])
            markKilledFrontStage(fetchQueue[i]);

        fetchQueue.delete();
        
        stageRename0 <= '{default: EMPTY_SLOT_F};
    endtask


    function automatic OpSlotAF readFromFQ();
        // fqSize is written in prev cycle, so new items must wait at least a cycle in FQ
        if (fqSize > 0 && AbstractCore.renameAllow)
            return fetchQueue.pop_front();
        else
            return '{default: EMPTY_SLOT_F};
    endfunction


    function automatic FetchStage getStageF2(input FetchStage st, input Mword expectedTarget);
        FetchStage res = st;
        
        foreach (res[i])
            res[i].active = !$isunknown(res[i].adr) && (res[i].adr >= expectedTarget);
        
        // Decode branches and decide if taken. Clear tail after taken branch
        // ...
        
        return res;
    endfunction
    
    function automatic Mword getNextTargetF2(input FetchStage st);
        // If no taken branches, increment base adr. Otherwise get taken target
        return st[0].adr + 4*FETCH_WIDTH;
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
        foreach (res[i])
            res[i].bits = fg[i];
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
            res[i] = '{active, -1, adr, 'x};
        end
        
        return res;
    endfunction

endmodule
