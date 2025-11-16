
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
    
    UopMemPacket toReplayQueue0, toReplayQueue2;
    UopMemPacket toReplayQueue[N_MEM_PORTS];

    
    UopMemPacket toLqE0[N_MEM_PORTS];
    UopMemPacket toLqE1[N_MEM_PORTS];
    UopMemPacket toLqE2[N_MEM_PORTS];

    AccessDesc accessDescs_E0[N_MEM_PORTS];
    AccessDesc accessDescs_E2[N_MEM_PORTS];

    Translation dcacheTranslations_EE0[N_MEM_PORTS]; // source: DataL1
    Translation dcacheTranslations_E1[N_MEM_PORTS];
    Translation dcacheTranslations_E2[N_MEM_PORTS];


    DataCacheOutput dcacheOuts_E1[N_MEM_PORTS];
    DataCacheOutput uncachedOuts_E1[N_MEM_PORTS];
    DataCacheOutput sysOuts_E1[N_MEM_PORTS];
    
    UopMemPacket sqResponse_E1[N_MEM_PORTS];



    UopMemPacket toBq[N_MEM_PORTS]; // FUTURE: Customize this width in MemBuffer (or make whole new module for BQ)?  


    

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
        toReplayQueue,
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

    assign toReplayQueue0 = memToReplay(mem0.stage0_E);
    assign toReplayQueue2 = memToReplay(mem2.stage0_E);
    
    assign toReplayQueue = '{0: toReplayQueue0, 2: toReplayQueue2, default: EMPTY_UOP_PACKET};
    

    assign toLqE0 = '{0: mem0.pE0_E, 2: mem2.pE0_E, default: EMPTY_UOP_PACKET};
    assign toLqE1 = '{0: mem0.pE1_E, 2: mem2.pE1_E, default: EMPTY_UOP_PACKET};
    assign toLqE2 = '{0: mem0.pE2_E, 2: mem2.pE2_E, default: EMPTY_UOP_PACKET};


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
    assign floatImages = '{0: float0.image_E, 1: float1.image_E, 2: fdiv.image_E, default: EMPTY_IMAGE};

    always_comb intImagesTr = trsInt(intImages);
    always_comb memImagesTr = trsMem(memImages);
    always_comb floatImagesTr = trsVec(floatImages);

    assign allByStage.ints = intImagesTr;
    assign allByStage.mems = memImagesTr;
    assign allByStage.vecs = floatImagesTr;



    generate
        logic chp, chq;
    
        InsId firstEventId_N = -1, firstFloatInvId = -1, firstFloatOvId = -1;
        
            OpSlotB staticEventSlot = EMPTY_SLOT_B;


        OpSlotB staticEventReg = EMPTY_SLOT_B;
        UopPacket memEventReg = EMPTY_UOP_PACKET;
        UopPacket memRefetchReg = EMPTY_UOP_PACKET;
        UopPacket fpInvReg = EMPTY_UOP_PACKET;
        UopPacket fpOvReg = EMPTY_UOP_PACKET;

        OpSlotB staticEventNewH = EMPTY_SLOT_B;
        UopPacket memEventNewH = EMPTY_UOP_PACKET;
        UopPacket memRefetchNewH = EMPTY_UOP_PACKET;
        UopPacket fpInvNewH = EMPTY_UOP_PACKET;
        UopPacket fpOvNewH = EMPTY_UOP_PACKET;

        OpSlotB staticEventOldH = EMPTY_SLOT_B;
        UopPacket memEventOldH = EMPTY_UOP_PACKET;
        UopPacket memRefetchOldH = EMPTY_UOP_PACKET;
        UopPacket fpInvOldH = EMPTY_UOP_PACKET;
        UopPacket fpOvOldH = EMPTY_UOP_PACKET;

        InsId lqRefetchReg = -1, lqRefetchOldH = -1, lqRefetchNewH = -1;


           assign chp = U2M(fpOvReg.TMP_oid) === firstFloatOvId;
           assign chq = U2M(fpInvReg.TMP_oid) === firstFloatInvId;


            function automatic OpSlotB replaceEvS(input OpSlotB prev, input OpSlotB next);
                InsId prevId = prev.mid;
                InsId nextId = next.mid;
            
                if (prevId == -1) return next;
                else if (nextId != -1 && prevId > nextId) return next;
                else return prev;
            endfunction


            function automatic UopPacket replaceEvP(input UopPacket prev, input UopPacket next);
                InsId prevId = U2M(prev.TMP_oid);
                InsId nextId = U2M(next.TMP_oid);
            
                if (prevId == -1) return next;
                else if (nextId != -1 && prevId > nextId) return next;
                else return prev;
            endfunction


            function automatic OpSlotB getOldestRenameEvSlot();
                OpSlotB found[$] = AbstractCore.stageRename1.find_first with (item.active && hasStaticEvent(item.mid));// && item.);
                // No need to find oldest because they are ordered in slot. They are also younger than any executed op and current slot content.

                if (found.size() == 0) return EMPTY_SLOT_B;
                else return found[0];
            endfunction
            
            

                task automatic gatherStaticEvents();        
                    OpSlotB found[$] = AbstractCore.stageRename1.find_first with (item.active && hasStaticEvent(item.mid));// && item.);
                    // No need to find oldest because they are ordered in slot. They are also younger than any executed op and current slot content.

                    if (found.size() == 0) return;
                    if (!staticEventSlot.active && !branchEventInfo.redirect && !lateEventInfo.redirect) staticEventSlot <= found[0];
                endtask


            function automatic UopPacket effEventP(input UopPacket p);
                InsId lastId = AbstractCore.lastRetired;

                if (lateEventInfo.redirect && lateEventInfo.eventMid == U2M(p.TMP_oid) || (lastId != -1 && lastId >= U2M(p.TMP_oid)))
                                             // TODO: redundant lateEventInfo.eventMid cause lateEventInfo.redirect flushes it anyway?
                    return EMPTY_UOP_PACKET;
                else
                    return effP(p);
            endfunction

            function automatic OpSlotB effEventS(input OpSlotB s);
                InsId lastId = AbstractCore.lastRetired;

                if (shouldFlushId(s.mid) || (lastId != -1 && lastId >= s.mid))
                    return EMPTY_SLOT_B;
                else
                    return s;
            endfunction



            function automatic UopPacket findOldestMemWithState(input ExecStatus refSt);
                ForwardingElement memStages0[N_MEM_PORTS] = memImagesTr[0];
                ForwardingElement found[$] = memStages0.find with (item.active && item.status == refSt);
                ForwardingElement oldest[$] = found.min with (U2M(item.TMP_oid));
                
                if (found.size() == 0) return EMPTY_UOP_PACKET;
                
                assert (oldest[0].TMP_oid != UIDT_NONE) else $fatal(2, "id none");
                return oldest[0];
            endfunction

             function automatic UopPacket findOldestFpWithState(input ExecStatus refSt);
                ForwardingElement fpStages0[N_MEM_PORTS] = floatImagesTr[0];
                ForwardingElement found[$] = fpStages0.find with (item.active && item.status == refSt);
                ForwardingElement oldest[$] = found.min with (U2M(item.TMP_oid));
                
                if (found.size() == 0) return EMPTY_UOP_PACKET;
                
                assert (oldest[0].TMP_oid != UIDT_NONE) else $fatal(2, "id none");
                return oldest[0];
            endfunction
        
        
        always @(negedge AbstractCore.clk) begin
            staticEventOldH <= effEventS(staticEventReg);
            memEventOldH <= effEventP(memEventReg);
            memRefetchOldH <= effEventP(memRefetchReg);
            lqRefetchOldH <= shouldFlushId(lqRefetchReg) ? -1 : lqRefetchReg;

            fpInvOldH <= effEventP(fpInvReg);
            fpOvOldH <= effEventP(fpOvReg);
            

            staticEventNewH <= effEventS(getOldestRenameEvSlot());
            memEventNewH <= effEventP(findOldestMemWithState(ES_ILLEGAL));
            memRefetchNewH <= effEventP(findOldestMemWithState(ES_REFETCH));
            lqRefetchNewH <= shouldFlushId(theLq.submod.oldestRefetchEntryP0.mid) ? -1 : theLq.submod.oldestRefetchEntryP0.mid;
            
            fpInvNewH <= effEventP(findOldestFpWithState(ES_FP_INVALID));
            fpOvNewH <= effEventP(findOldestFpWithState(ES_FP_OVERFLOW));
        end
        
        
        always @(posedge AbstractCore.clk) begin
            staticEventReg <= replaceEvS(staticEventOldH, staticEventNewH);
            memEventReg <= replaceEvP(memEventOldH, memEventNewH);
            memRefetchReg <= replaceEvP(memRefetchOldH, memRefetchNewH);
            lqRefetchReg <= replaceEvId(lqRefetchOldH, lqRefetchNewH);
            
            fpInvReg <= replaceEvP(fpInvOldH, fpInvNewH);
            fpOvReg <= replaceEvP(fpOvOldH, fpOvNewH);
            
            ///////////////////////////////
                  
            updateFirstEvent();
        
            updateArithBits();

            if (shouldFlushId(staticEventSlot.mid)) staticEventSlot <= EMPTY_SLOT_B;
            gatherStaticEvents();         
        end



        task automatic updateFirstEvent();
            OpSlotB foundRename[$] = AbstractCore.stageRename1.find_first with (item.active && hasStaticEvent(item.mid));

            ForwardingElement memStages0[N_MEM_PORTS] = memImagesTr[0];
            ForwardingElement oldestMemIll[$] = findOldestWithStatus(memStages0, ES_ILLEGAL);
            ForwardingElement oldestMemRef[$] = findOldestWithStatus(memStages0, ES_REFETCH);

            ForwardingElement floatStages0[N_VEC_PORTS] = floatImagesTr[0];

            ForwardingElement oldestInv[$] = findOldestWithStatus(floatStages0, ES_FP_INVALID);
            ForwardingElement oldestOv[$] =  findOldestWithStatus(floatStages0, ES_FP_OVERFLOW);


            begin
                InsId nextId = firstEventId_N;
                if (foundRename.size() > 0) nextId = replaceEvId(nextId, foundRename[0].mid);
                if (oldestMemIll.size() > 0) nextId = replaceEvId(nextId, U2M(oldestMemIll[0].TMP_oid));                                    
                if (oldestMemRef.size() > 0) nextId = replaceEvId(nextId, U2M(oldestMemRef[0].TMP_oid));                                    
                nextId = replaceEvId(nextId, theLq.submod.oldestRefetchEntryP0.mid);
                
                if (AbstractCore.CurrentConfig.enArithExc && oldestInv.size() > 0) nextId = replaceEvId(nextId, U2M(oldestInv[0].TMP_oid));
                if (AbstractCore.CurrentConfig.enArithExc && oldestOv.size() > 0)  nextId = replaceEvId(nextId, U2M(oldestOv[0].TMP_oid));
                
                if (shouldFlushId(nextId)) firstEventId_N <= -1;
                else firstEventId_N <= nextId;
            end

        endtask

    
            task automatic updateArithBits();        
                ForwardingElement floatStages0[N_VEC_PORTS] = floatImagesTr[0];
    
                ForwardingElement oldestInv[$] = findOldestWithStatus(floatStages0, ES_FP_INVALID);
                ForwardingElement oldestOv[$] =  findOldestWithStatus(floatStages0, ES_FP_OVERFLOW);
    
                begin
                    InsId nextId = firstFloatInvId;
                    if (oldestInv.size() > 0) begin
                        nextId = replaceEvId(nextId, U2M(oldestInv[0].TMP_oid));
                    end
    
                    if (shouldFlushId(nextId)) firstFloatInvId <= -1;
                    else if (AbstractCore.lastRetired == nextId) firstFloatInvId <= -1;
                    else firstFloatInvId <= nextId;
                end
    
                begin
                    InsId nextId = firstFloatOvId;
                    if (oldestOv.size() > 0) begin
                        nextId = replaceEvId(nextId, U2M(oldestOv[0].TMP_oid));                                    
                        if (AbstractCore.CurrentConfig.enArithExc) insMap.setException(U2M(oldestOv[0].TMP_oid), PE_ARITH_EXCEPTION);
                    end
    
                    if (shouldFlushId(nextId)) firstFloatOvId <= -1;
                    else if (AbstractCore.lastRetired == nextId) firstFloatOvId <= -1;
                    else firstFloatOvId <= nextId;
                end
    
            endtask
    

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

