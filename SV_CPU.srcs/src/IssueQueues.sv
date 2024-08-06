
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
    typedef InsId OutIds[OUT_WIDTH];

    typedef OpPacket OutGroupP[OUT_WIDTH];
 
    //typedef logic logicArr[TOTAL_SIZE];


    IqEntry array[TOTAL_SIZE] = '{default: EMPTY_ENTRY};

    ReadyQueue  readyQueue, rfq;
    ReadyQueue3 rq3, readyOrForwardQ3;
    ReadyQueue3 fmq[-3:1] = FORWARDING_ALL_Z;

    IdArr ida;

    OpSlot issued[OUT_WIDTH] = '{default: EMPTY_SLOT};
    OpSlot issued1[OUT_WIDTH] = '{default: EMPTY_SLOT};

    OpPacket pIssued0[OUT_WIDTH] = '{default: EMPTY_OP_PACKET};
    OpPacket pIssued1[OUT_WIDTH] = '{default: EMPTY_OP_PACKET};


    int num = 0, numUsed = 0;
    
        Wakeup wakeups_TMP[TOTAL_SIZE][2];
        
        InputLocs newLocs;

    logic cmpb, cmpb0, cmpb1;


    //assign outGroup = issued;
    assign outPackets = //convertOutputG(issued);
                        pIssued0;


        assign cmpb0 = (outPackets[0] === pIssued0[0]);
        assign cmpb  = (outPackets === pIssued0);


    function automatic OutGroupP convertOutputG(input OpSlot outGroup[OUT_WIDTH]);
        OutGroupP res;
        
        foreach (outGroup[i])
            res[i] = outGroup[i].active ? '{1, outGroup[i].id, DEFAULT_POISON, 'x} : EMPTY_OP_PACKET;
            
        return res;
    endfunction




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
        
        
            TMP_showWakeups();

        updateWakeups();
        
        issue();

        removeIssuedFromArray();
      
            newLocs = getInputLocs();
      
        if (!(lateEventInfo.redirect || branchEventInfo.redirect)) begin
            writeInput();
        end                
        
        foreach (issued[i])
            issued1[i] <= tick(issued[i]);

        foreach (pIssued0[i])
            pIssued1[i] <= tickP(pIssued0[i]);
      
      
        num <= getNumVirtual();     
        numUsed <= getNumUsed();
             
        ida = q2a(getIdQueue(array));
    end


    function automatic OpSlot getOpFromId(input InsId id);
        OpSlot res;
        //if (id != -1) begin
            InstructionInfo ii = insMap.get(id);
            res = '{1, ii.id, ii.adr, ii.bits};
        //end
        return res;
    endfunction
    

//    function automatic OpSlotQueue getOpsFromIds(input OutIds outs);
//        OpSlotQueue res;
        
//        foreach (outs[i])
//            if (outs[i] != -1) begin
//                InstructionInfo ii = insMap.get(outs[i]);
//                res.push_back('{1, ii.id, ii.adr, ii.bits});
//            end
//        return res;
//    endfunction

    function automatic IdQueue getValidIds(input OutIds outs);
        IdQueue res;
        foreach (outs[i]) if (outs[i] != -1) res.push_back(outs[i]);
        return res;
    endfunction


    task automatic issue();
        OutIds ov = getArrOpsToIssue();
        IdQueue validIds = getValidIds(ov);
        //OpSlot ops[$] = getOpsFromIds(ov);
        
        issueFromArray(/*ops,*/ validIds);
    endtask


    function automatic OpPacket convertOutput(input OpSlot op, input InsId id);
        OpPacket res;        
        res = //op.active ? 
                '{1, op.id, DEFAULT_POISON, 'x};// : EMPTY_OP_PACKET;
            
        return res;
    endfunction


    task automatic issueFromArray(//input OpSlot ops[$], 
                                    input IdQueue ids);
        issued <= '{default: EMPTY_SLOT};
        pIssued0 <= '{default: EMPTY_OP_PACKET};

        foreach (ids[i]) begin
            InsId theId = ids[i];

            OpSlot op = //ops[i];
                        getOpFromId(theId);
            
            int found[$] = array.find_first_index with (item.id == theId);
            int s = found[0];
            
            assert (ids[i] != -1) else $error("Wrong id for issue");
            assert (op.id == ids[i]) else $error("differin id for issue");
            
            issued[i] <= tick(op);
            pIssued0[i] <= tickP(convertOutput(op, theId));
              // pIssued0[i].poison = mergePoisons(array[s].poisons);

            putMilestone(theId, InstructionMap::IqIssue);
            assert (array[s].used == 1 && array[s].active == 1) else $fatal(2, "Inactive slot to issue?");
            array[s].active = 0;
            array[s].issueCounter = 0;
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
        int nF = 0;
        OutIds res = '{default: -1};
    
        IdQueue ids = getIdQueue(array);
        IdQueue idsSorted = ids;
        idsSorted.sort();

        foreach (idsSorted[i]) begin
            if (idsSorted[i] == -1) continue;
            else begin
                int arrayLoc[$] = array.find_index with (item.id == idsSorted[i]);
                IqEntry entry = array[arrayLoc[0]]; 
                logic readyF = rfq[arrayLoc[0]];
                logic readyF_S = entry.state.readyF;

                logic active = entry.used && entry.active;
                
                assert (readyF_S == readyF) else $fatal(2, "differing ready bits");  

                if (active && readyF) res[nF++] = idsSorted[i];
                else if (IN_ORDER && active) break;
            end
        end
        
        return res;
    endfunction


    task automatic updateWakeups();
        foreach (array[i]) begin
            logic3 rf3 = readyOrForwardQ3[i];
            if (array[i].used) updateReadyBitsF(array[i], rf3);
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

        foreach (inGroup[i]) begin
            OpSlot op = inGroup[i];
            if (op.active && inMask[i]) begin
                int location = locs[nInserted];
                InsDependencies deps = insMap.get(op.id).deps;
                logic3 ra = checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);
                logic3 raf = checkForwardsReadyAll(insMap, AbstractCore.theExecBlock.allByStage, deps);//, stages);
                logic3 raAll = '{ ra[0] | raf[0], ra[1] | raf[1], ra[2] | raf[2] } ;

                    TMP_showSlotWakeup(location);

                array[location] = '{used: 1, active: 1, state: ZERO_ARG_STATE, poisons: DEFAULT_POISON_STATE, issueCounter: -1, id: op.id};
                putMilestone(op.id, InstructionMap::IqEnter);

                updateReadyBitsF(array[location], raAll);

                nInserted++;          
            end
        end
    endtask



    function automatic void updateReadyBitsF(ref IqEntry entry, input logic3 ready3);
        InsDependencies deps = insMap.get(entry.id).deps;

        foreach (ready3[a]) begin
            if (ready3[a]) begin
                logic prev = entry.state.readyArgsF[a]; // Always 0 because this is a new slot
                entry.state.readyArgsF[a] = 1;

                if (prev) continue;

                if (a == 0) putMilestone(entry.id, InstructionMap::IqWakeup0);
                else if (a == 1) putMilestone(entry.id, InstructionMap::IqWakeup1);
            end

        end

        if (entry.state.readyArgsF.and()) begin
            logic prev = entry.state.readyF;
            entry.state.readyF = 1;
            if (!prev) putMilestone(entry.id, InstructionMap::IqWakeupComplete);
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
    
    
        // CAREFUL: only for int
        task automatic TMP_showSlotWakeup(input int i);
            IqEntry entry = array[i];
            
            wakeups_TMP[i] = '{default: EMPTY_WAKEUP};
            if (!entry.used) return;
            
            foreach (entry.state.readyArgsF[a]) begin
                InsDependencies deps = insMap.get(entry.id).deps;
                int prod = deps.producers[a];
                int source = deps.sources[a];
                
                Wakeup wup = checkForwardSourceInt(insMap, prod, source, AbstractCore.theExecBlock.intImages);
                if (!wup.active) wup = checkForwardSourceMem(insMap, prod, source, AbstractCore.theExecBlock.memImages);
                
                // If the arg was ready before, deactivate wakeup
                if (entry.state.readyArgsF[a]) wup.active = 0;
            
                wakeups_TMP[i][a] = wup;
            end
        endtask
    
    
    task automatic TMP_showWakeups();
        foreach (array[i]) begin
            TMP_showSlotWakeup(i);
        end
    endtask
 
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

        OpSlot issuedRegular_D[2];
        OpSlot issuedFloat_D[2];
        OpSlot issuedMem_D[1];
        OpSlot issuedSys_D[1];
        OpSlot issuedBranch_D[1];
    
    OpPacket issuedRegularP[2];
    OpPacket issuedFloatP[2];
    OpPacket issuedMemP[1];
    OpPacket issuedSysP[1];
    OpPacket issuedBranchP[1];   
    
    
    IssueQueue#(.OUT_WIDTH(2)) regularQueue(insMap, branchEventInfo, lateEventInfo, inGroup, regularMask,
                                            issuedRegular_D, issuedRegularP);
    IssueQueue#(.OUT_WIDTH(2)) floatQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.float,
                                            issuedFloat_D, issuedFloatP);
    IssueQueue#(.OUT_WIDTH(1)) branchQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.branch,
                                            issuedBranch_D, issuedBranchP);
    IssueQueue#(.OUT_WIDTH(1)) memQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.mem,
                                            issuedMem_D, issuedMemP);
    IssueQueue#(.OUT_WIDTH(1)) sysQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.sys,
                                            issuedSys_D, issuedSysP);
    
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
        ReadyQueue3 res;
        foreach (ids[i]) 
            if (ids[i] == -1) res.push_back(D3);
            else
            begin                
                InsDependencies deps = imap.get(ids[i]).deps;
                logic3 ra = checkForwardsReadyAll(imap, AbstractCore.theExecBlock.allByStage, deps);//, stages);
                res.push_back(ra);
            end
        return res;
    endfunction


endmodule
