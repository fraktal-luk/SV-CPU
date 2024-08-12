
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
    output OpPacket outPackets[OUT_WIDTH]
);
    localparam int IN_SIZE = $size(OpSlotA);

    localparam int HOLD_CYCLES = 3;
    localparam int N_HOLD_MAX = (HOLD_CYCLES+1) * OUT_WIDTH;
    localparam int TOTAL_SIZE = SIZE + N_HOLD_MAX;

    typedef int InputLocs[$size(OpSlotA)];

    typedef InsId IdArr[TOTAL_SIZE];
    typedef InsId OutIds[OUT_WIDTH];

    typedef OpPacket OutGroupP[OUT_WIDTH];
 

    IqEntry array[TOTAL_SIZE] = '{default: EMPTY_ENTRY};

    ReadyQueue  rfq_perSlot;
    ReadyQueue3 forwardStates, rq_perArg, fq_perArg, rfq_perArg;
    logic forwardInitialStates[IN_SIZE][3], forwardInitialStates_D[IN_SIZE][3];

        logic TMP_initialFw[IN_SIZE][3];


    IdArr ida;

    OpPacket pIssued0[OUT_WIDTH] = '{default: EMPTY_OP_PACKET};
    OpPacket pIssued1[OUT_WIDTH] = '{default: EMPTY_OP_PACKET};

    int num = 0, numUsed = 0;    
        
    //InputLocs newLocs;


    typedef Wakeup Wakeup3[3];
    typedef Wakeup WakeupInitial[IN_SIZE][3];
    typedef Wakeup WakeupMatrix[TOTAL_SIZE][3];

    WakeupInitial wInitial;
    WakeupMatrix wMatrix;


    logic cmpb, cmpb0, cmpb1;

    
    always_comb wInitial = getInitialForwards(inGroup, inMask);
    always_comb forwardInitialStates = fwFromInitialWups(wInitial, inMask);
    
    always_comb wMatrix = getForwards(array);
    always_comb forwardStates = fwFromWups(wMatrix, getIdQueue(array));

    assign outPackets = pIssued0;

         always_comb cmpb = (TMP_initialFw === forwardInitialStates);
            

    always @(posedge AbstractCore.clk) begin
            cmpb1 = cmpb;

                forwardInitialStates_D = forwardInitialStates;

        TMP_incIssueCounter();

        rq_perArg = getReadyQueue3(insMap, getIdQueue(array));
               
        fq_perArg = forwardStates;
        rfq_perArg  = unifyReadyAndForwardsQ(rq_perArg, fq_perArg);
        rfq_perSlot = makeReadyQueue(rfq_perArg);


        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
           flushIq();
        end

        updateWakeups();
        

        issue();

        removeIssuedFromArray();
      
      
            TMP_initialFw = '{default: dummy3};
      
        if (!(lateEventInfo.redirect || branchEventInfo.redirect)) begin
            writeInput();
        end                
        
        
        foreach (pIssued0[i])
            pIssued1[i] <= tickP(pIssued0[i]);

      
        num <= getNumVirtual();     
        numUsed <= getNumUsed();
             
        ida = q2a(getIdQueue(array));
    end




    function automatic IdQueue getValidIds(input OutIds outs);
        IdQueue res;
        foreach (outs[i]) if (outs[i] != -1) res.push_back(outs[i]);
        return res;
    endfunction


    task automatic issue();
        OutIds ov = getArrOpsToIssue();
        IdQueue validIds = getValidIds(ov);        
        issueFromArray(validIds);
    endtask


    function automatic ReadyQueue3 fwFromWups(input WakeupMatrix wm, input InsId ids[$]);
        ReadyQueue3 res;
        foreach (wm[i]) begin
            Wakeup3 w3 = wm[i];
            logic3 r3;
            
            if (ids[i] == -1) begin
                res.push_back('{'z, 'z, 'z});
                continue;
            end
            
            foreach (w3[a]) begin
                r3[a] = w3[a].active;
            end
            res.push_back(r3);
        end
        
        return res;
    endfunction

    function automatic ReadyQueue3 fwFromInitialWups(input WakeupInitial wi, input logic im[$size(OpSlotA)]);
        ReadyQueue3 res;
        foreach (wi[i]) begin
            Wakeup3 w3 = wi[i];
            logic3 r3;
            
            if (!im[i]) begin
                res.push_back('{'z, 'z, 'z});
                continue;
            end
            
            foreach (w3[a]) begin
                r3[a] = w3[a].active;
            end
            res.push_back(r3);
        end
        
        return res;
    endfunction


    // ONCE
    function automatic OpPacket convertOutput(/*input OpSlot op,*/ input InsId id);
        OpPacket res;        
        res = '{1, id, DEFAULT_POISON, 'x};  
        return res;
    endfunction


    task automatic issueFromArray(input IdQueue ids);
        pIssued0 <= '{default: EMPTY_OP_PACKET};

        foreach (ids[i]) begin
            InsId theId = ids[i];
            
            int found[$] = array.find_first_index with (item.id == theId);
            int s = found[0];
            
            assert (ids[i] != -1) else $error("Wrong id for issue");
            
            pIssued0[i] <= tickP(convertOutput(theId));

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
                logic readyF = rfq_perSlot[arrayLoc[0]];
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
            logic3 rf3 = rfq_perArg[i];
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
                //InsDependencies deps = insMap.get(op.id).deps;
//                logic3 ra = checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);
//                logic3 raf = checkForwardsReadyAll(insMap, AbstractCore.theExecBlock.allByStage, deps);//, stages);
//                logic3 raAll = '{ ra[0] | raf[0], ra[1] | raf[1], ra[2] | raf[2] } ;

//                    TMP_initialFw[i] = raf;

                array[location] = '{used: 1, active: 1, state: ZERO_ARG_STATE, poisons: DEFAULT_POISON_STATE, issueCounter: -1, id: op.id};
                putMilestone(op.id, InstructionMap::IqEnter);

                //updateReadyBitsF(array[location], raAll);

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
    
    

    function automatic Wakeup3 getForwardsForOp(input IqEntry entry);
        Wakeup3 res = '{default: EMPTY_WAKEUP};
        if (entry.id == -1) return res;
        
        foreach (entry.state.readyArgsF[a]) begin
            InsDependencies deps = insMap.get(entry.id).deps;
            SourceType argType = deps.types[a];
            int prod = deps.producers[a];
            int source = deps.sources[a];
            
            Wakeup wup = checkForwardSourceInt(insMap, prod, source, AbstractCore.theExecBlock.intImages);
            if (!wup.active) wup = checkForwardSourceVec(insMap, prod, source, AbstractCore.theExecBlock.floatImages);
            // CAREFUL: Not using mem pipe forwarding for FP to simplify things
            if (!wup.active && argType != SRC_FLOAT) wup = checkForwardSourceMem(insMap, prod, source, AbstractCore.theExecBlock.memImages);
            
            if (wup.active) res[a] = wup;
        end
        return res;
    endfunction

    function automatic WakeupMatrix getForwards(input IqEntry arr[TOTAL_SIZE]);
        WakeupMatrix res;
    
        foreach (arr[i]) begin
            IqEntry entry = arr[i];
            Wakeup3 w3 = getForwardsForOp(entry);
            res[i] = w3;
        end
        
        return res;
    endfunction

    function automatic WakeupInitial getInitialForwards(input OpSlotA arr, input logic im[$size(OpSlotA)]);
        WakeupInitial res;
    
        foreach (arr[i]) begin
            IqEntry entry = '{used: arr[i].active, active: arr[i].active, state: ZERO_ARG_STATE, poisons: DEFAULT_POISON_STATE, issueCounter: -1, id: arr[i].id};
            Wakeup3 w3 = '{default: EMPTY_WAKEUP};
            if (arr[i].active && im[i]) w3 = getForwardsForOp(entry);
            res[i] = w3;
        end
        
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
    
    OpPacket issuedRegularP[2];
    OpPacket issuedFloatP[2];
    OpPacket issuedMemP[1];
    OpPacket issuedSysP[1];
    OpPacket issuedBranchP[1];   
    
    
    IssueQueue#(.OUT_WIDTH(2)) regularQueue(insMap, branchEventInfo, lateEventInfo, inGroup, regularMask,
                                            issuedRegularP);
    IssueQueue#(.OUT_WIDTH(2)) floatQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.float,
                                            issuedFloatP);
    IssueQueue#(.OUT_WIDTH(1)) branchQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.branch,
                                            issuedBranchP);
    IssueQueue#(.OUT_WIDTH(1)) memQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.mem,
                                            issuedMemP);
    IssueQueue#(.OUT_WIDTH(1)) sysQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.sys,
                                            issuedSysP);
    
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


endmodule
