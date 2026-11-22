
package FrontendHelpers;
    
    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import EmulationDefs::*;
    import Emulation::*;
    import UopList::*;
    import AbstractSim::*;
    import CoreConfig::*;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Frontend
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function automatic Mword fetchLineBase(input Mword adr);
        return adr & ~(4*FETCH_WIDTH-1);
    endfunction;


    function automatic OpSlotAF clearBeforeStart(input OpSlotAF st, input Mword expectedTarget);
        OpSlotAF res = st;
        Mword expectedTargetFloor = expectedTarget;
        logic anyFound = 0;
        expectedTargetFloor[1:0] = 0;

        foreach (res[i]) begin
            logic active = res[i].active && !$isunknown(res[i].adr) && (res[i].adr >= expectedTargetFloor);
            
            res[i].active = active;
            res[i].first = active & !anyFound;

            anyFound |= active;
        end

        return res;       
    endfunction


    function automatic OpSlotAF clearAfterBranch(input OpSlotAF st, input int branchSlot);
        OpSlotAF res = st;

        if (branchSlot == -1) return res;

        foreach (res[i])
            if (i > branchSlot) res[i].active = 0;

        return res;        
    endfunction


    function automatic FrontStage makeStage_IP(input Mword target);
        FrontStage res = DEFAULT_FRONT_STAGE;
        Mword baseAdr = fetchLineBase(target);
        logic already = 0;
        Mword targetFloor = target;
        targetFloor[1:0] = 0;

        res.active = 1;
        res.status = CR_HIT;
        res.vadr = target;

        foreach (res.arr[i]) begin
            Mword adr = baseAdr + 4*i;
            logic elemActive = !$isunknown(target) && (adr >= targetFloor) && !already;  
            res.arr[i] = '{elemActive, -1, adr, 'x, 0, 0, 0, 'x};
        end
        
        return res;
    endfunction



    function automatic FrontStage advanceF2(input FrontStage stage, input BranchGroup dirPredictions, input Mword predictedRegTarget,
                                            input Mword expectedTarget, input TMP_PredState prevPredState);
        FrontStage res = stage;
        BranchGroup immBranches, regBranches, unconditionalBranches, fullPrediction = '{default: 'z};
        logic branches[FETCH_WIDTH], taken[FETCH_WIDTH];
        Mword target = 'x;
        int firstTakenIndex[$];
        OpSlotAF array = clearBeforeStart(stage.arr, expectedTarget);
        
        if (!stage.active) return DEFAULT_FRONT_STAGE;

        foreach (stage.arr[i]) begin
            AbstractInstruction ins = decodeAbstract(array[i].bits);
            immBranches[i] = array[i].active & isBranchImmIns(ins);
            regBranches[i] = array[i].active & isBranchRegIns(ins);
            unconditionalBranches[i] = array[i].active & isBranchAlwaysIns(ins);
            
            branches[i] = immBranches[i] | regBranches[i];
            taken[i] = unconditionalBranches[i] | dirPredictions[i];
        end

        firstTakenIndex = taken.find_first_index with (item === 1);

        if (firstTakenIndex.size() == 0) begin // No taken branches
            target = fetchLineBase(stage.vadr) + FETCH_WIDTH*4;
        end
        else begin
            int index = firstTakenIndex[0];
            if (immBranches[index]) begin
                target = getImmTarget(array[index]);
            end
            else if (regBranches[index]) begin
                target = predictedRegTarget; // TODO: make proper reg target prediction. For now we'll use imm target (although this will be always* incorrect)
                    target = getImmTarget(array[index]);
            end
            else $fatal(2, "First taken branch in group (%d), but it's not a branch!", index);

            array = clearAfterBranch(array, firstTakenIndex[0]);
            array[firstTakenIndex[0]].takenBranch = 1;
        end

        foreach (fullPrediction[i]) begin
            if (taken[i]) begin
                fullPrediction[i] = 1;
                break;
            end
            else if (branches[i])
                fullPrediction[i] = 0;
        end

        res.predState = prevPredState;

        res.ownPredF2 = fullPrediction;
        res.ownPredTargetF2 = target;

        res.padr = 'x;
        res.arr = array;

        return res;
    endfunction


    function automatic Mword getImmTarget(input OpSlotF slot);
        AbstractInstruction ins = decodeAbstract(slot.bits);

        assert (isBranchIns(ins)) else $fatal(2, "Not a branch");

        return slot.adr + Mword'(ins.sources[1]);
    endfunction


    function automatic FrontStage makeStageUnc_IP(input Mword target, input logic on, input Mword prevAdr, input logic guardPageCross);
        FrontStage res = DEFAULT_FRONT_STAGE;
        logic pageCross = (getPageBaseM(target) !== getPageBaseM(prevAdr));

        res.active = on && !(guardPageCross && pageCross);
        res.status = CR_HIT;
        res.vadr = target;
        res.padr = target;

        res.arr[0] = '{1, -1, target, 'x, 0, 0, 0, 'x};

        return res;
    endfunction


    function automatic FrontStage getFrontStageF2_U(input FrontStage fs, input logic ENABLE_FRONT_BRANCHES);
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

endpackage
