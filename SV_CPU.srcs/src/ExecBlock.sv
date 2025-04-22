
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
    UopPacket doneRegular0, doneRegular1;
    UopPacket doneBranch;
    UopPacket doneMem0, doneMem2;
    UopPacket doneFloat0,  doneFloat1; 
    
    UopPacket doneStoreData;

    UopPacket doneRegular0_E, doneRegular1_E;
    UopPacket doneBranch_E;
    UopPacket doneMem0_E, doneMem2_E;
    UopPacket doneFloat0_E, doneFloat1_E; 

    UopPacket doneStoreData_E;

    UopPacket storeDataE0, storeDataE0_E;


    //DataReadReq readReqs[N_MEM_PORTS];
   // DataReadReq sysReadReqs[N_MEM_PORTS];
    AccessDesc accessDescs[N_MEM_PORTS];
    Translation dcacheTranslations[N_MEM_PORTS];
    
        AccessDesc accessDescs_E2[N_MEM_PORTS];
        Translation dcacheTranslations_E2[N_MEM_PORTS];
    
    DataCacheOutput dcacheOuts[N_MEM_PORTS];
    DataCacheOutput sysOuts[N_MEM_PORTS];
    
    logic TMP_memAllow;
    
    UopMemPacket issuedReplayQueue;
    
    UopMemPacket toReplayQueue0, toReplayQueue2;
    UopMemPacket toReplayQueue[N_MEM_PORTS];

    UopMemPacket toLqE0[N_MEM_PORTS];
        UopMemPacket toLqE0_tr[N_MEM_PORTS]; // TMP. transalted
    UopMemPacket toLqE1[N_MEM_PORTS];
    UopMemPacket toLqE2[N_MEM_PORTS];
    UopMemPacket toSqE0[N_MEM_PORTS];
        UopMemPacket toSqE0_tr[N_MEM_PORTS]; // TMP. transalted
    UopMemPacket toSqE1[N_MEM_PORTS];
    UopMemPacket toSqE2[N_MEM_PORTS];
    UopMemPacket toBq[N_MEM_PORTS]; // FUTURE: Customize this width in MemBuffer (or make whole new module for BQ)?  

    UopMemPacket fromSq[N_MEM_PORTS];
    UopMemPacket fromLq[N_MEM_PORTS];
    UopMemPacket fromBq[N_MEM_PORTS];
    

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

    
    // Mem 0
    MemSubpipe#(.HANDLE_UNALIGNED(1))
    mem0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedMemP[0],
       // readReqs[0],
      //  sysReadReqs[0],
        accessDescs[0],
        dcacheTranslations[0],
        dcacheOuts[0],
        sysOuts[0],
        fromSq[0],
        fromLq[0]
    );

    // Mem 2 - for ReplayQueue only!
    MemSubpipe#(.HANDLE_UNALIGNED(1))
    mem2(
        insMap,
        branchEventInfo,
        lateEventInfo,
        issuedReplayQueue,
      //  readReqs[2],
     //   sysReadReqs[2],
        accessDescs[2],
        dcacheTranslations[2],
        dcacheOuts[2],
        sysOuts[2],
        fromSq[2],
        fromLq[2]
    );

    // Vec 0
    RegularSubpipe float0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedFloatP[0]
    );
    
    // Vec 1
    RegularSubpipe float1(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedFloatP[1]
    );


    StoreDataSubpipe storeData0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedStoreDataP[0]
    );


//    assign readReqs[1] = EMPTY_READ_REQ;
//    assign readReqs[3] = EMPTY_READ_REQ;

//    assign sysReadReqs[1] = EMPTY_READ_REQ;
//    assign sysReadReqs[3] = EMPTY_READ_REQ;

    ReplayQueue replayQueue(
        insMap,
        AbstractCore.clk,
        branchEventInfo,
        lateEventInfo,
        toReplayQueue,
        issuedReplayQueue
    );
    
    // TODO: apply for Issue
    assign TMP_memAllow = replayQueue.accept;

    assign doneRegular0_E = regular0.stage0_E;
    assign doneRegular1_E = regular1.stage0_E;
    assign doneBranch_E = branch0.stage0_E;
    assign doneMem0_E = TMP_mp(memToComplete(mem0.stage0_E));
    assign doneMem2_E = TMP_mp(memToComplete(mem2.stage0_E));
    assign doneFloat0_E = float0.stage0_E;
    assign doneFloat1_E = float1.stage0_E;
    assign doneStoreData_E = storeData0.stage0_E;

    assign storeDataE0_E = storeData0.stage0_E;

        assign accessDescs_E2 = '{0: mem0.accessDescE2, 1: DEFAULT_ACCESS_DESC, 2: mem2.accessDescE2, 3: DEFAULT_ACCESS_DESC};
        assign dcacheTranslations_E2 = '{0: mem0.trE2, 1: DEFAULT_TRANSLATION, 2: mem2.trE2, 3: DEFAULT_TRANSLATION};

    assign toReplayQueue0 = memToReplay(mem0.stage0_E);
    assign toReplayQueue2 = memToReplay(mem2.stage0_E);
    
    assign toReplayQueue = '{0: toReplayQueue0, 2: toReplayQueue2, default: EMPTY_UOP_PACKET};
    
    
    
    assign toLqE0 = '{0: mem0.pE0_E, 2: mem2.pE0_E, default: EMPTY_UOP_PACKET};
    assign toSqE0 = toLqE0;

        assign toLqE0_tr = toLqE0;
        assign toSqE0_tr = toSqE0;

    assign toLqE1 = '{0: mem0.pE1_E, 2: mem2.pE1_E, default: EMPTY_UOP_PACKET};
    assign toSqE1 = toLqE1;

    assign toLqE2 = '{0: mem0.pE2_E, 2: mem2.pE2_E, default: EMPTY_UOP_PACKET};
    assign toSqE2 = toLqE2;

    assign toBq = '{0: branch0.pE0_E, default: EMPTY_UOP_PACKET};


    ForwardingElement intImages[N_INT_PORTS][-3:1];
    ForwardingElement memImages[N_MEM_PORTS][-3:1];
    ForwardingElement floatImages[N_VEC_PORTS][-3:1];

    IntByStage intImagesTr;
    MemByStage memImagesTr;
    VecByStage floatImagesTr;

    ForwardsByStage_0 allByStage;

    assign intImages = '{0: regular0.image_E, 1: regular1.image_E, 2: branch0.image_E, default: EMPTY_IMAGE};
    assign memImages = '{0: mem0.image_E, 2: mem2.image_E, default: EMPTY_IMAGE};
    assign floatImages = '{0: float0.image_E, 1: float1.image_E, default: EMPTY_IMAGE};

    assign intImagesTr = trsInt(intImages);
    assign memImagesTr = trsMem(memImages);
    assign floatImagesTr = trsVec(floatImages);

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

    // TOPLEVEL
    function automatic Mword calcRegularOp(input UidT uid);
        Mword3 args = getAndVerifyArgs(uid);
        Mword lk = getAdr(U2M(uid)) + 4;
        Mword result = calcArith(decUname(uid), args, lk);  
        insMap.setActualResult(uid, result);
        
        return result;
    endfunction

    // TODO: make multicycle pipes for mul/div
    function automatic Mword calcArith(UopName name, Mword args[3], Mword linkAdr);
        Mword res = 'x;
        
        case (name)
            UOP_int_and:  res = args[0] & args[1];
            UOP_int_or:   res = args[0] | args[1];
            UOP_int_xor:  res = args[0] ^ args[1];
            
            UOP_int_addc: res = args[0] + args[1];
            UOP_int_addh: res = args[0] + (args[1] << 16);
            
            UOP_int_add:  res = args[0] + args[1];
            UOP_int_sub:  res = args[0] - args[1];
            
                UOP_int_cgtu:  res = $unsigned(args[0]) > $unsigned(args[1]);
                UOP_int_cgts:  res = $signed(args[0]) > $signed(args[1]);
            
            UOP_int_shlc:
                            if ($signed(args[1]) >= 0) res = $unsigned(args[0]) << args[1];
                            else                       res = $unsigned(args[0]) >> -args[1];
            UOP_int_shac:
                            if ($signed(args[1]) >= 0) res = $unsigned(args[0]) << args[1];
                            else                       res = $unsigned(args[0]) >> -args[1];                     
            UOP_int_rotc:
                            if ($signed(args[1]) >= 0) res = {args[0], args[0]} << args[1];
                            else                       res = {args[0], args[0]} >> -args[1];
            
            // mul/div/rem
            UOP_int_mul:   res = args[0] * args[1];
            UOP_int_mulhu: res = (Dword'($unsigned(args[0])) * Dword'($unsigned(args[1]))) >> 32;
            UOP_int_mulhs: res = (Dword'($signed(args[0])) * Dword'($signed(args[1]))) >> 32;
            UOP_int_divu:  res = divUnsignedW(args[0], args[1]);
            UOP_int_divs:  res = divSignedW(args[0], args[1]);
            UOP_int_remu:  res = remUnsignedW(args[0], args[1]);
            UOP_int_rems:  res = remSignedW(args[0], args[1]);
            
            UOP_int_link: res = linkAdr;
            
            // FP
            UOP_fp_move:   res = args[0];
            UOP_fp_or:     res = args[0] | args[1];
            UOP_fp_addi:   res = args[0] + args[1];

            default: $fatal(2, "Wrong uop");
        endcase
        
        // Handling of cases of division by 0  
        if ((name inside {UOP_int_divs, UOP_int_divu, UOP_int_rems, UOP_int_remu}) && $isunknown(res)) res = -1;

        return res;
    endfunction


    // TOPLEVEL
    function automatic UopPacket performBranchE0(input UopPacket p);
        if (!p.active) return p;
        begin
            UidT uid = p.TMP_oid;
            Mword3 args = getAndVerifyArgs(uid);
            p.result = resolveBranchDirection(decUname(uid), args[0]);// reg
        end
        return p;
    endfunction


    task automatic runExecBranch(input logic active, input UidT uid);
        AbstractCore.branchEventInfo <= EMPTY_EVENT_INFO;

        if (!active) return;

        setBranchInCore(uid);
        putMilestone(uid, InstructionMap::ExecRedirect);
    endtask


    task automatic setBranchInCore(input UidT uid);
        UopName uname = decUname(uid);
        Mword3 args = insMap.getU(uid).argsA;
        Mword adr = getAdr(U2M(uid));
        Mword takenTrg = takenTarget(uname, adr, args); // reg or stored in BQ
        
        logic predictedDir = insMap.get(U2M(uid)).frontBranch;
        logic dir = resolveBranchDirection(uname, args[0]);// reg
        logic redirect = predictedDir ^ dir;
        
        Mword expectedTrg = dir ? takenTrg : adr + 4;
        Mword resolvedTarget = finalTarget(uname, dir, args[1], AbstractCore.theBq.lookupTarget, AbstractCore.theBq.lookupLink);
        
        assert (resolvedTarget === expectedTrg) else $error("Branch target wrong!");
        assert (!$isunknown(predictedDir)) else $fatal(2, "Front branch info not in insMap");

        if (redirect) putMilestoneM(U2M(uid), InstructionMap::ExecRedirect);

        AbstractCore.branchEventInfo <= '{1, U2M(uid), CO_none, redirect, adr, resolvedTarget};
    endtask
    

    function automatic logic resolveBranchDirection(input UopName uname, input Mword condArg);        
        assert (!$isunknown(condArg)) else $fatal(2, "Branch condition not well formed\n%p, %p", uname, condArg);
        
        case (uname)
            UOP_bc_z, UOP_br_z:  return condArg === 0;
            UOP_bc_nz, UOP_br_nz: return condArg !== 0;
            UOP_bc_a, UOP_bc_l: return 1;  
            default: $fatal(2, "Wrong branch uop");
        endcase            
    endfunction

    function automatic Mword takenTarget(input UopName uname, input Mword adr, input Mword args[3]);
        case (uname)
            UOP_br_z, UOP_br_nz:  return args[1];
            UOP_bc_z, UOP_bc_nz, UOP_bc_a, UOP_bc_l: return adr + args[1];  
            default: $fatal(2, "Wrong branch uop");
        endcase  
    endfunction

    function automatic Mword finalTarget(input UopName uname, input logic dir, input Mword regValue, input Mword bqTarget, input Mword bqLink);
        if (dir === 0) return bqLink;

        case (uname)
            UOP_br_z, UOP_br_nz:  return regValue;
            UOP_bc_z, UOP_bc_nz, UOP_bc_a, UOP_bc_l: return bqTarget;  
            default: $fatal(2, "Wrong branch uop");
        endcase 
    endfunction

    function automatic UopPacket performStoreData(input UopPacket p);
        if (p.TMP_oid == UIDT_NONE) return p;
                
        begin
            UopPacket res = p;
            Mword3 args = getAndVerifyArgs(p.TMP_oid);
            res.result = args[2];
            return res;
        end
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

