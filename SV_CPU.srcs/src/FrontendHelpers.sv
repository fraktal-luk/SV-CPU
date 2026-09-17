
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


    function automatic FrontStage makeStage_IP(input Mword target, input logic on);
        FrontStage res = DEFAULT_FRONT_STAGE;
        Mword baseAdr = fetchLineBase(target);
        logic already = 0;
        Mword targetFloor = target;
        targetFloor[1:0] = 0;

        res.active = on;
        res.status = CR_HIT;
        res.vadr = target;

        foreach (res.arr[i]) begin
            Mword adr = baseAdr + 4*i;
            logic elemActive = !$isunknown(target) && (adr >= targetFloor) && !already;  
            res.arr[i] = '{elemActive, -1, adr, 'x, 0, 0, 0, 'x};
        end
        
        return res;
    endfunction



    function automatic FrontStage getFrontStageF2(input FrontStage fs, input Mword expectedTarget);
        FrontStage res = fs;

        logic predictions[FETCH_WIDTH] = '{default: 0}; // TODO: should be provided by BP

        logic branches[FETCH_WIDTH] = '{default: 0};
        logic unconditional[FETCH_WIDTH] = '{default: 0};
        logic predictedTaken[FETCH_WIDTH] = '{default: 0};

        OpSlotAF arrayF2 = clearBeforeStart(fs.arr, expectedTarget);

        if (!fs.active) return DEFAULT_FRONT_STAGE;

        foreach (fs.arr[i]) begin
            AbstractInstruction ins = decodeAbstract(fs.arr[i].bits);
            branches[i] = isBranchIns(ins);
            unconditional[i] = isBranchAlwaysIns(ins);
            predictedTaken[i] = arrayF2[i].active && ((branches[i] && predictions[i]) || unconditional[i]);
        end

        begin
            int firstTaken[$] = predictedTaken.find_first_index with (item === 1);

            if (firstTaken.size() != 0) begin
                arrayF2 = clearAfterBranch(arrayF2, firstTaken[0]);
                arrayF2[firstTaken[0]].takenBranch = 1;
            end
        end

        res.padr = 'x;
        res.arr = arrayF2;

        return res;
    endfunction


    function automatic Mword TMP_trgFromArr(input FrontStage fs);
        Mword target = fetchLineBase(fs.vadr) + 4*FETCH_WIDTH;
        
        foreach (fs.arr[i]) begin
            if (fs.arr[i].takenBranch) begin
                AbstractInstruction ins = decodeAbstract(fs.arr[i].bits);
                target = fs.arr[i].adr + Mword'(ins.sources[1]);
                break;
            end
        end

        return target;
    endfunction


    function automatic Mbyte TMP_predictionFromArr(input FrontStage fs);
        logic anyBranch = 0;

        foreach (fs.arr[i]) begin
            if (fs.arr[i].branch) anyBranch = 1;
            if (fs.arr[i].takenBranch) return TMP_bpEncode(i);
        end

        return anyBranch ? 0 : 'z;
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
