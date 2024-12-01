
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
    FetchStage fetchQueue[$:FETCH_QUEUE_SIZE];

    int fetchCtr = 0;
    OpSlotAF stageRename0 = '{default: EMPTY_SLOT_F};



    always @(posedge AbstractCore.clk) begin
        if (lateEventInfo.redirect || branchEventInfo.redirect)
            redirectFront();
        else
            fetchAndEnqueue();
            
        fqSize <= fetchQueue.size();
    end



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
        if (AbstractCore.fetchAllow) begin
            Mword target = (ipStage[0].adr & ~(4*FETCH_WIDTH-1)) + 4*FETCH_WIDTH;
            ipStage <= '{0: '{1, -1, -1, target, 'x}, default: EMPTY_SLOT_F};

            registerNewTarget(fetchCtr + FETCH_WIDTH, target);

            fetchCtr <= fetchCtr + FETCH_WIDTH;
        end

        fetchStage0 <= setActive(ipStage, ipStage[0].active & AbstractCore.fetchAllow, fetchCtr);
        fetchStage1 <= setWords(fetchStage0, AbstractCore.instructionCacheOut);
        fetchStage2 <= fetchStage1;

        if (anyActiveFetch(fetchStage2)) fetchQueue.push_back(fetchStage2);

        stageRename0 <= readFromFQ();
    endtask


    task automatic flushFrontend();
        markKilledFrontStage(fetchStage0);
        markKilledFrontStage(fetchStage1);
        markKilledFrontStage(fetchStage2);
        fetchStage0 <= EMPTY_STAGE;
        fetchStage1 <= EMPTY_STAGE;
        fetchStage2 <= EMPTY_STAGE;

        foreach (fetchQueue[i])
            markKilledFrontStage(fetchQueue[i]);

        fetchQueue.delete();
    endtask


    function automatic OpSlotAF readFromFQ();
        OpSlotAF res = '{default: EMPTY_SLOT_F};

        // fqSize is written in prev cycle, so new items must wait at least a cycle in FQ
        if (fqSize > 0 && AbstractCore.renameAllow)
            return fetchQueue.pop_front();

        return res;
    endfunction



    function automatic logic anyActiveFetch(input FetchStage s);
        foreach (s[i])
            if (s[i].active) return 1;
        return 0;
    endfunction
    
    // FUTURE: split along with split between FETCH_WIDTH and RENAME_WIDTH
    task automatic markKilledFrontStage(ref FetchStage stage);
        foreach (stage[i])
            if (stage[i].active) putMilestoneF(stage[i].id, InstructionMap::FlushFront);
    endtask


    task automatic registerNewTarget(input int fCtr, input Mword target);
        int slotPosition = (target/4) % FETCH_WIDTH;
        for (int i = slotPosition; i < FETCH_WIDTH; i++)
            putMilestoneF(fCtr + i, InstructionMap::GenAddress);
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


endmodule
