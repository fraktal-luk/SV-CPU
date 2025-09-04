
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
    output OpSlotAB outGroup
);

    localparam logic IS_STORE_QUEUE = !IS_LOAD_QUEUE && !IS_BRANCH_QUEUE;

    localparam InstructionMap::Milestone QUEUE_ENTER = HELPER::QUEUE_ENTER;
    localparam InstructionMap::Milestone QUEUE_FLUSH = HELPER::QUEUE_FLUSH;
    localparam InstructionMap::Milestone QUEUE_EXIT = HELPER::QUEUE_EXIT;


    localparam logic SQ_RETAIN = 1;

    typedef HELPER::Entry QEntry;
    localparam QEntry EMPTY_QENTRY = HELPER::EMPTY_QENTRY;

    int drainPointer = 0, startPointer = 0, scanPointer = 0, endPointer = 0;

    int size;
    logic allow;

    assign size = (endPointer - drainPointer + 2*SIZE) % (2*SIZE);
    assign allow = (size < SIZE - 3*RENAME_WIDTH);

    QEntry content[SIZE] = '{default: EMPTY_QENTRY};

    QEntry outputQ[$:3*ROB_WIDTH];
    QEntry outputQM[3*ROB_WIDTH] = '{default: EMPTY_QENTRY}; 

    typedef QEntry QM[3*ROB_WIDTH];



    always @(posedge AbstractCore.clk) begin    
        advance();
        
        if (0) begin
            submod.updateMain();
            submod.readImpl();
        end

        if (lateEventInfo.redirect)
            flushAll();
        else if (branchEventInfo.redirect)
            flushPartial(); 
        else
            writeInput(inGroup);
            
        if (1) begin
            submod.updateMain();
            submod.readImpl();
        end
    end



    task automatic flushAll();
        foreach (content[i]) begin
            InsId thisId = content[i].mid;        
            if (submod.isCommitted(content[i])) continue; 
            if (thisId != -1) putMilestoneM(thisId, QUEUE_FLUSH);            
            content[i] = EMPTY_QENTRY;
        end
        endPointer = startPointer;
        scanPointer = startPointer;
        outputQ.delete();
    endtask


    task automatic flushPartial();
        int p = startPointer;

        endPointer = startPointer;
        for (int i = 0; i < SIZE; i++) begin
            InsId thisId = content[p % SIZE].mid;        
            if (thisId > branchEventInfo.eventMid) begin
                putMilestoneM(thisId, QUEUE_FLUSH);
                content[p % SIZE] = EMPTY_QENTRY;
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



    task automatic checkOnCommit();
        QEntry startEntry = content[startPointer % SIZE];
        submod.verify(startEntry);
    endtask

    function automatic void commitEntry(ref QEntry entry);
        if (SQ_RETAIN && IS_STORE_QUEUE) begin
            submod.setCommitted(entry);
        end
        else begin
            setEmpty(entry);
        end
    endfunction


    task automatic advance();
        int nOut = 0;
        outGroup <= '{default: EMPTY_SLOT_B};

        while (isScanned(content[scanPointer % SIZE].mid)) begin 
            outputQ.push_back(content[scanPointer % SIZE]);
            scanPointer = (scanPointer+1) % (2*SIZE);
        end

        while (isCommittable(content[startPointer % SIZE].mid)) begin
            InsId thisId = content[startPointer % SIZE].mid;
            outGroup[nOut].mid <= thisId;
            outGroup[nOut].active <= 1;
            nOut++;

            assert (outputQ[0].mid == thisId) else $error("mismatch at outputQ %p", outputQ[0]);
            outputQ.pop_front();

            putMilestoneM(thisId, QUEUE_EXIT);
            checkOnCommit();
            commitEntry(content[startPointer % SIZE]);
            startPointer = (startPointer+1) % (2*SIZE);
        end

        if (SQ_RETAIN && IS_STORE_QUEUE) begin
            if (AbstractCore.drainHead.mid != -1) begin
                assert (AbstractCore.drainHead.mid == content[drainPointer % SIZE].mid) else $error("Not matching n id drain %d/%d", AbstractCore.drainHead.mid, content[drainPointer % SIZE].mid);            
                content[drainPointer % SIZE] = EMPTY_QENTRY;
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
        int found[$] = content.find_first_index with (item.mid == U2M(uid));
        assert (found.size() == 1) else $fatal(2, "id %d not found in queue", U2M(uid));
        return found[0];
    endfunction


    function automatic QEntry newEntry(input InsId mid);
        return submod.getNewEntry(mid);
    endfunction


                    // .active, .mid
    task automatic writeInput(input OpSlotAB inGroup);
        if (!anyActiveB(inGroup)) return;

        foreach (inGroup[i]) begin
            InsId thisMid = inGroup[i].mid;

            if (appliesU(decMainUop(thisMid))) begin
                content[endPointer % SIZE] = newEntry(thisMid);
                putMilestoneM(thisMid, QUEUE_ENTER);
                endPointer = (endPointer+1) % (2*SIZE);
            end
        end
    endtask

endmodule



module TmpSubSq();
    UopPacket storeDataD0 = EMPTY_UOP_PACKET, storeDataD1 = EMPTY_UOP_PACKET, storeDataD2 = EMPTY_UOP_PACKET;
    UopPacket storeDataD0_E, storeDataD1_E, storeDataD2_E;

    task automatic readImpl();
        foreach (theExecBlock.toLqE0[p]) begin
            UopMemPacket loadOp = theExecBlock.toLqE0[p];
            AccessDesc ad = theExecBlock.accessDescs[p];
            Translation tr = theExecBlock.dcacheTranslations[p];
            UopPacket resb;

            theExecBlock.fromSq[p] <= EMPTY_UOP_PACKET;

            if (!loadOp.active || !isLoadMemUop(decUname(loadOp.TMP_oid))) continue;

            resb = scanStoreQueue(StoreQueue.content, U2M(loadOp.TMP_oid), tr.padr, ad.size);

            if (resb.active) begin
                AccessSize size = ad.size;
                AccessSize trSize = getTransactionSize(decMainUop(U2M(resb.TMP_oid)));
                checkSqResp(loadOp, resb, StoreQueue.memTracker.findStoreAll(U2M(resb.TMP_oid)), trSize, tr.padr, size);
            end

            theExecBlock.fromSq[p] <= resb;
        end
    endtask

    function automatic UopPacket scanStoreQueue(ref SqEntry entries[SQ_SIZE], input InsId id, input Dword padr, input AccessSize loadSize);
        SqEntry found[$] = entries.find with ( item.mid != -1 && item.mid < id 
                                                    && item.translation.present && !item.accessDesc.sys
                                                    && memOverlap(item.translation.padr, item.accessDesc.size, padr, loadSize));
        SqEntry fwEntry;

        if (found.size() == 0) return EMPTY_UOP_PACKET;
        else begin // Youngest older overlapping store:
            SqEntry vmax[$] = found.max with (item.mid);
            fwEntry = vmax[0];
        end

        if ((loadSize != fwEntry.accessDesc.size) || !memInside(padr, (loadSize), fwEntry.translation.padr, (fwEntry.accessDesc.size)))  // don't allow FW of different size because shifting would be needed
            return '{1, FIRST_U(fwEntry.mid), ES_CANT_FORWARD,   EMPTY_POISON, 'x};
        else if (!fwEntry.valReady)         // Covers, not has data -> to RQ
            return '{1, FIRST_U(fwEntry.mid), ES_SQ_MISS,   EMPTY_POISON, 'x};
        else                                // Covers and has data -> OK
            return '{1, FIRST_U(fwEntry.mid), ES_OK,        EMPTY_POISON, fwEntry.val};

    endfunction


    task automatic verify(input SqEntry entry);
        checkStore(entry.mid, entry.accessDesc.vadr, entry.val);
    endtask

    function automatic void checkStore(input InsId mid, input Mword adr, input Mword value);
        Transaction tr[$] = AbstractCore.memTracker.stores.find_first with (item.owner == mid); // removal from tracker is unordered w.r.t. this...
        if (tr.size() == 0) tr = AbstractCore.memTracker.committedStores.find_first with (item.owner == mid); // ... so may be already here

        if (decMainUop(mid) == UOP_mem_sts) return; // Not checking sys stores

        assert (tr[0].adr === adr && tr[0].val === value) else $error("Wrong store: Mop %d, %d@%d\n%p\n%p", mid, value, adr, tr[0],  StoreQueue.insMap.get(mid));
    endfunction


    function automatic void checkSqResp(input UopPacket loadOp, input UopPacket sr, input Transaction tr, input AccessSize trSize, input Dword padr, input AccessSize esize);
        Transaction latestOverlap = StoreQueue.memTracker.checkTransactionOverlap(U2M(loadOp.TMP_oid));
        logic isInside = memInside(padr, (esize), tr.padr, (trSize));

        // If sr source is not latestOverlap, denote this fact somewhere (so far printing an error, hasn't happened yet).
        // On Retire, if the load has taken its value from FW but not latestOverlap, raise an error.
        assert (latestOverlap.owner == U2M(sr.TMP_oid)) else $error("not the same Tr:\n%p\n%p", latestOverlap, tr);
        assert (tr.owner != -1) else $error("Forwarded store unknown by memTracker! %d", U2M(sr.TMP_oid));

        if (sr.status == ES_CANT_FORWARD) begin //
            logic isOverlapping = memOverlap(padr, (esize), tr.padr, (trSize));
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
        UopMemPacket packetsE0[N_MEM_PORTS] = theExecBlock.toSqE0;
        UopMemPacket packetsE1[N_MEM_PORTS] = theExecBlock.toSqE1;
        UopMemPacket packetsE2[N_MEM_PORTS] = theExecBlock.toSqE2;

        foreach (packetsE0[p]) begin
            UopMemPacket packet = packetsE0[p];
            UopName uname = decUname(packet.TMP_oid);
            if (!packet.active) continue;
            if (!appliesU(uname)) continue;

            begin
               int index = findIndex(packet.TMP_oid);
               updateEntry(StoreQueue.content[index], packet, theExecBlock.dcacheTranslations[p], theExecBlock.accessDescs[p]);
                
               putMilestone(packet.TMP_oid, InstructionMap::WriteStoreAddress);
            end
        end

        foreach (packetsE1[p]) begin
            UopMemPacket packet = packetsE1[p];
            UopName uname = decUname(packet.TMP_oid);
            if (!packet.active) continue;
            if (!appliesU(uname)) continue;

            if (!(packet.status inside {ES_REFETCH, ES_ILLEGAL})) continue;

            begin
               int index = findIndex(packet.TMP_oid);
          
            end
        end

        foreach (packetsE2[p]) begin
            UopMemPacket packet = packetsE2[p];
            UopName uname = decUname(packet.TMP_oid);
            if (!packet.active) continue;
            if (!appliesU(uname)) continue;

            if (!(packet.status inside {ES_REFETCH, ES_ILLEGAL})) continue;

            begin
               int index = findIndex(packet.TMP_oid);
               if (packet.status == ES_REFETCH) StoreQueue.content[index].refetch = 1;
               else if (packet.status == ES_ILLEGAL) StoreQueue.content[index].error = 1;            
            end
        end
        
        updateStoreData();

    endtask


    function automatic void updateEntry(ref SqEntry entry, input UopPacket p, input Translation tr, input AccessDesc desc);
        UopName uname = decUname(p.TMP_oid);
        if (uname inside {UOP_mem_sti,  UOP_mem_stib, UOP_mem_stf, UOP_mem_sts}) begin
            entry.accessDesc = desc;
            entry.translation = tr;
        end
    endfunction



    task automatic updateStoreData();
        UopPacket dataUop = theExecBlock.storeDataE0_E;
        if (dataUop.active && (decUname(dataUop.TMP_oid) inside {UOP_data_int, UOP_data_fp})) begin
            int dataFound[$] = StoreQueue.content.find_first_index with (item.mid == U2M(dataUop.TMP_oid));
            assert (dataFound.size() == 1) else $fatal(2, "Not found SQ entry");
            
            updateStoreDataImpl(StoreQueue.content[dataFound[0]], dataUop);
            dataUop.result = StoreQueue.content[dataFound[0]].translation.padr; // This may be used in the future for waking up RQ when missed on store forwarding
            putMilestone(dataUop.TMP_oid, InstructionMap::WriteStoreValue);
        end

        storeDataD0 <= tickP(dataUop);
        storeDataD1 <= tickP(storeDataD0);
        storeDataD2 <= tickP(storeDataD1);
    endtask


    function automatic void updateStoreDataImpl(ref SqEntry entry, input UopPacket p);
        UopName uname = decUname(p.TMP_oid);
       
        if (p.status == ES_UNCACHED_1) begin
        end
        else if (uname inside {UOP_mem_sti,  UOP_mem_stib, UOP_mem_stf, UOP_mem_sts}) begin
        end
        else begin
            assert (uname inside {UOP_data_int, UOP_data_fp}) else $fatal(2, "Wrong uop for store data");
        
            entry.valReady = 1;
            entry.val = p.result;
        end
    endfunction


    function automatic logic isCommitted(input SqEntry entry);
        return entry.committed;
    endfunction
    
    function automatic void setCommitted(ref SqEntry entry);
        entry.committed = 1;
    endfunction

    function automatic SqEntry getNewEntry(input InsId mid);
        return  '{
            mid: mid,
            valReady: 0,
            val: 'x,
            accessDesc: DEFAULT_ACCESS_DESC,
            translation: DEFAULT_TRANSLATION,
            
            committed: 0,
            error: 0,
            refetch: 0
        };
    endfunction

    assign storeDataD0_E = effP(storeDataD0); 
    assign storeDataD1_E = effP(storeDataD1); 
    assign storeDataD2_E = effP(storeDataD2); 

endmodule




module TmpSubLq();

    LqEntry oldestRefetchEntry = LoadQueueHelper::EMPTY_QENTRY, oldestRefetchEntryP0 = LoadQueueHelper::EMPTY_QENTRY, oldestRefetchEntryP1 = LoadQueueHelper::EMPTY_QENTRY;

    task automatic readImpl();
        foreach (theExecBlock.toSqE2[p]) begin
            UopMemPacket storeUop = theExecBlock.toSqE2[p];

            if (!storeUop.active || !isStoreMemUop(decUname(storeUop.TMP_oid))) continue;
            void'(scanLoadQueue(StoreQueue.content, U2M(storeUop.TMP_oid), theExecBlock.dcacheTranslations_E2[p].padr, theExecBlock.accessDescs_E2[p].size));
        end
    endtask


    function automatic UopPacket scanLoadQueue(ref LqEntry entries[LQ_SIZE], input InsId id, input Dword padr, input AccessSize size);
        UopPacket res = EMPTY_UOP_PACKET;
        AccessSize trSize = size;
        
        // We search for all matching entries
        int found[$] = entries.find_index with (item.mid > id && item.translation.present && item.valReady && memOverlap(item.translation.padr, (item.accessDesc.size), padr, (trSize)));

        if (found.size() == 0) return res;

        foreach (found[i]) entries[found[i]].refetch = 1; // Mark which entries have a sotre order violation

        begin // 'active' indicates that some match has happened without further details
            int oldestFound[$] = found.min with (entries[item].mid);
            StoreQueue.insMap.setRefetch(entries[oldestFound[0]].mid);
        end
        
        return res;
    endfunction



    task automatic verify(input LqEntry entry);

    endtask
    
    
    task automatic updateMain();
        UopMemPacket packetsE0[N_MEM_PORTS] = theExecBlock.toLqE0;
        UopMemPacket packetsE1[N_MEM_PORTS] = theExecBlock.toLqE1;
        UopMemPacket packetsE2[N_MEM_PORTS] = theExecBlock.toLqE2;

        foreach (packetsE0[p]) begin
            UopMemPacket packet = packetsE0[p];
            UopName uname = decUname(packet.TMP_oid);
            if (!packet.active) continue;
            if (!appliesU(uname)) continue;

            begin
               int index = findIndex(packet.TMP_oid);
               updateEntry(StoreQueue.content[index], packet, theExecBlock.dcacheTranslations[p], theExecBlock.accessDescs[p]);
               putMilestone(packet.TMP_oid, InstructionMap::WriteLoadAddress);
            end
        end

        foreach (packetsE1[p]) begin
            UopMemPacket packet = packetsE1[p];
            UopName uname = decUname(packet.TMP_oid);
            if (!packet.active) continue;
            if (!appliesU(uname)) continue;

            begin
               int index = findIndex(packet.TMP_oid);

            end
        end

        foreach (packetsE2[p]) begin
            UopMemPacket packet = packetsE2[p];
            UopName uname = decUname(packet.TMP_oid);
            if (!packet.active) continue;
            if (!appliesU(uname)) continue;

            begin
               int index = findIndex(packet.TMP_oid);
               if (packet.status == ES_REFETCH) StoreQueue.content[index].refetch = 1;
               else if (packet.status == ES_ILLEGAL) StoreQueue.content[index].error = 1;
               else if (packet.status == ES_OK) StoreQueue.content[index].valReady = 1;           
            end
        end
        
        // Scan entries which need to be refetched and find the oldest
        
        begin
            LqEntry found[$] = StoreQueue.content.find with (item.mid != -1 && item.refetch);
            LqEntry oldestFound[$] = found.min with (item.mid);
            
            int foundAgain[$] = StoreQueue.content.find_first_index with (item.mid == oldestRefetchEntry.mid);
            int foundAgainP0[$] = StoreQueue.content.find_first_index with (item.mid == oldestRefetchEntryP0.mid);
            //int foundAgain[$] = StoreQueue.content.find_first_index with (item.mid == oldestRefetchEntry.mid);
            
            
            if (oldestFound.size() > 0) oldestRefetchEntry <= oldestFound[0];
            else oldestRefetchEntry <= LoadQueueHelper::EMPTY_QENTRY;
            
            // If wasn't killed in queue, pass on
            if (foundAgain.size() > 0) oldestRefetchEntryP0 <= oldestRefetchEntry;
            else oldestRefetchEntryP0 <= LoadQueueHelper::EMPTY_QENTRY;

            // If wasn't killed in queue, pass on
            if (foundAgainP0.size() > 0) oldestRefetchEntryP1 <= oldestRefetchEntryP0;
            else oldestRefetchEntryP1 <= LoadQueueHelper::EMPTY_QENTRY;
        end
        
        
    endtask

    function automatic void updateEntry(ref LqEntry entry, input UopPacket p, input Translation tr, input AccessDesc desc);
        entry.accessDesc = desc;
        entry.translation = tr;
    endfunction


    function automatic logic isCommitted(input LqEntry entry);
        return 0;
    endfunction
    
    function automatic void setCommitted(ref LqEntry entry);
    endfunction

    function automatic LqEntry getNewEntry(input InsId mid);
        return '{
            mid: mid,
            valReady: 'x,
            val: 'x,
            accessDesc: DEFAULT_ACCESS_DESC,
            translation: DEFAULT_TRANSLATION,
            
            committed: 0,
            error: 0,
            refetch: 0
        };
    endfunction

endmodule




module TmpSubBr();
    Mword lookupTarget = 'x, lookupLink = 'x;

    task automatic readImpl();        
        UopPacket p = theExecBlock.branch0.p0_E;

        if (p.active) begin
            int index = findIndex(p.TMP_oid);     
            lookupTarget <= StoreQueue.content[index].immTarget;
            lookupLink <= StoreQueue.content[index].linkAdr;
        end
        else begin
            lookupTarget <= 'x;
            lookupLink <= 'x;
        end
    endtask
    
    task automatic verify(input BqEntry entry);
        InstructionMap imap = StoreQueue.insMap;
        UopName uname = decUname(FIRST_U(entry.mid));
        Mword target = imap.get(entry.mid).basicData.target;
        Mword actualTarget = 'x;
                    
        if (entry.taken) begin
            if (uname inside {UOP_br_z, UOP_br_nz})
                actualTarget = entry.regTarget;
            else
                actualTarget = entry.immTarget;
        end
        else begin
            actualTarget = entry.linkAdr;
        end
        
        assert (actualTarget === target) else $error("Branch %p committed not matching: %d // %d", uname, actualTarget, target);
        
    endtask


    task automatic updateMain();
        UopMemPacket packetsE0[N_MEM_PORTS] = theExecBlock.toBq;
        
        foreach (packetsE0[p]) begin
            UopMemPacket packet = packetsE0[p];
            UopName uname = decUname(packet.TMP_oid);
            if (!packet.active) continue;
            if (!appliesU(uname)) continue;

            begin
               int index = findIndex(packet.TMP_oid);
               updateEntry(StoreQueue.content[index], packet);
            end
        end

    endtask

    function automatic void updateEntry(ref BqEntry entry, input UopPacket p);            
        UopInfo uInfo = StoreQueue.insMap.getU(p.TMP_oid);
        UopName name = uInfo.name;
        Mword trgArg = uInfo.argsA[1];
        
        entry.taken = p.result;
        entry.condReady = 1;
        entry.trgReady = 1;

        if (name inside {UOP_br_z, UOP_br_nz})
            entry.regTarget = trgArg;
 
    endfunction


    function automatic logic isCommitted(input BqEntry entry);
        return 0;
    endfunction
    
    function automatic void setCommitted(ref BqEntry entry);
    endfunction
    
    function automatic BqEntry getNewEntry(input InsId mid);
        BqEntry res = BranchQueueHelper::EMPTY_QENTRY;
        InstructionInfo ii = StoreQueue.insMap.get(mid);
        UopInfo ui = StoreQueue.insMap.getU(FIRST_U(mid));
        AbstractInstruction abs = ii.basicData.dec;
        
        res.mid = mid;
        
        res.predictedTaken = 0;

        res.condReady = 0;
        res.trgReady = isBranchImmIns(abs);
        
        res.linkAdr = ii.basicData.adr + 4;
        
        // If branch immediate, calculate target for taken
        if (ui.name inside {UOP_bc_a, UOP_bc_l, UOP_bc_z, UOP_bc_nz})
            res.immTarget = ii.basicData.adr + ui.argsE[1];

        return res;
    endfunction
    
endmodule
