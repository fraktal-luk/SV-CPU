
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

    FetchStage ipStage = EMPTY_STAGE, fetchStage0 = EMPTY_STAGE, fetchStage1 = EMPTY_STAGE;
    FetchStage fetchQueue[$:FETCH_QUEUE_SIZE];

    int fetchCtr = 0;
    OpSlotAF stageRename0 = '{default: EMPTY_SLOT_F};

    function automatic logic anyActiveFetch(input FetchStage s);
        foreach (s[i]) if (s[i].active) return 1;
        return 0;
    endfunction
    
    // FUTURE: split along with split between FETCH_WIDTH and RENAME_WIDTH
    task automatic markKilledFrontStage(ref FetchStage stage);
        foreach (stage[i]) begin
            if (!stage[i].active) continue;
            putMilestoneF(stage[i].id, InstructionMap::FlushFront);
        end
    endtask


    task automatic registerNewTarget(input int fCtr, input Mword target);
        int slotPosition = (target/4) % FETCH_WIDTH;
        Mword baseAdr = target & ~(4*FETCH_WIDTH-1);
        for (int i = slotPosition; i < FETCH_WIDTH; i++) begin
            Mword adr = baseAdr + 4*i;
            InsId index = fCtr + i;
            insMap.registerIndex(index);
            putMilestoneF(index, InstructionMap::GenAddress);
        end
    endtask


    function automatic FetchStage setActive(input FetchStage s, input logic on, input int ctr);
        FetchStage res = s;
        Mword firstAdr = res[0].adr;
        Mword baseAdr = res[0].adr & ~(4*FETCH_WIDTH-1);

        if (!on) return EMPTY_STAGE;

        foreach (res[i]) begin
            res[i].active = (((firstAdr/4) % FETCH_WIDTH <= i)) === 1;
            res[i].id = res[i].active ? ctr + i : -1;
            res[i].adr = res[i].active ? baseAdr + 4*i : 'x;
        end

        return res;
    endfunction

    function automatic FetchStage setWords(input FetchStage s, input FetchGroup fg);
        FetchStage res = s;
        foreach (res[i])
            if (res[i].active) res[i].bits = fg[i];
        return res;
    endfunction


    task automatic flushFrontend();
        markKilledFrontStage(fetchStage0);
        markKilledFrontStage(fetchStage1);
        fetchStage0 <= EMPTY_STAGE;
        fetchStage1 <= EMPTY_STAGE;

        foreach (fetchQueue[i]) begin
            FetchStage current = fetchQueue[i];
            markKilledFrontStage(current);
        end
        fetchQueue.delete();
    endtask

    task automatic redirectFront();
        Mword target;

        if (lateEventInfo.redirect)         target = lateEventInfo.target;
        else if (branchEventInfo.redirect)  target = branchEventInfo.target;
        else $fatal(2, "Should never get here");

        if (ipStage[0].id != -1) markKilledFrontStage(ipStage);
        ipStage <= '{0: '{1, -1, -1, target, 'x}, default: EMPTY_SLOT_F};

        fetchCtr <= fetchCtr + FETCH_WIDTH;

        registerNewTarget(fetchCtr + FETCH_WIDTH, target);

        flushFrontend();

        markKilledFrontStage(stageRename0);
        stageRename0 <= '{default: EMPTY_SLOT_F};
    endtask

    task automatic fetchAndEnqueue();
        FetchStage fetchStage0ua, ipStageU;
        if (AbstractCore.fetchAllow) begin
            Mword target = (ipStage[0].adr & ~(4*FETCH_WIDTH-1)) + 4*FETCH_WIDTH;
            ipStage <= '{0: '{1, -1, -1, target, 'x}, default: EMPTY_SLOT_F};
            fetchCtr <= fetchCtr + FETCH_WIDTH;
            
            registerNewTarget(fetchCtr + FETCH_WIDTH, target);
        end

        ipStageU = setActive(ipStage, ipStage[0].active & AbstractCore.fetchAllow, fetchCtr);

        fetchStage0 <= ipStageU;
        fetchStage0ua = setWords(fetchStage0, AbstractCore.instructionCacheOut);
        
        foreach (ipStageU[i]) if (ipStageU[i].active) begin
            insMap.add(ipStageU[i].id, ipStageU[i].adr, ipStageU[i].bits);
        end

        foreach (fetchStage0ua[i]) if (fetchStage0ua[i].active) begin
            insMap.setEncoding(fetchStage0ua[i].id, fetchStage0ua[i].bits);
        end

        fetchStage1 <= fetchStage0ua;
        if (anyActiveFetch(fetchStage1)) fetchQueue.push_back(fetchStage1);
    
        stageRename0 <= readFromFQ();
    endtask
    
    function automatic OpSlotAF readFromFQ();
        OpSlotAF res = '{default: EMPTY_SLOT_F};

        // fqSize is written in prev cycle, so new items must wait at least a cycle in FQ
        if (fqSize > 0 && AbstractCore.renameAllow) begin
            FetchStage fqOut_N = fetchQueue.pop_front();
            foreach (fqOut_N[i]) res[i] = fqOut_N[i];
        end
        
        return res;
    endfunction

   
    always @(posedge AbstractCore.clk) begin
        if (lateEventInfo.redirect || branchEventInfo.redirect)
            redirectFront();
        else
            fetchAndEnqueue();
            
        fqSize <= fetchQueue.size();
    end

endmodule
