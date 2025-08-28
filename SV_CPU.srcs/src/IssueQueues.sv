
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
    //localparam int IN_SIZE = RENAME_WIDTH;

    localparam int HOLD_CYCLES = 3;
    localparam int N_HOLD_MAX = (HOLD_CYCLES+1) * OUT_WIDTH;
    localparam int TOTAL_SIZE = SIZE + N_HOLD_MAX;

    typedef int InputLocs[RENAME_WIDTH];

    typedef UidT IdArr[TOTAL_SIZE];

    typedef UopPacket OutGroupP[OUT_WIDTH];
 

    IqEntry array[TOTAL_SIZE] = '{default: EMPTY_ENTRY};

    ReadyQueue  rfq_perSlot;
    ReadyQueue3 forwardStates, rq_perArg, fq_perArg, rfq_perArg;

    typedef logic ReadyArray[TOTAL_SIZE];
    typedef logic ReadyArray3[TOTAL_SIZE][3];


    UopPacket pIssued0[OUT_WIDTH] = '{default: EMPTY_UOP_PACKET};
    UopPacket pIssued1[OUT_WIDTH] = '{default: EMPTY_UOP_PACKET};

    int num = 0, numUsed = 0;    
        
    typedef Wakeup Wakeup3[3];
    typedef Wakeup WakeupMatrix[TOTAL_SIZE][3];

    WakeupMatrix wMatrix, wMatrixVar;


    assign outPackets = effA(pIssued0);

    always_comb wMatrix = getForwards(array);
    always_comb forwardStates = fwFromWups(wMatrix, getIdQueue(array));

    
    typedef struct {
        UidT uid;
        logic allowed;
            logic used;
            logic active;
        logic3 registers;
        logic3 bypasses;
        logic3 combined;
        logic all;
    } ReadinessInfo;

    
    ReadinessInfo readiness[TOTAL_SIZE],  readinessVar[TOTAL_SIZE];
    typedef ReadinessInfo ReadinessInfoArr[TOTAL_SIZE];

    function automatic ReadinessInfo getReadinessInfo(input IqEntry entry, input logic3 fwState);
        ReadinessInfo res;
        
        res.uid = entry.uid;
        
        if (entry.uid == UIDT_NONE) return res;
        
            res.used = entry.used;
            res.active = entry.active;
        
        res.allowed = entry.used && entry.active;
        res.registers = TMP_getReadyRegisterArgsForUid(insMap, entry.uid);
        res.bypasses = fwState;
        
        foreach (res.combined[i]) res.combined[i] = res.registers[i] || res.bypasses[i];
        
        res.all = res.combined.and();
        
        return res;
    endfunction

    function automatic ReadinessInfoArr getReadinessArr();
        ReadinessInfoArr res;
        
        foreach (res[i])
            res[i] = getReadinessInfo(array[i], forwardStates[i]);
            
        return res;
    endfunction


    always_comb readiness = getReadinessArr();

    generate
        logic opsReady[TOTAL_SIZE];
        logic registerArgsReady[TOTAL_SIZE][3];
        logic bypassArgsReady[TOTAL_SIZE][3];
        
       // always_comb registerArgsReady = arrayFromQueue3(getReadyRegisterArgsQueue3(insMap, getIdQueue(array)));
       // always_comb bypassArgsReady = arrayFromQueue3(forwardStates);
    endgenerate


    always @(posedge AbstractCore.clk) begin
        TMP_incIssueCounter();

        rq_perArg = getReadyRegisterArgsQueue3(insMap, getIdQueue(array));// module var

        fq_perArg = forwardStates;                                    // module var
        rfq_perArg  = unifyReadyAndForwardsQ(rq_perArg, fq_perArg);   // module var
        rfq_perSlot = makeReadyQueue(rfq_perArg);                     // module var


        wMatrixVar = wMatrix; // for DB                               // module var


        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
           flushIq();
        end

        updateWakeups();    // rfq_perArg, wMatrixVar

            readinessVar = readiness;


        issue();

        if (!(lateEventInfo.redirect || branchEventInfo.redirect)) begin
            writeInput();
        end                
        
        removeIssuedFromArray();    
        
        foreach (pIssued0[i])
            pIssued1[i] <= tickP(pIssued0[i]);

        num <= getNumVirtual();     
        numUsed <= getNumUsed();
    end


    task automatic updateWakeups();    
        foreach (array[i])
            if (array[i].used) updateReadyBits(array[i], rfq_perArg[i], wMatrixVar[i], theExecBlock.memImagesTr[0]);
    endtask


    task automatic issue();
        UidQueueT validIds = getArrOpsToIssue();
        issueFromArray(validIds);
    endtask


    function automatic UidQueueT getArrOpsToIssue();
        UidQueueT res;
        UidQueueT idsSorted = getIdQueue(array);  // array
        idsSorted.sort with (U2M(item));

        if (!allow) return res;

        foreach (idsSorted[i]) begin
            UidT thisId = idsSorted[i];
        
            if (thisId == UIDT_NONE) continue;
            else begin
                int arrayLoc[$] = array.find_index with (item.uid == thisId); // array
                IqEntry entry = array[arrayLoc[0]];     // array
                logic ready = rfq_perSlot[arrayLoc[0]];     // rfq_perSlot
                logic active = entry.used && entry.active;

                    logic ready_N = readinessVar[arrayLoc[0]].all;
                    logic active_A = readinessVar[arrayLoc[0]].active;
                    logic used_A = readinessVar[arrayLoc[0]].used;
                    
                    assert (ready_N === ready) else $error("Different ready [%d]: %p, %p", arrayLoc[0], ready, ready_N);
                    assert (active_A === entry.active) else $error("Different active [%d]: %p, %p", arrayLoc[0], entry.active, active_A);
                    assert (used_A === entry.used) else $error("Different used [%d]: %p, %p", arrayLoc[0], entry.used, used_A);


                if (!active) continue;

                assert (entry.state.ready == ready) else $fatal(2, "differing ready bits\n%p", entry);  

                if (ready) res.push_back(thisId);
                else if (IN_ORDER) break;
                
                if (res.size() == OUT_WIDTH) break;
            end
            
        end
        
        return res;
    endfunction



    task automatic issueFromArray(input UidQueueT ids);
        pIssued0 <= '{default: EMPTY_UOP_PACKET};

        foreach (ids[i]) begin
            UidT theId = ids[i];
            int found[$] = array.find_first_index with (item.uid == theId);
            int s = found[0];
            
            Poison newPoison = mergePoisons(array[s].poisons.poisoned);
            UopPacket newPacket = '{1, theId, ES_OK, newPoison, 'x};

            pIssued0[i] <= tickP(newPacket);

            assert (theId != UIDT_NONE) else $fatal(2, "Wrong id for issue");
            assert (array[s].used && array[s].active) else $fatal(2, "Inactive slot to issue?");

            putMilestone(theId, InstructionMap::IqIssue);
  
            array[s].active = 0;
            array[s].issueCounter = 0;
        end
    endtask


    task automatic TMP_incIssueCounter();
        foreach (array[s])
            if (array[s].used && !array[s].active) array[s].issueCounter++;
    endtask

    task automatic removeIssuedFromArray();
        foreach (array[s]) begin
            if (array[s].issueCounter == HOLD_CYCLES) begin
                putMilestone(array[s].uid, InstructionMap::IqExit);
                                
                assert (array[s].used == 1 && array[s].active == 0) else $fatal(2, "slot to remove must be used and inactive");
                array[s] = EMPTY_ENTRY;
            end
        end
    endtask


    task automatic writeInput();
        InputLocs locs = getInputLocs();
        int nInserted = 0;

        foreach (inGroupU[i]) begin
            if (inGroupU[i].active) begin
                int location = locs[nInserted];
                UidT uid = inGroupU[i].uid;
                                
                array[location] = '{used: 1, active: 1, state: ZERO_ARG_STATE, poisons: DEFAULT_POISON_STATE, issueCounter: -1, uid: uid};
                putMilestone(uid, InstructionMap::IqEnter);

                nInserted++;          
            end
        end
    endtask


    task automatic flushIq();
        if (lateEventInfo.redirect) flushOpQueueAll();
        else if (branchEventInfo.redirect) flushOpQueuePartial(branchEventInfo.eventMid);
    endtask

    task automatic flushOpQueueAll();
        foreach (array[i]) begin
            if (array[i].used) putMilestone(array[i].uid, InstructionMap::IqFlush);
            array[i] = EMPTY_ENTRY;
        end
    endtask

    task automatic flushOpQueuePartial(input InsId id);
        foreach (array[i]) begin
            if (U2M(array[i].uid) > id) begin
                if (array[i].used) putMilestone(array[i].uid, InstructionMap::IqFlush);
                array[i] = EMPTY_ENTRY;
            end
        end
    endtask

    function automatic InputLocs getInputLocs();
        InputLocs res = '{default: -1};
        int nFound = 0;

        foreach (array[i])
            if (!array[i].used) res[nFound++] = i;

        return res;
    endfunction


    function automatic void updateReadyBits(ref IqEntry entry, input logic3 ready3, input Wakeup wup[3], input ForwardingElement memStage0[N_MEM_PORTS]);                
        foreach (ready3[a]) begin
            if (ready3[a] && !entry.state.readyArgs[a]) begin // handle wakeup
                setArgReady(entry, a, wup[a]);
            end
        end

        if (entry.state.readyArgs.and()) begin
            if (!entry.state.ready) putMilestone(entry.uid, InstructionMap::IqWakeupComplete);
            entry.state.ready = 1;
        end
        
        
        foreach (ready3[a]) begin
            // Check for args to cancel.
            // CAREFUL: it seems this can't apply to arg that is being woken up now, because wakeup is suppressed if poisoned by failing op.
            if (entry.state.readyArgs[a] && shouldFlushPoison(entry.poisons.poisoned[a])) begin // handle retraction if applies
                pullbackEntry(entry);
                cancelArg(entry, a);
            end
        end
    endfunction

    
    function automatic int getNumUsed();
        int res = 0;
        foreach (array[s]) if (array[s].used) res++; 
        return res; 
    endfunction

    function automatic int getNumVirtual();
        int res = 0;
        foreach (array[s]) if (array[s].used && array[s].issueCounter == -1) res++; 
        return res; 
    endfunction


    function automatic UidQueueT getIdQueue(input IqEntry entries[TOTAL_SIZE]);
        UidT res[$];
        
        foreach (entries[i]) begin
            UidT uid = entries[i].used ? entries[i].uid : UIDT_NONE;
            res.push_back(uid);
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

    function automatic WakeupMatrix getForwards(input IqEntry arr[TOTAL_SIZE]);
        WakeupMatrix res;
        foreach (arr[i]) res[i] = getForwardsForOp(arr[i], theExecBlock.memImagesTr[0]);
        
        return res;
    endfunction

    function automatic ReadyQueue3 fwFromWups(input WakeupMatrix wm, input UidT ids[$]);
        ReadyQueue3 res;
        foreach (wm[i]) begin
            logic3 r3 = '{'z, 'z, 'z};

            if (ids[i] != UIDT_NONE)
                foreach (r3[a]) r3[a] = wm[i][a].active;

            res.push_back(r3);
        end
        
        return res;
    endfunction



    function automatic void setArgReady(ref IqEntry entry, input int a, input Wakeup wup);
        entry.state.readyArgs[a] = 1;
        entry.poisons.poisoned[a] = wup.poison;

        if (a == 0) putMilestone(entry.uid, InstructionMap::IqWakeup0);
        else if (a == 1) putMilestone(entry.uid, InstructionMap::IqWakeup1);
        else if (a == 2) putMilestone(entry.uid, InstructionMap::IqWakeup2);
    endfunction

    function automatic void cancelArg(ref IqEntry entry, input int a);
        entry.state.readyArgs[a] = 0;
        entry.poisons.poisoned[a] = EMPTY_POISON;

        if (a == 0) putMilestone(entry.uid, InstructionMap::IqCancelWakeup0);
        else if (a == 1) putMilestone(entry.uid, InstructionMap::IqCancelWakeup1);
        else if (a == 2) putMilestone(entry.uid, InstructionMap::IqCancelWakeup2);
    endfunction

    function automatic void pullbackEntry(ref IqEntry entry);
        if (entry.state.ready) putMilestone(entry.uid, InstructionMap::IqPullback);

        // cancel issue
        entry.active = 1;
        entry.issueCounter = -1;                    
        entry.state.ready = 0;
    endfunction


        function automatic ReadyArray arrayFromQueue(input ReadyQueue rq);
            return rq[0:TOTAL_SIZE-1];
        endfunction

        function automatic ReadyArray3 arrayFromQueue3(input ReadyQueue3 rq3);
            return rq3[0:TOTAL_SIZE-1];
        endfunction

        // MOVE?
        // Duplicate of original in IssueQueueComplex!
        function automatic logic3 TMP_getReadyRegisterArgsForUid(input InstructionMap imap, input UidT uid);
            if (uid == UIDT_NONE) return '{'z, 'z, 'z};
            else begin
                InsDependencies deps = imap.getU(uid).deps;
                return checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);
            end
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

                if (isLoadUop(uname) || isStoreUop(uname)) res.mem[i] = '{1, uid};
                else if (isStoreDataUop(uname)) res.storeData[i] = '{1, uid};
                else if (isBranchUop(uname)) res.branch[i] = '{1, uid};
                else if (isFloatCalcUop(uname)) res.float[i] = '{1, uid};
                else if (isIntDividerUop(uname)) res.divider[i] = '{1, uid};
                else res.regular[i] = '{1, uid};
            end
        end
        
        return res;
    endfunction


    RoutedUops routedUops;
    
    UopPacket issuedRegularP[2];
    UopPacket issuedDividerP[1];
    UopPacket issuedBranchP[1];
    UopPacket issuedFloatP[2];
    UopPacket issuedMemP[1];
    UopPacket issuedStoreDataP[1];


    assign routedUops = routeUops(inGroup); 


    IssueQueue#(.OUT_WIDTH(2)) regularQueue(insMap, branchEventInfo, lateEventInfo, routedUops.regular, '1,
                                            issuedRegularP);

    IssueQueue#(.OUT_WIDTH(1)) dividerQueue(insMap, branchEventInfo, lateEventInfo, routedUops.divider, '1,
                                            issuedDividerP);                                            
                                            
    IssueQueue#(.OUT_WIDTH(1)) branchQueue(insMap, branchEventInfo, lateEventInfo, routedUops.branch, '1,
                                            issuedBranchP);
                                            
    IssueQueue#(.OUT_WIDTH(2)) floatQueue(insMap, branchEventInfo, lateEventInfo, routedUops.float, '1,
                                            issuedFloatP);
    IssueQueue#(.OUT_WIDTH(1)) memQueue(insMap, branchEventInfo, lateEventInfo, routedUops.mem, '1,
                                            issuedMemP);
    IssueQueue#(.OUT_WIDTH(1)) storeDataQueue(insMap, branchEventInfo, lateEventInfo, routedUops.storeData, '1,
                                            issuedStoreDataP);


    function automatic ReadyQueue3 getReadyRegisterArgsQueue3(input InstructionMap imap, input UidT ids[$]);
        ReadyQueue3 res;
        foreach (ids[i])
            res.push_back(getReadyRegisterArgsForUid(imap, ids[i]));        
//            if (ids[i] == UIDT_NONE) res.push_back('{'z, 'z, 'z});
//            else begin
//                InsDependencies deps = imap.getU(ids[i]).deps;
//                logic3 ra = checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);
//                res.push_back(ra);
//            end
        return res;
    endfunction


        function automatic logic3 getReadyRegisterArgsForUid(input InstructionMap imap, input UidT uid);
            if (uid == UIDT_NONE) return '{'z, 'z, 'z};
            else begin
                InsDependencies deps = imap.getU(uid).deps;
                return checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);
            end
        endfunction

endmodule
