
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;


module IssueQueue
#(
    parameter int SIZE = ISSUE_QUEUE_SIZE,
    parameter int OUT_WIDTH = 1
)
(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input TMP_Uop inGroupU[RENAME_WIDTH],
        
    input logic allow,   
    output UopPacket outPackets[OUT_WIDTH]
);

    localparam int HOLD_CYCLES = 3;
    localparam int N_HOLD_MAX = (HOLD_CYCLES+1) * OUT_WIDTH;
    localparam int TOTAL_SIZE = SIZE + N_HOLD_MAX;

    typedef UidT UidArray[];
    typedef int InputLocs[RENAME_WIDTH];

    typedef UopPacket OutGroupP[OUT_WIDTH];
 
    typedef IqEntry InputArray[RENAME_WIDTH];
    
    IqEntry array[TOTAL_SIZE] = '{default: EMPTY_ENTRY}, arrayReg[TOTAL_SIZE] = '{default: EMPTY_ENTRY};
    InputArray inputArray = '{default: EMPTY_ENTRY};

    logic readyForIssue[OUT_WIDTH] = '{default: 0};
    UopPacket pIssued0[OUT_WIDTH] = '{default: EMPTY_UOP_PACKET}, pIssued1[OUT_WIDTH] = '{default: EMPTY_UOP_PACKET};

    int num = 0;    


    typedef Wakeup WakeupMatrix[TOTAL_SIZE][3];
    typedef Wakeup WakeupInputMatrix[RENAME_WIDTH][3];

    WakeupMatrix wMatrix;
    WakeupInputMatrix wiMatrix;

    ReadinessInfo readiness[TOTAL_SIZE],  readinessVar[TOTAL_SIZE];
    ReadinessInfo readinessInput[RENAME_WIDTH], readinessInputVar[RENAME_WIDTH];
    
    typedef ReadinessInfo ReadinessInfoArr[];

    logic anySelected;

    always_comb anySelected = anyReady();

    always_comb  outPackets = effA(pIssued0);

    always_comb inputArray = makeInputArray(inGroupU); 

    always @(negedge AbstractCore.clk) begin
        wMatrix = getForwardsD(arrayReg);
        wiMatrix = getForwardsD(inputArray);
    end

    always_comb readiness = getReadinessArr(arrayReg, wMatrix);
    always_comb readinessInput = getReadinessArr(inputArray, wiMatrix);

    assign readinessVar = readiness;
    assign readinessInputVar = readinessInput;

    function automatic logic anyReady();
        int inds[$] = readiness.find_first_index with (item.all);
        return inds.size() > 0;
    endfunction



    always @(posedge AbstractCore.clk) begin
        array = arrayReg;
    
        TMP_incIssueCounter();

        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
           flushIq();
        end

        updateWakeups();
        updateWakeups_Part2();

        issue();

        // Assure that ready indications in entries agree with ready signals
        checkReadyStatus();
        
        if (!(lateEventInfo.redirect || branchEventInfo.redirect)) begin
            writeInput();
        end                

        removeIssuedFromArray();

            unlockBarrier();


        arrayReg <= array;

        foreach (pIssued0[i])
            pIssued1[i] <= tickP(pIssued0[i]);

        num <= getNumUsed();
    end


        function automatic void unlockBarrier();
            if (!AbstractCore.barrierUnlocking) return;

            foreach (array[i]) begin
                if (array[i].status == IqSuspended && array[i].barrier <= AbstractCore.barrierUnlockingMid) begin
                    array[i].status = IqActive;
                       // $error("unlocking %d [%d]", array[i].uid.m,  array[i].barrier);
                end
            end
        endfunction


    function automatic ReadinessInfoArr getReadinessArr(input IqEntry arr[], input Wakeup wm[][3]);
        ReadinessInfoArr res = new[arr.size()];           
        foreach (res[i]) res[i] = getReadinessInfo(insMap, arr[i], wm[i]);
        return res;
    endfunction


    task automatic updateWakeups();    
        foreach (array[i]) begin            
            if (array[i].status != IqEmpty) updateReadyBits(array[i], readinessVar[i].combined, readinessVar[i].poisons);
        end
    endtask

    task automatic updateWakeups_Part2();
        foreach (array[i])
            if (array[i].status != IqEmpty) updateReadyBits_Part2(array[i]);
    endtask

    task automatic issue();
        UidArray selected = getArrOpsToIssue_A();

        pIssued0 <= '{default: EMPTY_UOP_PACKET};
        
        readyForIssue = '{default: 0};
        foreach (readyForIssue[i]) readyForIssue[i] = (selected[i] != UIDT_NONE);
        
        if (allow) begin
            issueFromArray_0(selected);
            issueFromArray_1(selected);
         end
    endtask


    function automatic UidArray getArrOpsToIssue_A();
        UidT res[] = new[OUT_WIDTH];
        int cnt = 0;
        
        UidQueueT idsSorted = getActiveIdQueue(array);
        
        res = '{default: UIDT_NONE};
        
        idsSorted.sort with (U2M(item));

        foreach (idsSorted[i]) begin
            UidT thisId = idsSorted[i];

            int arrayLoc[$] = array.find_index with (item.uid == thisId); // array
            IqEntry entry = array[arrayLoc[0]];     // array
            logic ready = readinessVar[arrayLoc[0]].all;

            assert (entry.status == IqActive) else $fatal(2, "!!!!!!Issue inactive slot");

            if (ready) res[cnt++] = thisId;
            
            if (cnt == OUT_WIDTH) break;
        end
        
        return res;
    endfunction


    // MOVE?
    function automatic UopPacket makeUop(input IqEntry entry, input ReadinessInfo ri);
        logic3 prevReady = ri.prevReady;
        Poison currentPoisons[3] = ri.poisons;
        Poison prevPoisons[3] = ri.prevPoisons;
        Poison properPoisons[3];
        
        Poison newPoison;
        UopPacket newPacket;

        foreach (properPoisons[i]) properPoisons[i] = (prevReady[i]) ? prevPoisons[i] : currentPoisons[i];
        
        newPoison = mergePoisons(properPoisons);
        return '{1, entry.uid, MC_NONE, ES_BEGIN, newPoison, 'x};
    endfunction


    task automatic setIssued(ref IqEntry entry);
        putMilestone(entry.uid, InstructionMap::IqIssue);
        entry.status = IqIssued;
        entry.active_ = 0;         // Entry upd
        entry.issueCounter = 0;   // Entry upd
    endtask


    task automatic issueFromArray_0(input UidArray ua);

        foreach (ua[i]) begin
            UidT theId = ua[i];
            int found[$] = array.find_first_index with (item.uid == theId);
            int s = found[0];

            if (theId == UIDT_NONE) continue;

            assert (array[s].status == IqActive) else $fatal(2, "!!!Inactive slot to issue?");

                //TODO;
                // check for violation of conditions preventing issue
                // * mem: when barrier active 
                // * mem: when store-load dependecy prediction block a load
            if (isMemUop(decUname(theId))) begin

                  //  if (U2M(theId) inside {6076, 6077}) $error("\n    Issue uop %d: %p\n", U2M(theId), decUname(theId));

                void'(AbstractCore.memTracker.checkIssue(theId));
            end

            begin
                UopPacket newPacket = makeUop(array[s], readinessVar[s]);
                pIssued0[i] <= tickP(newPacket);
            end

        end
    endtask
    
    task automatic issueFromArray_1(input UidArray ua);
        foreach (ua[i]) begin
            UidT theId = ua[i];
            int found[$] = array.find_first_index with (item.uid == theId);
            int s = found[0];

            if (theId == UIDT_NONE) continue;

            assert (array[s].status == IqActive) else $fatal(2, "!!!!!Inactive slot to issue?");

            setIssued(array[s]);
        end
    endtask

    // Only a check
    function automatic void checkReadyStatus();
        foreach (array[i]) begin
            logic signalReady = readinessVar[i].all;
            IqEntry entry = array[i];

            if (entry.status != IqActive) continue;
            
            assert (entry.state.ready == signalReady) else $fatal(2, "Check ready bits: differ entry %p, sig %p\n%p", entry.state.ready, signalReady, entry);
        end
    endfunction

    task automatic TMP_incIssueCounter();
        foreach (array[s])
            if (array[s].status == IqIssued) begin
                array[s].issueCounter++;  // Entry upd
            end
    endtask

    task automatic removeIssuedFromArray();
        foreach (array[s]) begin
            if (array[s].issueCounter == HOLD_CYCLES) begin
                assert (array[s].status == IqIssued) else $fatal(2, "slot to remove must be used and inactive\n%p", array[s]);
                putMilestone(array[s].uid, InstructionMap::IqExit);                                
                array[s] = EMPTY_ENTRY;  // Entry upd
            end
        end
    endtask


    function automatic IqEntry makeIqEntry(input TMP_Uop inUop);
        InsId barrier = insMap.getU(inUop.uid).barrier;
        SlotStatus status = IqActive;
        
            if (barrier != -1) status = IqSuspended; // TODO: introduce barrier unlocking
        
            if (0) status = IqLocked; // TODO: when resource conflicts like divider/multiplier competition come into play

        return inUop.active ? '{used: 1, active_: 1,
                                status: status,
                                state: ZERO_ARG_STATE,
                                barrier: barrier,
                                poisons: DEFAULT_POISON_STATE, issueCounter: -1, uid: inUop.uid}
                                : EMPTY_ENTRY;
    endfunction

    // MOVE?
    function automatic InputArray makeInputArray(input TMP_Uop inUops[RENAME_WIDTH]);
        InputArray res = '{default: EMPTY_ENTRY};
        foreach (res[i]) begin
            if (inUops[i].active !== 1) continue;
            res[i] = makeIqEntry(inUops[i]);
        end
        return res;
    endfunction


    task automatic writeInput();
        InputLocs locs = getInputLocs();
        int nInserted = 0;

        foreach (inputArray[i]) begin
            if (inGroupU[i].active) begin
                int location = locs[nInserted];
                array[location] = inputArray[i];  // Entry upd
                nInserted++;          

                putMilestone(inputArray[i].uid, InstructionMap::IqEnter);
                updateReadyBits(array[location], readinessInputVar[i].combined, readinessInputVar[i].poisons);
            end
        end
    endtask


    task automatic flushIq();
        if (lateEventInfo.redirect) flushOpQueueAll();
        else if (branchEventInfo.redirect) flushOpQueuePartial(branchEventInfo.eventMid);
    endtask

    task automatic flushOpQueueAll();
        foreach (array[i]) begin
            if (array[i].status != IqEmpty) putMilestone(array[i].uid, InstructionMap::IqFlush);
            array[i] = EMPTY_ENTRY;  // Entry upd
        end
    endtask

    task automatic flushOpQueuePartial(input InsId id);
        foreach (array[i]) begin
            if (U2M(array[i].uid) > id) begin
                if (array[i].status != IqEmpty) putMilestone(array[i].uid, InstructionMap::IqFlush);
                array[i] = EMPTY_ENTRY;  // Entry upd
            end
        end
    endtask

    function automatic InputLocs getInputLocs();
        InputLocs res = '{default: -1};
        int nFound = 0;

        foreach (array[i])
            if (array[i].status == IqEmpty) begin
                res[nFound++] = i;
            end
        return res;
    endfunction


    function automatic void updateReadyBits(ref IqEntry entry, input logic3 ready3, /*input Wakeup wup[3],*/ input Poison poisons[3]);
        foreach (ready3[a]) begin
            if (ready3[a] && !entry.state.readyArgs[a]) begin // Entry tr rd? (only for DB?)
                setArgReady(entry, a,/* wup[a],*/ poisons[a]);
            end
        end

        if (entry.state.readyArgs.and()) begin // Entry tr rd? (only DB)
            if (!entry.state.ready) putMilestone(entry.uid, InstructionMap::IqWakeupComplete);
            entry.state.ready = 1;  // Entry upd
        end
    endfunction    

    function automatic void updateReadyBits_Part2(ref IqEntry entry);
        foreach (entry.state.readyArgs[a]) begin
            // Check for args to cancel.
            // CAREFUL: it seems this can't apply to arg that is being woken up now, because wakeup is suppressed if poisoned by failing op.
            if (entry.state.readyArgs[a] && shouldFlushPoison(entry.poisons.poisoned[a])) begin // handle retraction if applies   // Entry tr rd? (but state bing read should be in FFs 
                pullbackEntry(entry);                                                           // - can't be cancelled right when being waked)
                cancelArg(entry, a);
            end
        end
    endfunction

    function automatic void setArgReady(ref IqEntry entry, input int a, /*input Wakeup wup,*/ input Poison p);
        entry.state.readyArgs[a] = 1;            // Entry upd
        entry.poisons.poisoned[a] = p;//wup.poison;  // Entry upd
        putMilestone(entry.uid, wakeupMilestone(a));
    endfunction

    function automatic void cancelArg(ref IqEntry entry, input int a);
        entry.state.readyArgs[a] = 0;             // Entry upd
        entry.poisons.poisoned[a] = EMPTY_POISON; // Entry upd

        putMilestone(entry.uid, cancelMilestone(a));
    endfunction

    function automatic void pullbackEntry(ref IqEntry entry);
        if (entry.state.ready) putMilestone(entry.uid, InstructionMap::IqPullback);

        // cancel issue
        entry.status = IqActive; // TODO: or IqLocked if possible resource conflict?
        entry.active_ = 1;        // Entry upd
        entry.issueCounter = -1; // Entry upd                  
        entry.state.ready = 0;   // Entry upd
    endfunction


    function automatic int getNumUsed();
        int res = 0;
        foreach (array[s]) if (array[s].status != IqEmpty) res++; 
        return res; 
    endfunction

    function automatic UidQueueT getIdQueue(input IqEntry entries[]);
        UidT res[$];
        
        foreach (entries[i]) begin
            UidT uid = (entries[i].status != IqEmpty) ? entries[i].uid : UIDT_NONE;
            res.push_back(uid);
        end
        
        return res;
    endfunction

        function automatic UidQueueT getActiveIdQueue(input IqEntry entries[]);
            UidT res[$];
            
            foreach (entries[i]) begin
                if (entries[i].status == IqActive)
                    res.push_back(entries[i].uid);
            end
            
            return res;
        endfunction

    function automatic OutGroupP effA(input OutGroupP g);
        OutGroupP res;
        foreach (g[i]) res[i] = effP(g[i]);
        
        return res;
    endfunction

    function automatic Wakeup3 getForwardsForOp(input IqEntry entry, input ForwardingElement memStage0[N_MEM_PORTS]);
        Wakeup3 res = '{default: EMPTY_WAKEUP};
        if (entry.uid == UIDT_NONE) return res;
        
        foreach (entry.state.readyArgs[a]) begin
            InsDependencies deps = insMap.getU(entry.uid).deps;
            SourceType argType = deps.types[a];
            UidT prod = deps.producers[a];
            int source = deps.sources[a];
            
            Wakeup wup = checkForwardSourceInt(insMap, prod, source, AbstractCore.theExecBlock.intImages);
            if (!wup.active) wup = checkForwardSourceVec(insMap, prod, source, AbstractCore.theExecBlock.floatImages);
            // CAREFUL: Not using mem pipe forwarding for FP to simplify things
            if (!wup.active && argType != SRC_FLOAT) wup = checkForwardSourceMem(insMap, prod, source, AbstractCore.theExecBlock.memImages);
            
            if (shouldFlushPoison(wup.poison)) wup.active = 0;
           
            if (wup.active) res[a] = wup;
        end
        return res;
    endfunction


    function automatic WakeupMatrixD getForwardsD(input IqEntry arr[]);
        WakeupMatrixD res = new[arr.size()];
        foreach (arr[i]) res[i] = getForwardsForOp(arr[i], theExecBlock.memImagesTr[0]);
        return res;
    endfunction

///////////////
    function automatic logic3 getLogic3(input Wakeup w[3]);
        logic3 r3 = '{'z, 'z, 'z};
        foreach (r3[a]) r3[a] = w[a].active;
        return r3;
    endfunction

    function automatic InstructionMap::Milestone wakeupMilestone(input int a);
        case (a)
            0: return InstructionMap::IqWakeup0;
            1: return InstructionMap::IqWakeup1;
            2: return InstructionMap::IqWakeup2;
            default: $fatal("Arg doesn't exist");
        endcase
    endfunction

    function automatic InstructionMap::Milestone cancelMilestone(input int a);
        case (a)
            0: return InstructionMap::IqCancelWakeup0;
            1: return InstructionMap::IqCancelWakeup1;
            2: return InstructionMap::IqCancelWakeup2;
            default: $fatal("Arg doesn't exist");
        endcase
    endfunction
//////////////////////////////////


    function automatic logic3 getReadyRegisterArgsForUid(input InstructionMap imap, input UidT uid);
        if (uid == UIDT_NONE) return '{'z, 'z, 'z};
        else begin
            InsDependencies deps = imap.getU(uid).deps;
            return checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);
        end
    endfunction

    function automatic ReadinessInfo getReadinessInfo(input InstructionMap insMap, input IqEntry entry, input Wakeup3 wup);//, input logic3 fwState);
        ReadinessInfo res = '{default: 'z};
        
        res.uid = entry.uid;
        
        if (entry.uid == UIDT_NONE) return res;
        
        res.used = entry.status != IqEmpty;
        res.active = //entry.active_;
                        entry.status == IqActive;
        
        res.registers = getReadyRegisterArgsForUid(insMap, entry.uid);
        res.bypasses = getLogic3(wup);
        
        foreach (res.combined[a]) res.combined[a] = res.registers[a] || res.bypasses[a];        
        foreach (res.poisons[a]) res.poisons[a] = wup[a].poison;

        res.all = res.combined.and();

        res.prevReady = entry.state.readyArgs;
        res.prevPoisons = entry.poisons.poisoned;
        
        return res;
    endfunction

endmodule



module IssueQueueComplex(
                        ref InstructionMap insMap,
                        input EventInfo branchEventInfo,
                        input EventInfo lateEventInfo,
                        input OpSlotAB inGroup
);    

                // .active, .mid
    function automatic RoutedUops routeUops(input OpSlotAB gr);
        RoutedUops res = DEFAULT_ROUTED_UOPS;
        
        foreach (gr[i]) begin
            if (!gr[i].active) continue;
            
            for (int u = 0; u < insMap.get(gr[i].mid).nUops; u++) begin // insMap dependece
                UopId uid = '{gr[i].mid, u};
                UopName uname = decUname(uid);                          // module dependence

                if (isMemUop(uname) || isLoadSysUop(uname) || isStoreSysUop(uname)) res.mem[i] = '{1, uid};
                else if (isStoreDataUop(uname)) res.storeData[i] = '{1, uid};
                else if (isBranchUop(uname)) res.branch[i] = '{1, uid};
                else if (isIntDividerUop(uname)) res.idivider[i] = '{1, uid};
                else if (isIntMultiplierUop(uname)) res.multiply[i] = '{1, uid};
                else if (isFloatDividerUop(uname)) res.fdivider[i] = '{1, uid};
                else if (isFloatCalcUop(uname)) res.float[i] = '{1, uid};
                else res.regular[i] = '{1, uid};
            end
        end
        
        return res;
    endfunction


    RoutedUops routedUops;
    
    UopPacket issuedRegularP[2];
    UopPacket issuedMultiplierP[2];
    UopPacket issuedDividerP[1];
    UopPacket issuedBranchP[1];
    UopPacket issuedFloatP[2];
    UopPacket issuedFdivP[1];
    UopPacket issuedMemP[1];
    UopPacket issuedStoreDataP[1];


    assign routedUops = routeUops(inGroup); 


    IssueQueue#(.OUT_WIDTH(2)) regularQueue(insMap, branchEventInfo, lateEventInfo, routedUops.regular, '1,
                                            issuedRegularP);                                            

    IssueQueue#(.OUT_WIDTH(1)) branchQueue(insMap, branchEventInfo, lateEventInfo, routedUops.branch, '1,
                                            issuedBranchP);


    IssueQueue#(.OUT_WIDTH(1)) dividerQueue(insMap, branchEventInfo, lateEventInfo, routedUops.idivider, theExecBlock.divider.allowIssue,
                                            issuedDividerP);

    IssueQueue#(.OUT_WIDTH(2)) multiplierQueue(insMap, branchEventInfo, lateEventInfo, routedUops.multiply, '1,
                                            issuedMultiplierP);


    IssueQueue#(.OUT_WIDTH(2)) floatQueue(insMap, branchEventInfo, lateEventInfo, routedUops.float, '1,
                                            issuedFloatP);
    IssueQueue#(.OUT_WIDTH(1)) fdivQueue(insMap, branchEventInfo, lateEventInfo, routedUops.fdivider, theExecBlock.fdiv.allowIssue,
                                            issuedFdivP);                                           

    IssueQueue#(.OUT_WIDTH(1)) memQueue(insMap, branchEventInfo, lateEventInfo, routedUops.mem, theExecBlock.memIssueAllow,
                                            issuedMemP);
    IssueQueue#(.OUT_WIDTH(1)) storeDataQueue(insMap, branchEventInfo, lateEventInfo, routedUops.storeData, '1,
                                            issuedStoreDataP);

endmodule
