
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;
import Queues::*;

import Arith::*;
import Arith64::*;

import ExecLogic::*;


module ExecBlock(ref InstructionMap insMap,
                 input EventInfo branchEventInfo,
                 input EventInfo lateEventInfo
);

    UopPacket doneRegular0_E, doneRegular1_E;
    UopPacket doneMultiplier0_E, doneMultiplier1_E;
    UopPacket doneBranch_E, doneDivider_E;
    UopPacket doneMem0_E, doneMem1_E, doneMem2_E;
    UopPacket doneFloat0_E, doneFloat1_E, doneFloatDiv_E;
    UopPacket doneStoreData_E;

    UopPacket storeDataE0, storeDataE0_E;

    UopMemPacket issuedReplayQueue;

    logic memIssueAllow;

    Translation dcacheTranslationsE0d[N_MEM_PORTS]; // source: DataL1

    DataCacheOutput dcacheOuts_E1[N_MEM_PORTS];
    DataCacheOutput uncachedOuts_E1[N_MEM_PORTS];
    DataCacheOutput sysOuts_E1[N_MEM_PORTS];

    UopMemPacket toBq[N_MEM_PORTS]; // FUTURE: Customize this width in MemBuffer (or make whole new module for BQ)?  
    
        logic ch0, ch1, ch2, ch3;


    // Int 0
    RegularSubpipe regular0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedRegularP[0]
    );
    
    // Int 1
    RegularSubpipe regular1(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedRegularP[1]
    );
    
    // Int 2
    BranchSubpipe branch0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedBranchP[0]
    );

    // Int 3
    DividerSubpipe divider(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedDividerP[0]
    );

    // Int 4
    MultiplierSubpipe multiplier0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedMultiplierP[0]
    );
    
    // Int 5
    MultiplierSubpipe multiplier1(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedMultiplierP[1]
    );


    // Mem 0
    MemSubpipe#()
    mem0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedMemP[0],
        dcacheTranslationsE0d[0],
        mn.cacheOutE1d[0],
        mn.uncachedOutE1d[0],
        mn.sysOutE1d[0],
        mn.sqOutE1d[0],
        mn.lqOutE1d[0]
    );

    MemSubpipe#()
    mem1(
        insMap,
        branchEventInfo,
        lateEventInfo,
            theIssueQueues.issuedMemP[1],
        dcacheTranslationsE0d[1],
        mn.cacheOutE1d[1],
        mn.uncachedOutE1d[1],
        mn.sysOutE1d[1],
        mn.sqOutE1d[1],
        mn.lqOutE1d[1]
    );

    // Mem 2 - for ReplayQueue only!
    MemSubpipe#()
    mem2(
        insMap,
        branchEventInfo,
        lateEventInfo,
        issuedReplayQueue,
        dcacheTranslationsE0d[2],
        mn.cacheOutE1d[2],
        mn.uncachedOutE1d[2],
        mn.sysOutE1d[2],
        mn.sqOutE1d[2],
        mn.lqOutE1d[2]
    );


    // Vec 0
    FloatSubpipe float0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedFloatP[0]
    );
    
    // Vec 1
    FloatSubpipe float1(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedFloatP[1]
    );

    DividerSubpipe#(.IS_FP(1)) fdiv(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedFdivP[0]
    );

    StoreDataSubpipe storeData0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedStoreDataP[0]
    );

    ReplayQueue replayQueue(
        insMap,
        AbstractCore.clk,
        branchEventInfo,
        lateEventInfo,
        rn.memImagesTr[-3], // TODO: this must include FP/vector too
        rn.memImagesTr[0],
        issuedReplayQueue
    );
    
    assign memIssueAllow = replayQueue.accept;

    assign doneRegular0_E = regular0.stage0_E;
    assign doneRegular1_E = regular1.stage0_E;
    assign doneMultiplier0_E = multiplier0.stage0_E;
    assign doneMultiplier1_E = multiplier1.stage0_E;

    assign doneBranch_E = branch0.stage0_E;
    assign doneDivider_E = divider.stage0_E;
        assign doneMem0_E = TMP_mp(memToComplete(mem0.stage0_E));
        assign doneMem1_E = TMP_mp(memToComplete(mem1.stage0_E));
        assign doneMem2_E = TMP_mp(memToComplete(mem2.stage0_E));
    assign doneFloat0_E = float0.stage0_E;
    assign doneFloat1_E = float1.stage0_E;
    assign doneFloatDiv_E = fdiv.stage0_E;
    assign doneStoreData_E = storeData0.stage0_E;

    assign storeDataE0_E = storeData0.stage0_E;

    assign toBq = '{0: branch0.pE0_E, default: EMPTY_UOP_PACKET};



    function automatic UopPacket performRegularE0(input UopPacket p);
        if (p.uid == UID_NONE) return p;
        begin
            UopPacket res = p;
            res.result = calcRegularOp(p.uid);
            return res;
        end
    endfunction


    function automatic Mword calcRegularOp(input UopId uid);
        Mword3 args = rn.getAndVerifyArgs(uid);
        Mword lk = getAdr(U2M(uid)) + 4;
        Mword result = calcArith(decUname(uid), args, lk);  
        insMap.setActualResult(uid, result);
        
        return result;
    endfunction


    function automatic FpResult64 calcRegularFpOp(input UopId uid);
        Rounding rm = convertRM(AbstractCore.CurrentConfig.rm);
        Mword3 args = rn.getAndVerifyArgs(uid);
        FpResult64 result;  

        result = calcArithFp(decUname(uid), args, rm);  
        insMap.setActualResult(uid, result.value);

        return result;
    endfunction


    function automatic UopPacket performFP(input UopPacket p);        
        UopPacket res = p;
        FpResult64 fpRes;

        if (p.uid == UID_NONE) return res;
        
        begin
            fpRes = calcRegularFpOp(p.uid);
            res.result = fpRes.value;

            if (fpRes.exc.invalid) begin
                res.status = ES_FP_INVALID;
            end
            
            if (fpRes.exc.div0) begin
                res.status = ES_FP_DIV0;
            end

            if (fpRes.exc.overflow) begin
                res.status = ES_FP_OVERFLOW;
            end

            if (fpRes.exc.underflow) begin
                res.status = ES_FP_UNDERFLOW;
            end

            if (fpRes.exc.inexact) begin
                if (fpRes.exc.overflow)
                    res.status = ES_FP_OV_INEXACT;
                else if (fpRes.exc.underflow)
                    res.status = ES_FP_UND_INEXACT;
                else
                    res.status = ES_FP_INEXACT;
            end
        end

        if (
            fpRes.exc.invalid && AbstractCore.CurrentConfig.enTrapInv
         || fpRes.exc.overflow && AbstractCore.CurrentConfig.enTrapOv
         || fpRes.exc.inexact && AbstractCore.CurrentConfig.enTrapInex
         || fpRes.exc.underflow && AbstractCore.CurrentConfig.enTrapUnd
         || fpRes.exc.div0 && AbstractCore.CurrentConfig.enTrapDiv0         
            )
        begin
            insMap.setException(U2M(p.uid), PE_ARITH_EXCEPTION);
        end
        
        return res;
    endfunction

endmodule
