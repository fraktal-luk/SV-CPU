
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
//    UopPacket doneRegular0, doneRegular1;
//    UopPacket doneBranch;
//    UopPacket doneMem0, doneMem2;
//    UopPacket doneFloat0,  doneFloat1; 
    
//    UopPacket doneStoreData;

    UopPacket doneRegular0_E, doneRegular1_E;
    UopPacket doneMultiplier0_E, doneMultiplier1_E;
    UopPacket doneBranch_E, doneDivider_E;
    UopPacket doneMem0_E, doneMem2_E;
    UopPacket doneFloat0_E, doneFloat1_E; 

    UopPacket doneStoreData_E;

    UopPacket storeDataE0, storeDataE0_E;


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
    MemSubpipe#(.HANDLE_UNALIGNED(1))
    mem0(
        insMap,
        branchEventInfo,
        lateEventInfo,
        theIssueQueues.issuedMemP[0],
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
        accessDescs[2],
        dcacheTranslations[2],
        dcacheOuts[2],
        sysOuts[2],
        fromSq[2],
        fromLq[2]
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
        toReplayQueue,
        issuedReplayQueue
    );
    
    // TODO: apply for Issue
    assign TMP_memAllow = replayQueue.accept;

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

    assign intImages = '{0: regular0.image_E, 1: regular1.image_E, 2: branch0.image_E, 3: divider.image_E, 4: multiplier0.image_E, 5: multiplier1.image_E, default: EMPTY_IMAGE};
    assign memImages = '{0: mem0.image_E, 2: mem2.image_E, default: EMPTY_IMAGE};
    assign floatImages = '{0: float0.image_E, 1: float1.image_E, default: EMPTY_IMAGE};

    assign intImagesTr = trsInt(intImages);
    assign memImagesTr = trsMem(memImages);
    assign floatImagesTr = trsVec(floatImages);

    assign allByStage.ints = intImagesTr;
    assign allByStage.mems = memImagesTr;
    assign allByStage.vecs = floatImagesTr;



    generate
        InsId firstEventId = -1, firstEventId_N = -1;
    
        OpSlotB staticEventSlot = EMPTY_SLOT_B;
        UopPacket memEventPacket = EMPTY_UOP_PACKET;
        UopPacket memRefetchPacket = EMPTY_UOP_PACKET;
        
        
        function automatic logic hasStaticEvent(InsId id);
            AbstractInstruction abs = insMap.get(id).basicData.dec;
            return isStaticEventIns(abs);
        endfunction
        
        task automatic gatherMemEvents();        
            ForwardingElement memStages0[N_MEM_PORTS] = memImagesTr[0];
            ForwardingElement found[$] = memStages0.find with (item.active && item.status == ES_ILLEGAL);
            
            ForwardingElement oldest[$] = found.min with (U2M(item.TMP_oid));
            
            if (found.size() == 0) return;
            
            assert (oldest[0].TMP_oid != UIDT_NONE) else $fatal(2, "id none"); 
            
            if (!memEventPacket.active || U2M(oldest[0].TMP_oid) < U2M(memEventPacket.TMP_oid)) memEventPacket <= tickP(oldest[0]);
        endtask
 
 
         task automatic gatherMemRefetches();        
            ForwardingElement memStages0[N_MEM_PORTS] = memImagesTr[0];
            ForwardingElement found[$] = memStages0.find with (item.active && item.status == ES_REFETCH);
            
            ForwardingElement oldest[$] = found.min with (U2M(item.TMP_oid));
            
            if (found.size() == 0) return;
            
            assert (oldest[0].TMP_oid != UIDT_NONE) else $fatal(2, "id none"); 
            
            if (!memRefetchPacket.active || U2M(oldest[0].TMP_oid) < U2M(memRefetchPacket.TMP_oid)) memRefetchPacket <= tickP(oldest[0]);
        endtask       
        
         task automatic gatherStaticEvents();        
            // TODO: find ops which cause events
            OpSlotB found[$] = AbstractCore.stageRename1.find_first with (item.active && hasStaticEvent(item.mid));// && item.);
            
            // No need to find oldest because they are ordered in slot. They are also younger than any executed op and current slot content.
            
            //ForwardingElement oldest[$] = found.min with (item.mid);
            
            if (found.size() == 0) return;
            
           // assert (oldest[0].TMP_oid != UIDT_NONE) else $fatal(2, "id none"); 
            
            if (!staticEventSlot.active && !branchEventInfo.redirect && !lateEventInfo.redirect) staticEventSlot <= found[0];//tickP(oldest[0]);
        endtask    
        
        task automatic updateFirstEvent();
            OpSlotB foundRename[$] = AbstractCore.stageRename1.find_first with (item.active && hasStaticEvent(item.mid));
        
            ForwardingElement memStages0[N_MEM_PORTS] = memImagesTr[0];
            ForwardingElement foundMem[$] = memStages0.find with (item.active && item.status inside {ES_ILLEGAL, ES_REFETCH});
            ForwardingElement oldestMem[$] = foundMem.min with (U2M(item.TMP_oid));
            
            // TODO: verify that oldestMem is empty or .active
            
            
            // 
            if (!branchEventInfo.redirect && !lateEventInfo.redirect && firstEventId == -1 && foundRename.size() > 0) firstEventId <= foundRename[0].mid; 
            
            if (oldestMem.size() > 0) begin
                ForwardingElement fe = tickP(oldestMem[0]);
                if (U2M(fe.TMP_oid) < firstEventId || firstEventId == -1) firstEventId <= U2M(fe.TMP_oid);
            end


            begin
                InsId nextId = firstEventId_N;
                
                if (foundRename.size() > 0) nextId = replaceId(nextId, foundRename[0].mid);
                
                if (oldestMem.size() > 0) nextId = replaceId(nextId, U2M(oldestMem[0].TMP_oid));
                                                          
                nextId = replaceId(nextId, theLq.submod.oldestRefetchEntryP0.mid);
                
                if (shouldFlushId(nextId)) firstEventId_N <= -1;
                else firstEventId_N <= nextId;
            end

        endtask
        
        
        function automatic InsId replaceId(input InsId prev, input InsId next);
            if (prev == -1) return next;
            else if (next != -1 && prev > next) return next;
            else return prev;
        endfunction
        
        
        
        always @(posedge AbstractCore.clk) begin
            if (lateEventInfo.redirect || (branchEventInfo.redirect && branchEventInfo.eventMid < firstEventId)) firstEventId <= -1;
        
            updateFirstEvent();
        
            if (lateEventInfo.redirect || branchEventInfo.redirect) staticEventSlot <= EMPTY_SLOT_B;
            //else memEventPacket <= tickP(memEventPacket);       
        
            if (lateEventInfo.redirect && lateEventInfo.eventMid == U2M(memEventPacket.TMP_oid)) memEventPacket <= EMPTY_UOP_PACKET;
            else memEventPacket <= tickP(memEventPacket);

            if (lateEventInfo.redirect && lateEventInfo.eventMid == U2M(memRefetchPacket.TMP_oid)) memRefetchPacket <= EMPTY_UOP_PACKET;
            else memRefetchPacket <= tickP(memRefetchPacket);
            
            gatherMemEvents();
            gatherMemRefetches();
            gatherStaticEvents();
        end
    
    endgenerate




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

