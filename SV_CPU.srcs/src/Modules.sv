
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;
import Queues::*;


module RegularSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input UopPacket opP
);
    UopPacket p0, p1 = EMPTY_UOP_PACKET, pE0 = EMPTY_UOP_PACKET, pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
    UopPacket p0_E, p1_E, pE0_E, pD0_E, pD1_E;
    UopPacket stage0, stage0_E;

    assign stage0 = pE0;
    assign stage0_E = pE0_E;

    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        pE0 <= performRegularE0(tickP(p1));
        pD0 <= tickP(pE0);
        pD1 <= tickP(pD0);
    end

    assign p0_E = effP(p0);
    assign p1_E = effP(p1);
    assign pE0_E = effP(pE0);
    assign pD0_E = effP(pD0);

    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -2: p0_E,
        -1: p1_E,
        0: pE0_E,
        1: pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };

endmodule


module BranchSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input UopPacket opP
);
    UopPacket p0, p1 = EMPTY_UOP_PACKET, pE0 = EMPTY_UOP_PACKET, pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
    UopPacket p0_E, p1_E, pE0_E, pD0_E, pD1_E;
    UopPacket stage0, stage0_E;


  
    assign stage0 = pE0;
    assign stage0_E = pE0_E;
                      
    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);   
        pE0 <= performBranchE0(tickP(p1));
        pD0 <= tickP(pE0);
        pD1 <= tickP(pD0);

        runExecBranch(p1_E.active, p1_E.TMP_oid);

    end

    assign p0_E = effP(p0);
    assign p1_E = effP(p1);
    assign pE0_E = effP(pE0);
    assign pD0_E = effP(pD0);

    ForwardingElement image_E[-3:1];
    
    // Copied from RegularSubpipe
    assign image_E = '{
        -2: p0_E,
        -1: p1_E,
        0: pE0_E,
        1: pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };
endmodule



module StoreDataSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input UopPacket opP
);
    UopPacket p0, p1 = EMPTY_UOP_PACKET, pE0 = EMPTY_UOP_PACKET, pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
    UopPacket p0_E, p1_E, pE0_E, pD0_E, pD1_E;
    UopPacket stage0, stage0_E;

    assign stage0 = pE0;
    assign stage0_E = pE0_E;

    assign p0 = opP;

    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);
        pE0 <= performStoreData(tickP(p1));
        pD0 <= tickP(pE0);
        pD1 <= tickP(pD0);
    end

    assign p0_E = effP(p0);
    assign p1_E = effP(p1);
    assign pE0_E = effP(pE0);
    assign pD0_E = effP(pD0);

    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -2: p0_E,
        -1: p1_E,
        0: pE0_E,
        1: pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };

endmodule



module ExecBlock(ref InstructionMap insMap,
                input EventInfo branchEventInfo,
                input EventInfo lateEventInfo
);
    UopPacket doneRegular0, doneRegular1;
    UopPacket doneBranch;
    
    UopPacket doneMem0, doneMem2;
    
    UopPacket doneFloat0,  doneFloat1; 
    
    UopPacket doneSys;
    

    UopPacket doneRegular0_E, doneRegular1_E;
    UopPacket doneBranch_E;
    
    UopPacket doneMem0_E, doneMem2_E;
    
    UopPacket doneFloat0_E, doneFloat1_E; 
    
    UopPacket doneSys_E;


    UopPacket sysE0, sysE0_E;


    DataReadReq readReqs[N_MEM_PORTS];
    //DataReadResp readResps[N_MEM_PORTS];
    DataCacheOutput dcacheOuts[N_MEM_PORTS];
    
    logic TMP_memAllow;
    
    UopPacket issuedReplayQueue;
    
    UopPacket toReplayQueue0, toReplayQueue2;
    UopPacket toReplayQueue[N_MEM_PORTS];

    UopPacket toLq[N_MEM_PORTS];
    UopPacket toLqE2[N_MEM_PORTS];
    UopPacket toSq[N_MEM_PORTS];
    UopPacket toSqE2[N_MEM_PORTS];
    UopPacket toBq[N_MEM_PORTS]; // FUTURE: Customize this width in MemBuffer (or make whole new module for BQ)?  

    UopPacket fromSq[N_MEM_PORTS];
    UopPacket fromLq[N_MEM_PORTS];
    UopPacket fromBq[N_MEM_PORTS];
    

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
        readReqs[0],
        dcacheOuts[0],
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
        readReqs[2],
        dcacheOuts[2],
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
        theIssueQueues.issuedSysP[0]
    );


    assign readReqs[1] = EMPTY_READ_REQ;
    assign readReqs[3] = EMPTY_READ_REQ;


    ReplayQueue replayQueue(
        insMap,
        AbstractCore.clk,
        branchEventInfo,
        lateEventInfo,
        toReplayQueue,
        issuedReplayQueue
    );
    

    assign TMP_memAllow = replayQueue.accept;


    function automatic UopPacket memToComplete(input UopPacket p);
        if (needsReplay(p.status)) return EMPTY_UOP_PACKET;
        else return p;
    endfunction

    function automatic UopPacket memToReplay(input UopPacket p);
        if (needsReplay(p.status)) return p;
        else return EMPTY_UOP_PACKET;
    endfunction



    assign doneRegular0 = regular0.stage0;
    assign doneRegular1 = regular1.stage0;
    assign doneBranch = branch0.stage0;
    
    assign doneMem0 = memToComplete(mem0.stage0);
    assign doneMem2 = memToComplete(mem2.stage0);
    
    assign doneFloat0 = float0.stage0;
    assign doneFloat1 = float1.stage0;

    assign doneSys = storeData0.stage0;



    assign doneRegular0_E = regular0.stage0_E;
    assign doneRegular1_E = regular1.stage0_E;
    assign doneBranch_E = branch0.stage0_E;
    
    assign doneMem0_E = memToComplete(mem0.stage0_E);
    assign doneMem2_E = memToComplete(mem2.stage0_E);
    
    assign doneFloat0_E = float0.stage0_E;
    assign doneFloat1_E = float1.stage0_E;

    assign doneSys_E = storeData0.stage0_E;


    assign sysE0 = storeData0.stage0;
    assign sysE0_E = storeData0.stage0_E;


    assign toReplayQueue0 = memToReplay(mem0.stage0_E);
    assign toReplayQueue2 = memToReplay(mem2.stage0_E);
    
    assign toReplayQueue = '{0: toReplayQueue0, 2: toReplayQueue2, default: EMPTY_UOP_PACKET};
    
    assign toLq = '{0: mem0.pE0_E, 2: mem2.pE0_E, default: EMPTY_UOP_PACKET};
    assign toSq = toLq;

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
        UopName uname = insMap.getU(uid).name;
        Mword3 args = getAndVerifyArgs(uid);
        Mword lk = getAdr(U2M(uid)) + 4;
        Mword result = calcArith(uname, args, lk);  
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
            UOP_int_divu:  res = $unsigned(args[0]) / $unsigned(args[1]);
            UOP_int_divs:  res = divSignedW(args[0], args[1]);
            UOP_int_remu:  res = $unsigned(args[0]) % $unsigned(args[1]);
            UOP_int_rems:  res = remSignedW(args[0], args[1]);
           
            
            UOP_int_link: res = linkAdr;
            
            
            // FP
            UOP_fp_move:   res = args[0];
            UOP_fp_or:     res = args[0] | args[1];
            UOP_fp_addi:   res = args[0] + args[1];
           
           
            default: $fatal(2, "Wrong uop");
        endcase
        
        // Handing of cases of division by 0  
        if ((name inside {UOP_int_divs, UOP_int_divu, UOP_int_rems, UOP_int_remu}) && $isunknown(res)) res = -1;

        return res;
    endfunction


    // TOPLEVEL
    function automatic UopPacket performBranchE0(input UopPacket p);
        if (!p.active) return p;
        begin
            UidT uid = p.TMP_oid;
            UopName uname = insMap.getU(uid).name;
            Mword3 args = getAndVerifyArgs(uid);
            
            logic dir = resolveBranchDirection(uname, args[0]);// reg
            
            p.result = dir;
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
        UopName uname = insMap.getU(uid).name;
        Mword3 args = insMap.getU(uid).argsA;
        Mword adr = getAdr(U2M(uid));
        Mword takenTrg = takenTarget(uname, adr, args); // reg or stored in BQ
        
        logic predictedDir = insMap.get(U2M(uid)).frontBranch;
        logic dir = resolveBranchDirection(uname, args[0]);// reg
        logic redirect = predictedDir ^ dir;
        
        Mword expectedTrg = dir ? takenTrg : adr + 4;

        Mword bqTarget = AbstractCore.theBq.lookupTarget;
        Mword bqLink = AbstractCore.theBq.lookupLink;

        Mword resolvedTarget = finalTarget(uname, dir, args[1], bqTarget, bqLink);
        
        assert (resolvedTarget === expectedTrg) else $error("Branch target wrong!");
        assert (!$isunknown(predictedDir)) else $fatal(2, "Front branch info not in insMap");

        if (redirect)
            putMilestoneM(U2M(uid), InstructionMap::ExecRedirect);

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
        Mword3 argsM = insMap.getU(uid).argsE;
        insMap.setActualArgs(uid, argsP);
        insMap.setArgError(uid, (argsP !== argsM));
        return argsP;
    endfunction;


    // Used once
    function automatic Mword3 getArgValues(input RegisterTracker tracker, input InsDependencies deps);
        ForwardsByStage_0 fws = allByStage;
        Mword res[3];
        logic3 ready = checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);
                    
        foreach (deps.types[i]) begin
            case (deps.types[i])
                SRC_ZERO:  res[i] = 0;
                SRC_CONST: res[i] = deps.sources[i];
                SRC_INT:   res[i] = getArgValueInt(insMap, tracker, deps.producers[i], deps.sources[i], fws, ready[i]);
                SRC_FLOAT: res[i] = getArgValueVec(insMap, tracker, deps.producers[i], deps.sources[i], fws, ready[i]);
            endcase
        end

        return res;
    endfunction


endmodule




module CoreDB();
        // dev, syntax check
        Mbyte bytes4[4] = '{5, 6, 7, 8};
        Mbyte bytes8[8] = '{'h6, 'ha, 0, 0, 0, 0, 2, 1};
        Mbyte bytesTmp[4];
        Mbyte bytesTmp2[4];

    int insMapSize = 0, trSize = 0, nCompleted = 0, nRetired = 0; // DB
        
        // Remove?
        OpSlotB lastRenamed = EMPTY_SLOT_B, lastCompleted = EMPTY_SLOT_B, lastRetired = EMPTY_SLOT_B, lastRefetched = EMPTY_SLOT_B;
    string lastRenamedStr, lastCompletedStr, lastRetiredStr, lastRefetchedStr;

        string csqStr, csqIdStr;

        InstructionInfo lastII;
        UopInfo lastUI;

    string bqStr;
    always @(posedge AbstractCore.clk) begin
        automatic int ids[$];
        foreach (AbstractCore.branchCheckpointQueue[i]) ids.push_back(AbstractCore.branchCheckpointQueue[i].id);
        $swrite(bqStr, "%p", ids);
    end

        assign lastRenamedStr = disasm(lastRenamed.bits);
        assign lastCompletedStr = disasm(lastCompleted.bits);
        assign lastRetiredStr = disasm(lastRetired.bits);
        assign lastRefetchedStr = disasm(lastRefetched.bits);

    logic cmp0, cmp1;
    Mword cmpmw0, cmpmw1, cmpmw2, cmpmw3;
   
   
        assign cmpmw0 = {>>8{bytes4}};
        assign cmpmw1 = {<<8{bytes4}};
        assign bytesTmp = bytes8[1 +: 4];
        assign bytesTmp2 = {>>{cmpmw0}};
   
endmodule
