
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;
import Queues::*;



module ExecBlock(ref InstructionMap insMap,
                input EventInfo branchEventInfo,
                input EventInfo lateEventInfo
);

    UopPacket doneRegular0_E, doneRegular1_E;
    UopPacket doneMultiplier0_E, doneMultiplier1_E;
    UopPacket doneBranch_E, doneDivider_E;
    UopPacket doneMem0_E, doneMem2_E;
    UopPacket doneFloat0_E, doneFloat1_E, doneFloatDiv_E;
    UopPacket doneStoreData_E;

    UopPacket storeDataE0, storeDataE0_E;

    logic memIssueAllow;
    
    UopMemPacket issuedReplayQueue;

    UopMemPacket toLqE0[N_MEM_PORTS];
    UopMemPacket toLqE1[N_MEM_PORTS];
    UopMemPacket toLqE2[N_MEM_PORTS];

    AccessDesc accessDescs_E0[N_MEM_PORTS];
    AccessDesc accessDescs_E2[N_MEM_PORTS];

    Translation dcacheTranslations_EE0[N_MEM_PORTS]; // source: DataL1
    Translation dcacheTranslations_E1[N_MEM_PORTS];
    Translation dcacheTranslations_E2[N_MEM_PORTS];

    Translation trsReplayQueue[N_MEM_PORTS];
    AccessDesc adsReplayQueue[N_MEM_PORTS];

    DataCacheOutput dcacheOuts_E1[N_MEM_PORTS];
    DataCacheOutput uncachedOuts_E1[N_MEM_PORTS];
    DataCacheOutput sysOuts_E1[N_MEM_PORTS];
    
    UopMemPacket sqResponse_E1[N_MEM_PORTS];

    UopMemPacket toBq[N_MEM_PORTS]; // FUTURE: Customize this width in MemBuffer (or make whole new module for BQ)?  

    ForwardingElement intImages[N_INT_PORTS][-3:1];
    ForwardingElement memImages[N_MEM_PORTS][-3:1];
    ForwardingElement floatImages[N_VEC_PORTS][-3:1];

    IntByStage intImagesTr;
    MemByStage memImagesTr;
    VecByStage floatImagesTr;

    ForwardsByStage_0 allByStage;
    

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
        accessDescs_E0[0],
        dcacheTranslations_EE0[0],
        dcacheOuts_E1[0],
        uncachedOuts_E1[0],
        sysOuts_E1[0],
        sqResponse_E1[0]
    );

    // Mem 2 - for ReplayQueue only!
    MemSubpipe#()
    mem2(
        insMap,
        branchEventInfo,
        lateEventInfo,
        issuedReplayQueue,
        accessDescs_E0[2],
        dcacheTranslations_EE0[2],
        dcacheOuts_E1[2],
        uncachedOuts_E1[2],
        sysOuts_E1[2],
        sqResponse_E1[2]
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
        memImagesTr[-3],
        memImagesTr[0],
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
    assign doneMem2_E = TMP_mp(memToComplete(mem2.stage0_E));
    assign doneFloat0_E = float0.stage0_E;
    assign doneFloat1_E = float1.stage0_E;
    assign doneFloatDiv_E = fdiv.stage0_E;
    assign doneStoreData_E = storeData0.stage0_E;

    assign storeDataE0_E = storeData0.stage0_E;

    assign accessDescs_E2 = '{0: mem0.accessDescE2, 1: DEFAULT_ACCESS_DESC, 2: mem2.accessDescE2, 3: DEFAULT_ACCESS_DESC};
    assign dcacheTranslations_E1 = '{0: mem0.trE1, 1: DEFAULT_TRANSLATION, 2: mem2.trE1, 3: DEFAULT_TRANSLATION};
    assign dcacheTranslations_E2 = '{0: mem0.trE2, 1: DEFAULT_TRANSLATION, 2: mem2.trE2, 3: DEFAULT_TRANSLATION};
    
    assign trsReplayQueue = '{0: mem0.tr0, 2: mem2.tr0, default: DEFAULT_TRANSLATION};
    assign adsReplayQueue = '{0: mem0.ad0, 2: mem2.ad0, default: DEFAULT_ACCESS_DESC};

    assign toLqE0 = '{0: mem0.pE0_E, 2: mem2.pE0_E, default: EMPTY_UOP_PACKET};
    assign toLqE1 = '{0: mem0.pE1_E, 2: mem2.pE1_E, default: EMPTY_UOP_PACKET};
    assign toLqE2 = '{0: mem0.pE2_E, 2: mem2.pE2_E, default: EMPTY_UOP_PACKET};


    assign toBq = '{0: branch0.pE0_E, default: EMPTY_UOP_PACKET};


    assign intImages = '{0: regular0.image_E, 1: regular1.image_E, 2: branch0.image_E, 3: divider.image_E, 4: multiplier0.image_E, 5: multiplier1.image_E, default: EMPTY_IMAGE};
    assign memImages = '{0: mem0.image_E, 2: mem2.image_E, default: EMPTY_IMAGE};
    assign floatImages = '{0: float0.image_E, 1: float1.image_E, 2: fdiv.image_E, default: EMPTY_IMAGE};

    always_comb intImagesTr = trsInt(intImages);
    always_comb memImagesTr = trsMem(memImages);
    always_comb floatImagesTr = trsVec(floatImages);

    assign allByStage.ints = intImagesTr;
    assign allByStage.mems = memImagesTr;
    assign allByStage.vecs = floatImagesTr;



    function automatic UopPacket performRegularE0(input UopPacket p);
        if (p.TMP_oid == UIDT_NONE) return p;
        begin
            UopPacket res = p;
            res.result = calcRegularOp(p.TMP_oid);
            return res;
        end
    endfunction
    

    function automatic Mword calcRegularOp(input UidT uid);
        Mword3 args = getAndVerifyArgs(uid);
        Mword lk = getAdr(U2M(uid)) + 4;
        Mword result = calcArith(decUname(uid), args, lk);  
        insMap.setActualResult(uid, result);
        
        return result;
    endfunction


        // FUTURE: Introduce forwarding of FP args
        // FUTURE: 1c longer load pipe on FP side? 
    // Used before Exec0 to get final values
    function automatic Mword3 getAndVerifyArgs(input UidT uid);
        InsDependencies deps = insMap.getU(uid).deps;
        Mword3 argsP = getArgValues(AbstractCore.registerTracker, deps);
        insMap.setActualArgs(uid, argsP);
        return argsP;
    endfunction;


    // Used once
    function automatic Mword3 getArgValues(input RegisterTracker tracker, input InsDependencies deps);
        Mword res[3];
        logic3 ready = checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);
                    
        foreach (deps.types[i]) begin
            case (deps.types[i])
                SRC_ZERO:  res[i] = 0;
                SRC_CONST: res[i] = deps.sources[i];
                SRC_INT:   res[i] = getArgValueInt(insMap, tracker, deps.producers[i], deps.sources[i], allByStage, ready[i]);
                SRC_FLOAT: res[i] = getArgValueVec(insMap, tracker, deps.producers[i], deps.sources[i], allByStage, ready[i]);
            endcase
        end

        return res;
    endfunction


endmodule
