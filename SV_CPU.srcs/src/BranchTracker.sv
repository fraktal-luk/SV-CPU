
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;
import Queues::*;


module BranchTracker;

    BranchGroup histFull[16];

    int lastCount = -1;
    int lastLen = -1;

    int newCount = -1;
    int newLen = -1; // 

    Mword p0i = -1, p0, p1, p2;
    Mword a0i, a0, a1, a2;

        logic ch0, ch1, ch2, ch3, ch4; 

        TMP_PredState predStateF0 = DEFAULT_PRED_STATE, // Generated from IP stage
                      predStateF2 = DEFAULT_PRED_STATE; // Generated from F1 stage


    TMP_PredState committedPredState = DEFAULT_PRED_STATE;
    TMP_PredState committedPredStatePrev = DEFAULT_PRED_STATE;
    logic latestPredPresent = 0;



    function automatic void update(input BqEntry entry);
        BranchGroup allZ = '{default: 'z};

        lastCount = entry.histCount;
        lastLen = entry.histLen;


        if (entry.histLen + 1 > newLen) begin // Open new group
            histFull = {allZ, histFull[0:14]};
        end

        histFull[0][entry.slot] = entry.taken;

        newCount = entry.histCount + 1;
        newLen = entry.histLen + 1;

    endfunction


    function automatic Mbyte getSimplePredictionSig();
        return 'z;
    endfunction

    function automatic Mword getSimplePredictionTarget();
        return 'x;
    endfunction


    function automatic Mbyte getAdvancedPredictionSig();
        return 0;
    endfunction

    function automatic Mword getAdvancedPredictionTarget();
        return 'x;
    endfunction



    function automatic void startPrediction(/*input int count, input int len, */input Mword adr);
        a0i <= adr;
        p0i <= predStateF0.len;
    endfunction

    function automatic void move();
        p0 <= p0i;
        p1 <= p0;
        p2 <= p1;

        a0 <= a0i;
        a1 <= a0;
        a2 <= a1;
    endfunction




    task automatic updateBpState(input InstructionInfo insInfo);

        // Start new block for predictor
        if (AbstractCore.CurrentConfig.enableMmu) begin
            if (insInfo.firstInGroup) begin
                latestPredPresent = 0;
                committedPredStatePrev = committedPredState;
                committedPredState = updatePredCommit(committedPredState, '{default: 'z}, insInfo.basicData.adr); // don't inc len
            end
        end

        if (isBranchUop(decMainUop(insInfo.id))) begin // Br queue entry release
            BranchCheckpoint bce = checkpointUnit.frontElem();
            checkpointUnit.pop();

            assert (bce.id === insInfo.id) else $error("Not matching op: %p / %p", bce, insInfo.id);
            assert (
                    bce.predState.count === committedPredStatePrev.count
                &&  bce.predState.len === committedPredStatePrev.len
                &&  bce.predState.histCoded === committedPredStatePrev.histCoded
                &&  bce.predState.recentCoded === committedPredStatePrev.recentCoded
                    )
                else $error("Diffr, op %d\n%d: %s\nprev pred state:\n%p\n%p",
                            insInfo.id, insInfo.basicData.adr, disasm(insInfo.basicData.bits), bce.predState, committedPredStatePrev);

            if (AbstractCore.CurrentConfig.enableMmu) begin
                BranchGroup bg = updateBranchGroup(bce.ownPred, bce.slotInd, insInfo.takenBranch);

                if (!latestPredPresent) committedPredState = replacePredFirst(committedPredState, bg);
                else                    committedPredState = replacePred(committedPredState, bg);

                latestPredPresent = 1;
            end

        end
    endtask


    function automatic void restoreOnBranch(input BranchCheckpoint causingCP, input BranchGroup bg, input Mword vadr);
        // CAREFUL: branchEventInfo.adr is not exactly the past state to be restored - may be on a different slot from the beginning
        predStateF0 <= updatePred(causingCP.predState, bg, vadr);
        predStateF2 <= updatePred(causingCP.predState, bg, vadr);  //  As well
    endfunction


    function automatic void restoreOnEvent();
        predStateF0 <= committedPredState;
        predStateF2 <= committedPredState;            
    endfunction


    function automatic void updatePredStateF0(input logic[1:0] linePred, input Mword vadr);
        predStateF0 <= updatePred(predStateF0, linePred, vadr);
    endfunction

    function automatic void updatePredStateF2(input BranchGroup newPred, input Mword vadr);
        predStateF2 <= updatePred(predStateF2, newPred, vadr);
    endfunction


    function automatic void restoreOnFrontBranch();
        predStateF0 <= predStateF2;
    endfunction







    function automatic Mbyte encodeBranchGroup(input BranchGroup bg);
        int found[$]; 

        logic arr[FETCH_WIDTH] = {>>{bg}};

        found = arr.find_index with (item === '1);
        if (found.size() > 0) begin
            if (found[0] >= 3) return 3;
            else return found[0] + 1;
        end

        found = arr.find_index with (item === '0);
        if (found.size() > 0) return 0;

        return 'z;
    endfunction


    function automatic TMP_PredState updatePred(input TMP_PredState prev, input BranchGroup lastFull, input Mword vadr);
        TMP_PredState res = prev;
        logic[1:0] last = encodeBranchGroup(lastFull);

        res.count++;
        res.pathHist = {vadr, res.pathHist[0:14]};

        res.recentCoded = {last, res.recentCoded[0]};

        if (last !== 'z) begin
            res.len++;
            res.histCoded = {last, res.histCoded[0:14]};
            res.histFull = {lastFull, res.histFull[0:14]};
        end

        return res;
    endfunction


    function automatic TMP_PredState updatePredCommit(input TMP_PredState prev, input BranchGroup lastFull, input Mword vadr);
        TMP_PredState res = prev;
        logic[1:0] last = encodeBranchGroup(lastFull);

        res.count++;
        res.pathHist = {vadr, res.pathHist[0:14]};

        res.recentCoded = {last, res.recentCoded[0]};

        return res;
    endfunction


    function automatic TMP_PredState replacePred(input TMP_PredState prev, input BranchGroup bg);
        logic[1:0] last = encodeBranchGroup(bg);
        TMP_PredState res = prev;
        res.recentCoded[0] = last;

        if (last !== 'z) begin
            res.histCoded[0] = last;
            res.histFull[0] = bg;
        end

        return res;
    endfunction


    function automatic TMP_PredState replacePredFirst(input TMP_PredState prev, input BranchGroup bg);
        logic[1:0] last = encodeBranchGroup(bg);
        TMP_PredState res = prev;
        res.recentCoded[0] = last;

        if (last !== 'z) begin
            res.len++;
            res.histCoded = {last, res.histCoded[0:14]};
            res.histFull = {bg, res.histFull[0:14]};
        end

        return res;
    endfunction


endmodule

