
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;

import Queues::*;


module StoreQueue
#(
    parameter logic IS_LOAD_QUEUE = 0,
    parameter logic IS_BRANCH_QUEUE = 0,

    parameter int SIZE = 32,

    type HELPER = QueueHelper
)
(
    ref InstructionMap insMap,
    ref MemTracker memTracker,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpSlotAB inGroup,
    output OpSlotAB outGroup,

    input UopMemPacket wrInputsE0[N_MEM_PORTS],
        input UopMemPacket wrInputsE0_tr[N_MEM_PORTS],
    input UopMemPacket wrInputsE1[N_MEM_PORTS],
    input UopMemPacket wrInputsE2[N_MEM_PORTS]
);

    localparam logic IS_STORE_QUEUE = !IS_LOAD_QUEUE && !IS_BRANCH_QUEUE;

    localparam InstructionMap::Milestone QUEUE_ENTER = IS_BRANCH_QUEUE ? InstructionMap::BqEnter : IS_LOAD_QUEUE ? InstructionMap::LqEnter : InstructionMap::SqEnter;
    localparam InstructionMap::Milestone QUEUE_FLUSH = IS_BRANCH_QUEUE ? InstructionMap::BqFlush : IS_LOAD_QUEUE ? InstructionMap::LqFlush : InstructionMap::SqFlush;
    localparam InstructionMap::Milestone QUEUE_EXIT = IS_BRANCH_QUEUE ? InstructionMap::BqExit : IS_LOAD_QUEUE ? InstructionMap::LqExit : InstructionMap::SqExit;

    localparam logic SQ_RETAIN = 1;

    typedef HELPER::Entry QEntry;
    localparam QEntry EMPTY_QENTRY = HELPER::EMPTY_QENTRY;

    int drainPointer = 0, startPointer = 0, scanPointer = 0, endPointer = 0;
    
    int size;
    logic allow;

    assign size = (endPointer - drainPointer + 2*SIZE) % (2*SIZE);
    assign allow = (size < SIZE - 3*RENAME_WIDTH);

    QEntry content_N[SIZE] = '{default: EMPTY_QENTRY};

    Mword lookupTarget = 'x, lookupLink = 'x; // TODO: move to BQ special submodule because not used in LSQ

    QEntry outputQ[$:3*ROB_WIDTH];
    QEntry outputQM[3*ROB_WIDTH] = '{default: EMPTY_QENTRY}; 

    typedef QEntry QM[3*ROB_WIDTH];

    
    UopPacket storeDataD0 = EMPTY_UOP_PACKET, storeDataD1 = EMPTY_UOP_PACKET, storeDataD2 = EMPTY_UOP_PACKET; // TODO: move to BQ special submodule because not used in LSQ
    UopPacket storeDataD0_E, storeDataD1_E, storeDataD2_E;// TODO: move to BQ special submodule because not used in LSQ

    assign storeDataD0_E = effP(storeDataD0); 
    assign storeDataD1_E = effP(storeDataD1); 
    assign storeDataD2_E = effP(storeDataD2); 


    always @(posedge AbstractCore.clk) begin    
        advance();


        update(); // Before reading and FW checks to eliminate hazards

        submod.readImpl();


        if (lateEventInfo.redirect)
            flushAll();
        else if (branchEventInfo.redirect)
            flushPartial(); 
        else
            writeInput(inGroup);
    end



    task automatic flushAll();
        foreach (content_N[i]) begin
            InsId thisId = content_N[i].mid;        
            if (submod.isCommitted(content_N[i])) continue; 
            if (thisId != -1) putMilestoneM(thisId, QUEUE_FLUSH);            
            content_N[i] = EMPTY_QENTRY;
        end
        endPointer = startPointer;
        scanPointer = startPointer;
        outputQ.delete();
    endtask


    task automatic flushPartial();
        int p = startPointer;

        endPointer = startPointer;
        for (int i = 0; i < SIZE; i++) begin
            InsId thisId = content_N[p % SIZE].mid;        
            if (thisId > branchEventInfo.eventMid) begin
                putMilestoneM(thisId, QUEUE_FLUSH);
                content_N[p % SIZE] = EMPTY_QENTRY;
            end
            else if (thisId == -1) break;
            else endPointer = (p+1) % (2*SIZE);   
            p++;
        end
    endtask


    function automatic logic isScanned(input InsId id);
        return id != -1 && id <= AbstractCore.theRob.lastScanned;
    endfunction

    function automatic logic isCommittable(input InsId id);
        return id != -1 && id <= AbstractCore.theRob.lastOut;
    endfunction

    
    function automatic logic appliesU(input UopName uname);        
        return (
            (IS_STORE_QUEUE && isStoreUop(uname)) 
         || (IS_LOAD_QUEUE && isLoadUop(uname)) 
         || (IS_BRANCH_QUEUE && isBranchUop(uname)) 
        );
    endfunction



    function automatic void setEmpty(ref QEntry entry);
        entry = EMPTY_QENTRY;
    endfunction


    function automatic void commitEntry(ref QEntry entry);
        if (SQ_RETAIN && IS_STORE_QUEUE) begin
            submod.setCommitted(entry);
        end
        else begin
            setEmpty(entry);
        end
    endfunction


    task automatic checkOnCommit();
        QEntry startEntry = content_N[startPointer % SIZE];
        submod.verify(startEntry);
    endtask



    task automatic advance();
        int nOut = 0;
        outGroup <= '{default: EMPTY_SLOT_B};

        while (isScanned(content_N[scanPointer % SIZE].mid)) begin 
            outputQ.push_back(content_N[scanPointer % SIZE]);
            scanPointer = (scanPointer+1) % (2*SIZE);
        end

        while (isCommittable(content_N[startPointer % SIZE].mid)) begin
            InsId thisId = content_N[startPointer % SIZE].mid;
            outGroup[nOut].mid <= thisId;
            outGroup[nOut].active <= 1;
            nOut++;

            assert (outputQ[0].mid == thisId) else $error("mismatch at outputQ %p", outputQ[0]);
            outputQ.pop_front();

            putMilestoneM(thisId, QUEUE_EXIT);
            checkOnCommit();
            commitEntry(content_N[startPointer % SIZE]);
            startPointer = (startPointer+1) % (2*SIZE);
        end

        if (SQ_RETAIN && IS_STORE_QUEUE) begin
            if (AbstractCore.drainHead.active) begin
                assert (AbstractCore.drainHead.mid == content_N[drainPointer % SIZE].mid) else $error("Not matching n id drain %d/%d", AbstractCore.drainHead.mid, content_N[drainPointer % SIZE].mid);            
                content_N[drainPointer % SIZE] = EMPTY_QENTRY;
                drainPointer = (drainPointer+1) % (2*SIZE);
            end
        end
        else
            drainPointer = startPointer;

        outputQM = makeQM(outputQ);
    endtask


    function automatic QM makeQM(input QEntry q[$:3*ROB_WIDTH]);
        QM res = '{default: EMPTY_QENTRY};
        foreach (q[i]) res[i] = q[i];
        return res;
    endfunction



    function automatic int findIndex(input UopId uid);
        int found[$] = content_N.find_first_index with (item.mid == U2M(uid));
        assert (found.size() == 1) else $fatal(2, "id %d not found in queue", U2M(uid));
        return found[0];
    endfunction


    task automatic update();
        submod.updateMain();
    endtask


                    // .active, .mid
    task automatic writeInput(input OpSlotAB inGroup);
        if (!anyActiveB(inGroup)) return;

        foreach (inGroup[i]) begin
            InsId thisMid = inGroup[i].mid;

            if (appliesU(decMainUop(thisMid))) begin
                content_N[endPointer % SIZE] = HELPER::newEntry(insMap, thisMid);                
                putMilestoneM(thisMid, QUEUE_ENTER);
                endPointer = (endPointer+1) % (2*SIZE);
            end
        end
    endtask

endmodule



module TmpSubSq();
    task automatic readImpl();
        // TODO: move to 'update' section unless it should be after queue scan 
        updateStoreData(); // CAREFUL: should it be before or after handleForwadsS may be uncertain

        foreach (theExecBlock.toLqE0[p]) begin
            UopMemPacket loadOp = theExecBlock.toLqE0[p];
            UopPacket resb;

            theExecBlock.fromSq[p] <= EMPTY_UOP_PACKET;

            if (!loadOp.active || !isLoadMemUop(decUname(loadOp.TMP_oid))) continue;

            resb = StoreQueueHelper::scanQueue(StoreQueue.insMap, StoreQueue.content_N, U2M(loadOp.TMP_oid), loadOp.result);

            if (resb.active) begin
                AccessSize size = getTransactionSize(decMainUop(U2M(loadOp.TMP_oid)));
                AccessSize trSize = getTransactionSize(decMainUop(U2M(resb.TMP_oid)));
                checkSqResp(loadOp, resb, StoreQueue.memTracker.findStoreAll(U2M(resb.TMP_oid)), trSize, loadOp.result, size);
            end

            theExecBlock.fromSq[p] <= resb;
        end
    endtask

    task automatic verify(input StoreQueueHelper::Entry entry);
        Mword actualAdr = //StoreQueueHelper::getAdr(entry);
                            entry.adr;
        Mword actualVal = //StoreQueueHelper::getVal(entry);
                            entry.val;
        checkStore(entry.mid, actualAdr, actualVal);
    endtask

    function automatic void checkStore(input InsId mid, input Mword adr, input Mword value);
        Transaction tr[$] = AbstractCore.memTracker.stores.find_first with (item.owner == mid); // removal from tracker is unordered w.r.t. this...
        if (tr.size() == 0) tr = AbstractCore.memTracker.committedStores.find_first with (item.owner == mid); // ... so may be already here

        if (decMainUop(mid) == UOP_mem_sts) return; // Not checking sys stores

        assert (tr[0].adr === adr && tr[0].val === value) else $error("Wrong store: Mop %d, %d@%d\n%p\n%p", mid, value, adr, tr[0],  StoreQueue.insMap.get(mid));
    endfunction

  
    task automatic updateStoreData();
        UopPacket dataUop = theExecBlock.storeDataE0_E;
        if (dataUop.active && (decUname(dataUop.TMP_oid) inside {UOP_data_int, UOP_data_fp})) begin
            int dataFound[$] = StoreQueue.content_N.find_first_index with (item.mid == U2M(dataUop.TMP_oid));
            assert (dataFound.size() == 1) else $fatal(2, "Not found SQ entry");
            
            StoreQueueHelper::updateStoreData(StoreQueue.insMap, StoreQueue.content_N[dataFound[0]], dataUop, StoreQueue.branchEventInfo);
            putMilestone(dataUop.TMP_oid, InstructionMap::WriteMemValue);
            dataUop.result = //StoreQueueHelper::getAdr(StoreQueue.content_N[dataFound[0]]); // Save store adr to notify RQ that it is being filled 
                            StoreQueue.content_N[dataFound[0]].adr;
        end
        
        StoreQueue.storeDataD0 <= tickP(dataUop);
        StoreQueue.storeDataD1 <= tickP(StoreQueue.storeDataD0);
        StoreQueue.storeDataD2 <= tickP(StoreQueue.storeDataD1);
    endtask

    function automatic void checkSqResp(input UopPacket loadOp, input UopPacket sr, input Transaction tr, input AccessSize trSize, input Mword eadr, input AccessSize esize);
        Transaction latestOverlap = StoreQueue.memTracker.checkTransactionOverlap(U2M(loadOp.TMP_oid));
        logic isInside = memInside(eadr, (esize), tr.adr, (trSize));

        // If sr source is not latestOverlap, denote this fact somewhere (so far printing an error, hasn't happened yet).
        // On Retire, if the load has taken its value from FW but not latestOverlap, raise an error.
        assert (latestOverlap.owner == U2M(sr.TMP_oid)) else $error("not the same Tr:\n%p\n%p", latestOverlap, tr);
        assert (tr.owner != -1) else $error("Forwarded store unknown by memTracker! %d", U2M(sr.TMP_oid));

        if (sr.status == ES_CANT_FORWARD) begin //
            logic isOverlapping = memOverlap(eadr, (esize), tr.adr, (trSize));
            assert (isOverlapping && ((esize != trSize) || !isInside) ) else $error("Adr (same size and inside) or not overlapping");
        end
        else if (sr.status == ES_SQ_MISS) begin
            assert (isInside) else $error("Adr not inside");
        end
        else begin
            assert (isInside) else $error("Adr not inside");
        end
    endfunction


    task automatic updateMain();
    
        foreach (StoreQueue.wrInputsE0[p]) begin
            UopMemPacket packet = StoreQueue.wrInputsE0[p];
            UopName uname = decUname(packet.TMP_oid);
            if (!packet.active) continue;
            if (!appliesU(uname)) continue;

            begin
               int index = findIndex(packet.TMP_oid);
               updateEntryE0(StoreQueue.content_N[index], packet);
            end
        end

        foreach (StoreQueue.wrInputsE2[p]) begin
            UopMemPacket packet = StoreQueue.wrInputsE2[p];
            UopName uname = decUname(packet.TMP_oid);
            if (!packet.active) continue;
            if (!appliesU(uname)) continue;

            if (!(packet.status inside {ES_REFETCH, ES_ILLEGAL})) continue;

            begin
               int index = findIndex(packet.TMP_oid);
               updateEntryE2(StoreQueue.content_N[index], packet);                
            end
        end
    endtask

    function automatic void updateEntryE2(ref StoreQueueHelper::Entry entry, input UopMemPacket p);
       if (p.status == ES_REFETCH) //StoreQueueHelper::setRefetch(entry);
                                        entry.refetch = 1;
       else if (p.status == ES_ILLEGAL) //StoreQueueHelper::setError(entry); 
                                        entry.error = 1;
    endfunction

    function automatic void updateEntryE0(ref StoreQueueHelper::Entry entry, input UopMemPacket p);
       StoreQueueHelper::updateEntry(StoreQueue.insMap, entry, p, StoreQueue.branchEventInfo);
        
       // TODO: make separate milestones for SQ and LQ
       putMilestone(p.TMP_oid, InstructionMap::WriteMemAddress);
    endfunction

    function automatic logic isCommitted(input StoreQueueHelper::Entry entry);
        //return StoreQueueHelper::isCommitted(entry);
        return entry.committed;
    endfunction
    
    function automatic void setCommitted(ref StoreQueueHelper::Entry entry);
        //StoreQueueHelper::setCommitted(entry);
        entry.committed = 1;
    endfunction

endmodule




module TmpSubLq();
    task automatic readImpl();        
        foreach (theExecBlock.toSqE0[p]) begin
            UopMemPacket storeUop = theExecBlock.toSqE0[p];
            UopPacket resb;

            theExecBlock.fromLq[p] <= EMPTY_UOP_PACKET;

            if (!storeUop.active || !isStoreMemUop(decUname(storeUop.TMP_oid))) continue;

            resb = LoadQueueHelper::scanQueue(StoreQueue.insMap, StoreQueue.content_N, U2M(theExecBlock.toLqE0[p].TMP_oid), storeUop.result);
            theExecBlock.fromLq[p] <= resb;      
        end
    endtask
    
    task automatic verify(input LoadQueueHelper::Entry entry);

    endtask
    
    
    task automatic updateMain();
    
        foreach (StoreQueue.wrInputsE0[p]) begin
            UopMemPacket packet = StoreQueue.wrInputsE0[p];
            UopName uname = decUname(packet.TMP_oid);
            if (!packet.active) continue;
            if (!appliesU(uname)) continue;

            begin
               int index = findIndex(packet.TMP_oid);
               updateEntryE0(StoreQueue.content_N[index], packet);
            end
        end

        foreach (StoreQueue.wrInputsE2[p]) begin
            UopMemPacket packet = StoreQueue.wrInputsE2[p];
            UopName uname = decUname(packet.TMP_oid);
            if (!packet.active) continue;
            if (!appliesU(uname)) continue;

            if (!(packet.status inside {ES_REFETCH, ES_ILLEGAL})) continue;

            begin
               int index = findIndex(packet.TMP_oid);
               updateEntryE2(StoreQueue.content_N[index], packet);                
            end
        end
    endtask

    function automatic void updateEntryE2(ref LoadQueueHelper::Entry entry, input UopMemPacket p);
       if (p.status == ES_REFETCH) //LoadQueueHelper::setRefetch(entry);
                                   entry.refetch = 1;
       else if (p.status == ES_ILLEGAL) //LoadQueueHelper::setError(entry); 
                                        entry.error = 1;
    endfunction

    function automatic void updateEntryE0(ref LoadQueueHelper::Entry entry, input UopMemPacket p);
       LoadQueueHelper::updateEntry(StoreQueue.insMap, entry, p, StoreQueue.branchEventInfo);
       putMilestone(p.TMP_oid, InstructionMap::WriteMemAddress);
    endfunction

    function automatic logic isCommitted(input LoadQueueHelper::Entry entry);
        return 0;// LoadQueueHelper::isCommitted(entry);
    endfunction
    
    function automatic void setCommitted(ref LoadQueueHelper::Entry entry);
        //LoadQueueHelper::setCommitted(entry);
    endfunction

endmodule




module TmpSubBr();
    task automatic readImpl();        
        UopPacket p = theExecBlock.branch0.p0_E;

        if (p.active) begin
            int index = findIndex(p.TMP_oid);     
            StoreQueue.lookupTarget <= //BranchQueueHelper::getAdr(StoreQueue.content_N[index]);
                                        StoreQueue.content_N[index].immTarget;
            StoreQueue.lookupLink <= //BranchQueueHelper::getLink(StoreQueue.content_N[index]);
                                        StoreQueue.content_N[index].linkAdr;
        end
        else begin
            StoreQueue.lookupTarget <= 'x;
            StoreQueue.lookupLink <= 'x;
        end
    endtask
    
    task automatic verify(input BranchQueueHelper::Entry entry);
        BranchQueueHelper::verifyOnCommit(StoreQueue.insMap, entry);
    endtask


    task automatic updateMain();
    
        foreach (StoreQueue.wrInputsE0[p]) begin
            UopMemPacket packet = StoreQueue.wrInputsE0[p];
            UopName uname = decUname(packet.TMP_oid);
            if (!packet.active) continue;
            if (!appliesU(uname)) continue;

            begin
               int index = findIndex(packet.TMP_oid);
               updateEntryE0(StoreQueue.content_N[index], packet);
            end
        end
   
    endtask

    function automatic void updateEntryE0(ref BranchQueueHelper::Entry entry, input UopMemPacket p);
       BranchQueueHelper::updateEntry(StoreQueue.insMap, entry, p, StoreQueue.branchEventInfo);
    endfunction

    function automatic logic isCommitted(input BranchQueueHelper::Entry entry);
        return 0;//BranchQueueHelper::isCommitted(entry);
    endfunction
    
    function automatic void setCommitted(ref BranchQueueHelper::Entry entry);
        //BranchQueueHelper::setCommitted(entry);
    endfunction
    
endmodule
