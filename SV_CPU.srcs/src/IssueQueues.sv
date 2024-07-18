
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
    
    output OpSlot outGroup[OUT_WIDTH]
);

    localparam int HOLD_CYCLES = 3;

    OpSlot content[$:SIZE];
    ReadyVec readyVec, readyVec_A;
    ReadyVec3   ready3Vec, readyOrForward3Vec;
    ReadyVec3   forwardingMatches[-3:1] = FORWARDING_ALL_Z;

    ReadyQueue  rfq;
    ReadyQueue3 rq, readyOrForwardQ3;
    ReadyQueue3 fmq[-3:1];


    OpSlot issued[OUT_WIDTH] = '{default: EMPTY_SLOT};
    OpSlot issued1[OUT_WIDTH] = '{default: EMPTY_SLOT};

    int num = 0, numUsed = 0, numActive = 0;


        logic cmpb, cmpb0, cmpb1;

    
    typedef OpSlot OpSlotQueue[$];
    typedef int InputLocs[$size(OpSlotA)];

    typedef struct {
        logic used;
        logic active;
        logic ready;
            int issueCounter;
        InsId id;
    } IqEntry;

    typedef struct {
        InsId id;
        
    } IqArgState;



    localparam IqEntry EMPTY_ENTRY = '{used: 0, active: 0, ready: 0, issueCounter: -1, id: -1};
    localparam int N_HOLD_MAX = (HOLD_CYCLES+1) * OUT_WIDTH;

    IqEntry array[SIZE + N_HOLD_MAX] = '{default: EMPTY_ENTRY};

    typedef InsId IdQueue[$];
    typedef InsId IdArr[$size(array)];

    IdQueue idq;
    IdArr ida;


    assign outGroup = issued;


    always @(posedge AbstractCore.clk) begin
        TMP_incIssueCounter();
    
        ready3Vec = getReadyVec3(insMap, content);
            rq = getReadyQueue3(insMap, getIdQueue(array));
        
        foreach (forwardingMatches[i]) forwardingMatches[i] = getForwardVec3(insMap, content, i);         
             foreach (fmq[i]) fmq[i] = getForwardQueue3(insMap, getIdQueue(array), i);

        readyVec = makeReadyVec(ready3Vec);

        readyOrForward3Vec = gatherReadyOrForwards(ready3Vec, forwardingMatches);
        readyVec_A = makeReadyVec(readyOrForward3Vec);

            readyOrForwardQ3 = gatherReadyOrForwardsQ(rq, fmq);
            rfq = makeReadyQueue(readyOrForwardQ3);

        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
            flushIq();
            TMP_flushIq();
        end
        else begin
            writeInput();
            TMP_writeInput();
        end
        
        issue();
        
        
        foreach (issued[i])
            issued1[i] <= tick(issued[i]);
        
        num <= content.size();

            numUsed <= TMP_getNumUsed();
            numActive <= TMP_getNumActive();
             
            idq = getIdQueue(array);
            ida = q2a(idq);
    end


    task automatic flushIq();
        if (lateEventInfo.redirect) flushOpQueueAll();
        else if (branchEventInfo.redirect) flushOpQueuePartial(branchEventInfo.op);
    endtask

    task automatic flushOpQueueAll();
        while (content.size() > 0) begin
            OpSlot qOp = (content.pop_back());
            putMilestone(qOp.id, InstructionMap::IqFlush);
        end
    endtask

    task automatic flushOpQueuePartial(input OpSlot op);
        while (content.size() > 0 && content[$].id > op.id) begin
            OpSlot qOp = (content.pop_back());
            putMilestone(qOp.id, InstructionMap::IqFlush);
        end
    endtask

    task automatic writeInput();
        foreach (inGroup[i]) begin
            OpSlot op = inGroup[i];
            if (op.active && inMask[i]) begin
                content.push_back(op);
                putMilestone(op.id, InstructionMap::IqEnter);
            end
        end
    endtask

    task automatic issue();
        OpSlot ops[$];
        ops = getOpsToIssue();
        
        removeIssued(ops);
        
        TMP_markIssuedInArray();
        
        TMP_issueFromArray(ops);
    endtask

    task automatic removeIssued(input OpSlot ops[$]);
        foreach (ops[i]) begin
            OpSlot op = ops[i];
            issued[i] <= tick(op);
            markOpIssued(op);
            
            void'(content.pop_front());
        end
    endtask 


    function automatic OpSlotQueue getOpsToIssue();
        OpSlot ops[$];
        int n = OUT_WIDTH > num ? num : OUT_WIDTH;
        if (content.size() < n) n = content.size();

        issued <= '{default: EMPTY_SLOT};

        foreach (issued[i]) begin        
            if (i < n && readyVec[i]) // TODO: switch to readyVec_A when ready
                ops.push_back( content[i]);
            else
                break;
        end
        
        return ops;
    endfunction
  

    function automatic void markOpIssued(input OpSlot op);        
        putMilestone(op.id, InstructionMap::IqIssue);
        putMilestone(op.id, InstructionMap::IqExit);
    endfunction

////////////////////////////

    task automatic TMP_flushIq();
        if (lateEventInfo.redirect) TMP_flushOpQueueAll();
        else if (branchEventInfo.redirect) TMP_flushOpQueuePartial(branchEventInfo.op);
    endtask

    task automatic TMP_flushOpQueueAll();
        foreach (array[i]) begin
            array[i] = EMPTY_ENTRY;
        end
    endtask

    task automatic TMP_flushOpQueuePartial(input OpSlot op);
        foreach (array[i]) begin
            if (array[i].id > op.id) array[i] = EMPTY_ENTRY;
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


    task automatic TMP_writeInput();
        InputLocs locs = getInputLocs();
        int nInserted = 0;
        
           // return;
        
        foreach (inGroup[i]) begin
            OpSlot op = inGroup[i];
            if (op.active && inMask[i]) begin
                array[locs[nInserted++]] = '{used: 1, active: 1, ready: 1, issueCounter: -1, id: op.id};
            end
        end
    endtask


    task automatic TMP_issueFromArray(input OpSlot ops[$]);
        foreach (ops[i]) begin
            OpSlot op = ops[i];
            foreach (array[s]) begin
                if (array[s].id == op.id) begin
                    assert (array[s].used == 1 && array[s].active == 1) else $fatal(2, "Inactive slot to issue?");
                    array[s].active = 0;
                    array[s].issueCounter = 0;
                    break;
                end
            end
        end
    endtask


    task automatic TMP_markIssuedInArray();
        foreach (array[s]) begin
            if (array[s].issueCounter == HOLD_CYCLES) begin
                assert (array[s].used == 1 && array[s].active == 0) else $fatal(2, "slot to remove must be used and inactive");
                array[s] = EMPTY_ENTRY;
            end
        end
    endtask

    task automatic TMP_incIssueCounter();
        foreach (array[s]) begin
            if (array[s].used == 1 && array[s].active == 0) begin
                array[s].issueCounter++;
            end
        end
    endtask

    
    function automatic int TMP_getNumUsed();
        int res = 0;
        foreach (array[s]) if (array[s].used) res++; 
        return res; 
    endfunction

    function automatic int TMP_getNumActive();
        int res = 0;
        foreach (array[s]) if (array[s].active) res++; 
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
    
    
    IssueQueue#(.OUT_WIDTH(2)) regularQueue(insMap, branchEventInfo, lateEventInfo, inGroup, regularMask,
                                            issuedRegular);
    IssueQueue#(.OUT_WIDTH(2)) floatQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.float,
                                            issuedFloat);
    IssueQueue#(.OUT_WIDTH(1)) branchQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.branch,
                                            issuedBranch);
    IssueQueue#(.OUT_WIDTH(1)) memQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.mem,
                                            issuedMem);
    IssueQueue#(.OUT_WIDTH(1)) sysQueue(insMap, branchEventInfo, lateEventInfo, inGroup, routingInfo.sys,
                                            issuedSys);
    
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


    function automatic ReadyVec3 getReadyVec3(input InstructionMap insMap, input OpSlot iq[$:ISSUE_QUEUE_SIZE]);
        logic D3[3] = '{'z, 'z, 'z};
        ReadyVec3 res = '{default: D3};
        foreach (iq[i]) begin
            InsDependencies deps = insMap.get(iq[i].id).deps;
            logic3 ra = checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);
            res[i] = ra;
        end
        return res;
    endfunction
    
    function automatic ReadyVec3 getForwardVec3(input InstructionMap imap, input OpSlot iq[$:ISSUE_QUEUE_SIZE], input int stage);
        logic D3[3] = '{'z, 'z, 'z};
        ReadyVec3 res = '{default: D3};
        foreach (iq[i]) begin
            InsDependencies deps = imap.get(iq[i].id).deps;
            logic3 ra = checkForwardsReady(imap, AbstractCore.theExecBlock.allByStage, deps, stage);
            res[i] = ra;
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
            ReadyQueue3 res ;
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


endmodule

