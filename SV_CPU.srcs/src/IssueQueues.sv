
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
    input OpSlotA inGroup,
    input logic inMask[$size(OpSlotA)],
    
    output OpSlot outGroup[OUT_WIDTH],
    output OpPacket outPackets[OUT_WIDTH]
);

    localparam int HOLD_CYCLES = 3;

    localparam int N_HOLD_MAX = (HOLD_CYCLES+1) * OUT_WIDTH;
    localparam int TOTAL_SIZE = SIZE + N_HOLD_MAX;

    typedef int InputLocs[$size(OpSlotA)];

    
    typedef InsId IdArr[TOTAL_SIZE];
    typedef logic logicArr[TOTAL_SIZE];


    IqEntry array[TOTAL_SIZE] = '{default: EMPTY_ENTRY};

    logicArr readyTotal, readyTotalF;
    ReadyQueue  readyQueue, rfq;
    ReadyQueue3 rq3, readyOrForwardQ3;
    ReadyQueue3 fmq[-3:1] = FORWARDING_ALL_Z;

    IdArr ida;
    IdArr sortedIds = '{default: -1}, sortedReadyArr = '{default: -1}, sortedReadyArrF = '{default: -1};

    typedef InsId OutIds[OUT_WIDTH];
    OutIds iss_new, iss_newF; // TMP

    OpSlot issued[OUT_WIDTH] = '{default: EMPTY_SLOT};
    OpSlot issued1[OUT_WIDTH] = '{default: EMPTY_SLOT};

    int num = 0, numUsed = 0;
    

    logic cmpb, cmpb0, cmpb1;


    assign outGroup = issued;
    assign outPackets = '{default: EMPTY_OP_PACKET};


    always @(posedge AbstractCore.clk) begin
        TMP_incIssueCounter();
    
        rq3 = getReadyQueue3(insMap, getIdQueue(array));
        readyQueue = makeReadyQueue(rq3);
   
        foreach (fmq[i]) fmq[i] = getForwardQueue3(insMap, getIdQueue(array), i);
        
        readyOrForwardQ3 = gatherReadyOrForwardsQ(rq3, fmq);
        rfq = makeReadyQueue(readyOrForwardQ3);


        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
           flushIq();
        end
        
        updateWakeups();
        
        issue();

        removeIssuedFromArray();
      
        if (!(lateEventInfo.redirect || branchEventInfo.redirect)) begin
            writeInput();
        end
        
        // TODO: check arg status of newly written ops, note wakeups if ready
                
        
        foreach (issued[i])
            issued1[i] <= tick(issued[i]);
        
        num <= getNumVirtual();     
        numUsed <= getNumUsed();
             
        ida = q2a(getIdQueue(array));
    end


    function automatic OpSlotQueue getOpsFromIds(input OutIds outs);
        OpSlotQueue res;
        
        foreach (outs[i])
            if (outs[i] != -1) begin
                InstructionInfo ii = insMap.get(outs[i]);
                res.push_back('{1, ii.id, ii.adr, ii.bits});
            end
        return res;
    endfunction

    task automatic issue();
        OutIds ov = getArrOpsToIssue();
        OpSlot ops[$] = getOpsFromIds(ov);
        
        issueFromArray(ops);
    endtask


    task automatic issueFromArray(input OpSlot ops[$]);
        issued <= '{default: EMPTY_SLOT};

        foreach (ops[i]) begin
            OpSlot op = ops[i];
            issued[i] <= tick(op);

            foreach (array[s]) begin
                if (array[s].id == op.id) begin
                    putMilestone(op.id, InstructionMap::IqIssue);
                    assert (array[s].used == 1 && array[s].active == 1) else $fatal(2, "Inactive slot to issue?");
                    array[s].active = 0;
                    array[s].issueCounter = 0;
                    break;
                end
            end
        end
    endtask

    task automatic removeIssuedFromArray();
        foreach (array[s]) begin
            if (array[s].issueCounter == HOLD_CYCLES) begin
                putMilestone(array[s].id, InstructionMap::IqExit);
                assert (array[s].used == 1 && array[s].active == 0) else $fatal(2, "slot to remove must be used and inactive");
                array[s] = EMPTY_ENTRY;
            end
        end
    endtask


    function automatic OutIds getArrOpsToIssue();
        int nNoF = 0, nF = 0;
    
        OutIds res = '{default: -1};
        IdArr sortedReady = '{default: -1};
        IdArr sortedReadyF = '{default: -1};
    
        IdQueue ids = getIdQueue(array);
        IdQueue idsSorted = ids;
        idsSorted.sort();
        
        sortedIds = idsSorted[0:TOTAL_SIZE-1];
        
        iss_new = '{default: -1};
        iss_newF = '{default: -1};

        foreach (idsSorted[i]) begin
            if (idsSorted[i] == -1) continue;
            else begin
                int arrayLoc[$] = array.find_index with (item.id == idsSorted[i]);
                logic ready = readyQueue[arrayLoc[0]]; 
                logic readyF = rfq[arrayLoc[0]];
                
                readyTotal[i] = ready;
                readyTotalF[i] = readyF;
            end
        end

        foreach (idsSorted[i]) begin
            if (idsSorted[i] == -1) continue;
            else begin
                int arrayLoc[$] = array.find_index with (item.id == idsSorted[i]);
                IqEntry entry = array[arrayLoc[0]]; 
                logic ready = readyQueue[arrayLoc[0]]; 
                logic readyF = rfq[arrayLoc[0]];
                
                logic active = entry.used && entry.active;
                
                if (active && ready) begin
                        assert (entry.state.ready) else $error("Not marked ready!");
                    sortedReady[i] = idsSorted[i];
                    iss_new[nNoF++] = idsSorted[i];
                end
                else begin
                    sortedReady[i] = -1;
                    if (IN_ORDER && active) break;
                end

            end
        end

        foreach (idsSorted[i]) begin
            if (idsSorted[i] == -1) continue;
            else begin
                int arrayLoc[$] = array.find_index with (item.id == idsSorted[i]);
                IqEntry entry = array[arrayLoc[0]]; 
                logic ready = readyQueue[arrayLoc[0]]; 
                logic readyF = rfq[arrayLoc[0]];

                logic ready_S = entry.state.ready; 
                logic readyF_S = entry.state.readyF;

                logic active = entry.used && entry.active;
                
                assert (ready_S == ready && readyF_S == readyF) else $error("differing ready bits");  

                if (active && readyF) begin
                    sortedReadyF[i] = idsSorted[i];
                    iss_newF[nF++] = idsSorted[i];
                end
                else begin
                    sortedReadyF[i] = -1;
                    if (IN_ORDER && active) break;
                end
            end
        end

        sortedReadyArr = sortedReady;
        sortedReadyArrF = sortedReadyF;

        res = USE_FORWARDING ? iss_newF : iss_new;
        
        return res;
    endfunction


    task automatic updateWakeups();
        foreach (array[i]) begin
            logic3 r3 = rq3[i];
            logic3 rf3 = readyOrForwardQ3[i];

            if (!array[i].used) continue;
            
            updateReadyBits(array[i], r3);
            updateReadyBitsF(array[i], rf3);
        end
    endtask


    task automatic flushIq();
        if (lateEventInfo.redirect) flushOpQueueAll();
        else if (branchEventInfo.redirect) flushOpQueuePartial(branchEventInfo.op);
    endtask

    task automatic flushOpQueueAll();
        foreach (array[i]) begin
            if (array[i].used) putMilestone(array[i].id, InstructionMap::IqFlush);
            array[i] = EMPTY_ENTRY;
        end
    endtask

    task automatic flushOpQueuePartial(input OpSlot op);
        foreach (array[i]) begin
            if (array[i].id > op.id) begin
                if (array[i].used) putMilestone(array[i].id, InstructionMap::IqFlush);
                array[i] = EMPTY_ENTRY;
            end
        end
    endtask

    function automatic InputLocs getInputLocs();
        InputLocs res = '{default: -1};
        int nFound = 0;

        foreach (array[i]) begin
            if (!array[i].used) res[nFound++] = i;
        end

        return res;
    endfunction


    task automatic writeInput();
        InputLocs locs = getInputLocs();
        int nInserted = 0;
        
        int stages[] = '{-3, -2, -1, 0, 1};
        
        foreach (inGroup[i]) begin
            OpSlot op = inGroup[i];
            if (op.active && inMask[i]) begin
                int location = locs[nInserted];
                InsDependencies deps = insMap.get(op.id).deps;
                logic3 ra = checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);
                logic3 raf = checkForwardsReadyAll(insMap, AbstractCore.theExecBlock.allByStage, deps, stages);
                logic3 raAll = '{ ra[0] | raf[0], ra[1] | raf[1], ra[2] | raf[2] } ;

                array[location] = '{used: 1, active: 1, state: ZERO_ARG_STATE, poisons: DEFAULT_POISON_STATE, issueCounter: -1, id: op.id};
                putMilestone(op.id, InstructionMap::IqEnter);

                updateReadyBits(array[location], ra);
                updateReadyBitsF(array[location], raAll);
            
                nInserted++;          
            end
        end
    endtask


        function automatic void updateReadyBits(ref IqEntry entry, input logic3 ready3);
            foreach (ready3[a]) begin
                if (ready3[a]) begin
                    logic prev = entry.state.readyArgs[a]; // Always 0 because this is a new slot
                    entry.state.readyArgs[a] = 1;
                    if (a == 0 && !prev && !USE_FORWARDING) putMilestone(entry.id, InstructionMap::IqWakeup0);
                    else if (a == 1 && !prev && !USE_FORWARDING) putMilestone(entry.id, InstructionMap::IqWakeup1);
                end

            end
            
            if (entry.state.readyArgs.and()) begin
                logic prev = entry.state.ready;
                entry.state.ready = 1;
                if (!prev && !USE_FORWARDING) putMilestone(entry.id, InstructionMap::IqWakeupComplete);
            end
        endfunction


        function automatic void updateReadyBitsF(ref IqEntry entry, input logic3 ready3);
            InsDependencies deps = insMap.get(entry.id).deps;

            foreach (ready3[a]) begin
            
                if (ready3[a]) begin
                    InsId producer = (deps.producers[a]);

                    logic prev = entry.state.readyArgsF[a]; // Always 0 because this is a new slot
                    entry.state.readyArgsF[a] = 1;
                    
                    if (!prev && USE_FORWARDING) begin end
                    else continue;
                    
                    if (a == 0) begin
                        putMilestone(entry.id, InstructionMap::IqWakeup0);
                    end
                    else if (a == 1) begin
                        putMilestone(entry.id, InstructionMap::IqWakeup1);
                    end
                    
                    // Poisons:
                    if (isLoadIns(insMap.get(producer).dec)) begin
                        
                    end
                end

            end
            
            if (entry.state.readyArgsF.and()) begin
                logic prev = entry.state.readyF;
                entry.state.readyF = 1;
                if (!prev && USE_FORWARDING) putMilestone(entry.id, InstructionMap::IqWakeupComplete);
            end
        endfunction


    task automatic TMP_incIssueCounter();
        foreach (array[s]) begin
            if (array[s].used == 1 && array[s].active == 0) begin
                array[s].issueCounter++;
            end
        end
    endtask

    
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


    function automatic IdQueue getIdQueue(input IqEntry entries[$size(array)]);
        InsId res[$];
        
        foreach (entries[i]) begin
            InsId id = entries[i].used ? entries[i].id : -1;
            res.push_back(id);
        end
        
        return res;
    endfunction
    
    
    function automatic IdArr q2a(input IdQueue queue);
        IdArr res = queue[0:$size(array)-1];
        return res;
    endfunction
    
endmodule



module IssueQueueComplex(
                        ref InstructionMap insMap,
                        input EventInfo branchEventInfo,
                        input EventInfo lateEventInfo,
                        input OpSlotA inGroup
);

    localparam int IN_WIDTH = $size(inGroup);


    logic regularMask[IN_WIDTH];
    OpSlot issuedRegular[2];
    OpSlot issuedFloat[2];
    OpSlot issuedMem[1];
    OpSlot issuedSys[1];
    OpSlot issuedBranch[1];
    
    OpPacket issuedRegularP[2];
    OpPacket issuedFloatP[2];
    OpPacket issuedMemP[1];
    OpPacket issuedSysP[1];
    OpPacket issuedBranchP[1];   
    
    
    IssueQueue#(.OUT_WIDTH(2)) regularQueue(insMap, branchEventInfo, lateEventInfo, inGroup, regularMask,
                                            issuedRegular, issuedRegularP);
    IssueQueue#(.OUT_WIDTH(2)) floatQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.float,
                                            issuedFloat, issuedFloatP);
    IssueQueue#(.OUT_WIDTH(1)) branchQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.branch,
                                            issuedBranch, issuedBranchP);
    IssueQueue#(.OUT_WIDTH(1)) memQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.mem,
                                            issuedMem, issuedMemP);
    IssueQueue#(.OUT_WIDTH(1)) sysQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.sys,
                                            issuedSys, issuedSysP);
    
    typedef struct {
        logic regular[IN_WIDTH];
        logic float[IN_WIDTH];
        logic branch[IN_WIDTH];
        logic mem[IN_WIDTH];
        logic sys[IN_WIDTH];
    } RoutingInfo;
    
    const RoutingInfo DEFAULT_ROUTING_INFO = '{
        regular: '{default: 0},
        float: '{default: 0},
        branch: '{default: 0},
        mem: '{default: 0},
        sys: '{default: 0}
    };
    
    RoutingInfo routingInfo;
    
    assign routingInfo = routeOps(inGroup); 
    assign regularMask = routingInfo.regular;


    function automatic RoutingInfo routeOps(input OpSlotA gr);
        RoutingInfo res = DEFAULT_ROUTING_INFO;
        
        foreach (gr[i]) begin
            OpSlot op = gr[i];
            
            if (isLoadIns(decAbs(op)) || isStoreIns(decAbs(op))) res.mem[i] = 1;
            else if (isSysIns(decAbs(op))) res.sys[i] = 1;
            else if (isBranchIns(decAbs(op))) res.branch[i] = 1;
            else if (isFloatCalcIns(decAbs(op))) res.float[i] = 1;
            else res.regular[i] = 1;
        end
        
        return res;
    endfunction


    function automatic ReadyQueue3 getReadyQueue3(input InstructionMap imap, input InsId ids[$]);
        logic D3[3] = '{'z, 'z, 'z};
        ReadyQueue3 res;
        foreach (ids[i])
            if (ids[i] == -1) res.push_back(D3);
            else
            begin
                InsDependencies deps = imap.get(ids[i]).deps;
                logic3 ra = checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);
                res.push_back(ra);
            end
        return res;
    endfunction
    
    function automatic ReadyQueue3 getForwardQueue3(input InstructionMap imap, input InsId ids[$], input int stage);
        logic D3[3] = '{'z, 'z, 'z};
        ReadyQueue3 res;
        foreach (ids[i])
            if (ids[i] == -1) res.push_back(D3);
            else
            begin
                InsDependencies deps = imap.get(ids[i]).deps;
                logic3 ra = checkForwardsReady(imap, AbstractCore.theExecBlock.allByStage, deps, stage);
                res.push_back(ra);
            end
        return res;
    endfunction

    function automatic ReadyQueue3 getForwardQueueAll3(input InstructionMap imap, input InsId ids[$]);
        logic D3[3] = '{'z, 'z, 'z};
        int stages[] = '{-3, -2, -1, 0, 1};
        ReadyQueue3 res ;
        foreach (ids[i]) 
            if (ids[i] == -1) res.push_back(D3);
            else
            begin                
                InsDependencies deps = imap.get(ids[i]).deps;
                logic3 ra = checkForwardsReadyAll(imap, AbstractCore.theExecBlock.allByStage, deps, stages);
                res.push_back(ra);
            end
        return res;
    endfunction



endmodule
