
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;


module ReplayQueue(
    ref InstructionMap insMap,
    input logic clk,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input UopPacket inputUops[N_MEM_PORTS],
    input UopPacket inputUopsE2[N_MEM_PORTS],
    output UopPacket outPacket
);

    localparam int SIZE = 32;


    typedef struct {
        logic used;
        UidT uid;
        logic issued;
        logic cancel;
        int outCnt;

        logic ready;
        int readyCnt;

        UopPacket p;
        AccessDesc ad;
        Translation tr;
    } TMP_Entry;

    localparam TMP_Entry TMP_EMPTY_ENTRY = '{0, UIDT_NONE, 0, 0, -1,
                                                0, -1,
                                            EMPTY_UOP_PACKET, DEFAULT_ACCESS_DESC, DEFAULT_TRANSLATION};

    int numUsed = 0;
    logic accept;


    TMP_Entry entries[SIZE] = '{default: TMP_EMPTY_ENTRY};


    typedef int InputLocs[N_MEM_PORTS];


    UopPacket issued0 = EMPTY_UOP_PACKET,
              issued1 = EMPTY_UOP_PACKET;


    always @(posedge clk) begin
        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
           flush();
        end

        issue();
        wakeup();

        writeInput();
        removeCanceled();

        issued1 <= tickP(issued0);
        numUsed = getNumUsed();
    end



    task automatic writeInput();
        InputLocs inLocs = getInputLocs();

        AccessDesc adsE2[N_MEM_PORTS] = theExecBlock.accessDescs_E2;
        Translation trsE2[N_MEM_PORTS] = theExecBlock.dcacheTranslations_E2;

        foreach (inputUops[i]) begin
            if (inputUops[i].active) begin 
                // Already present?
                int inds[$] = entries.find_first_index with (item.uid == inputUops[i].TMP_oid);
                if (inds.size() > 0) begin
                    continue;
                end
                entries[inLocs[i]] = '{1, inputUops[i].TMP_oid, 0, 0, -1,
                                        0, 15,
                                        EMPTY_UOP_PACKET, DEFAULT_ACCESS_DESC, DEFAULT_TRANSLATION};

                putMilestone(inputUops[i].TMP_oid, InstructionMap::RqEnter);

            end
        end

        foreach (inputUopsE2[i]) begin
            if (inputUopsE2[i].active) begin 
                int inds[$] = entries.find_first_index with (item.uid == inputUopsE2[i].TMP_oid);

                if (needsReplay(inputUopsE2[i].status)) begin
                    entries[inds[0]].cancel = 0;
                    entries[inds[0]].issued = 0;
                    entries[inds[0]].outCnt = -1;

                    entries[inds[0]].ready = 0;
                    entries[inds[0]].readyCnt = -1;

                    entries[inds[0]].p = inputUopsE2[i];
                    entries[inds[0]].ad = adsE2[i];
                    entries[inds[0]].tr = trsE2[i];
                    continue;
                end

                if (inds.size() > 0) begin
                    entries[inds[0]].cancel = 1;
                    entries[inds[0]].issued = 0;
                    entries[inds[0]].outCnt = -1;

                    entries[inds[0]].ready = 0;
                    entries[inds[0]].readyCnt = -1;
                end
            end

        end
    endtask


    task automatic wakeup();
        UopPacket wrInput = AbstractCore.theSq.submod.storeDataD2_E;
        logic storeDataActive = wrInput.active && (decUname(wrInput.TMP_oid) inside {UOP_data_int, UOP_data_fp});

        foreach (entries[i]) begin
            if (!entries[i].used || !entries[i].p.active || entries[i].ready || entries[i].cancel) continue;

            case (entries[i].p.status)
                ES_TLB_MISS: begin
                    if (getPageBaseM(entries[i].ad.vadr) === getPageBaseM(AbstractCore.dataCache.tlbFillEngine.notifiedTr.vadr)) begin
                        entries[i].ready = 1;                    
                    end
                end

                ES_DATA_MISS: begin
                    if (getBlockBaseD(entries[i].tr.padr) === getBlockBaseD(AbstractCore.dataCache.dataFillEngine.notifiedTr.padr)) begin
                        entries[i].ready = 1;
                    end
                end

                ES_UNCACHED_2: begin
                    if (AbstractCore.dataCache.uncachedSubsystem.uncachedReads[0].ready || isStoreMemUop(decUname(entries[i].uid))) begin
                        entries[i].ready = 1;
                    end
                end

                ES_SQ_MISS: begin
                    if (storeDataActive && U2M(entries[i].uid) > U2M(wrInput.TMP_oid))
                        entries[i].ready = 1;
                end

                ES_UNCACHED_1, ES_BARRIER_1, ES_AQ_REL_1: begin
                    if (U2M(entries[i].uid) == theRob.indToCommitSig.mid && AbstractCore.wqFree)
                        entries[i].ready = 1;
                end

                ES_LOWER_DONE:
                    entries[i].ready = 1;

                default: begin
                    if (entries[i].used && entries[i].p.active && entries[i].readyCnt > 0) begin
                        entries[i].readyCnt--;
                        entries[i].ready = (entries[i].readyCnt == 0);
                    end
                end
            endcase
        end

    endtask


    task automatic issue();
        UopPacket newPacket = EMPTY_UOP_PACKET;
        issued0 <= EMPTY_UOP_PACKET;
        
        foreach (entries[i]) begin
            if (entries[i].used && entries[i].ready && !entries[i].issued) begin                
                entries[i].issued = 1;

                putMilestone(entries[i].uid, InstructionMap::RqIssue);
                issued0 <= tickP(entries[i].p);
                break;
            end
        end
    endtask


    task automatic flush();
        foreach (entries[i]) begin
            if (shouldFlushId(U2M(entries[i].uid))) begin
                if (entries[i].used) putMilestone(entries[i].uid, InstructionMap::RqFlush);
                entries[i] = TMP_EMPTY_ENTRY;
            end
        end
    endtask


    function automatic int getNumUsed();
        int res = 0;
        foreach (entries[i]) if (entries[i].used) res++;
        return res;
    endfunction


    task automatic removeCanceled();
        foreach (entries[i]) begin
            if (0) ;
            else if (entries[i].outCnt == 2) begin
                entries[i] = TMP_EMPTY_ENTRY;
                putMilestone(entries[i].uid, InstructionMap::RqExit);
            end
            else if (entries[i].used && entries[i].cancel) entries[i].outCnt++;
        end    
    endtask


    function automatic InputLocs getInputLocs();
        InputLocs res = '{default: -1};
        int nFound = 0;

        foreach (entries[i])
            if (!entries[i].used) res[nFound++] = i;

        return res;
    endfunction


    assign accept = (numUsed <= SIZE - N_MEM_PORTS);
    always_comb outPacket = effP(issued0);

endmodule
