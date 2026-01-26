
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
    input UopPacket inPackets[N_MEM_PORTS],
        input UopPacket inputUops[N_MEM_PORTS],
        input UopPacket inputUopsE2[N_MEM_PORTS],

    output UopPacket outPacket
);

    localparam int SIZE = 16;
    localparam int TOTAL_SIZE = 32;

    typedef struct {
        // Scheduling state
        logic used;
        int readyCnt;
        logic ready_N;


            logic active;
            UidT uid;
            MemClass memClass;
            ExecStatus execStatus;
            
            Mword value;


        AccessDesc accessDesc;
        Translation translation;
    } Entry;



    localparam Entry EMPTY_ENTRY = '{0, -1, 0, 0, UIDT_NONE,  MC_NONE, ES_OK, 'x, DEFAULT_ACCESS_DESC, DEFAULT_TRANSLATION};


    typedef struct {
        logic used;
        UidT uid;
        logic issued;
            logic cancel;
        int cnt;
    } TMP_Entry;

    localparam TMP_Entry TMP_EMPTY_ENTRY = '{0, UIDT_NONE, 0, 0, -1};


    int numUsed = 0, New_numUsed = 0;
    logic accept;
    Entry content[SIZE] = '{default: EMPTY_ENTRY};
    Entry selected = EMPTY_ENTRY;


    TMP_Entry entries[TOTAL_SIZE] = {default: TMP_EMPTY_ENTRY};


    typedef int InputLocs[N_MEM_PORTS];

    function automatic InputLocs getInputLocs();
        InputLocs res = '{default: -1};
        int nFound = 0;

        foreach (content[i])
            if (!content[i].used) res[nFound++] = i;

        return res;
    endfunction

    function automatic InputLocs New_getInputLocs();
        InputLocs res = '{default: -1};
        int nFound = 0;

        foreach (entries[i])
            if (!entries[i].used) res[nFound++] = i;

        return res;
    endfunction



    UopPacket issued1 = EMPTY_UOP_PACKET, issued0 = EMPTY_UOP_PACKET;


    always @(posedge clk) begin
        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
           flush();
        end

        issue();
        wakeup();
        writeInput();



            New_writeInput();
            removeCanceled();


        removeIssued();

        issued1 <= tickP(issued0);
        numUsed <= getNumUsed();
            New_numUsed = New_getNumUsed();
    end


    task automatic writeInput();
        InputLocs inLocs = getInputLocs();
        
        foreach (inPackets[i]) begin
            if (inPackets[i].active) begin
                assert (numUsed < SIZE) else $fatal(2, "RQ full but writing");
                
                content[inLocs[i]] = '{inPackets[i].active, 15, 0,
                                        inPackets[i].active, inPackets[i].TMP_oid,
                                        inPackets[i].memClass, inPackets[i].status, inPackets[i].result,
                                        theExecBlock.adsReplayQueue[i], theExecBlock.trsReplayQueue[i]
                                        };
                putMilestone(inPackets[i].TMP_oid, InstructionMap::RqEnter);
            end
        end
    endtask


    task automatic New_writeInput();
        InputLocs inLocs = New_getInputLocs();

        foreach (inputUops[i]) begin
            if (inputUops[i].active) begin 
                // Already present?
                int inds[$] = entries.find_first_index with (item.uid == inputUops[i].TMP_oid);
                if (inds.size() > 0) begin
                    // entries[inds[0]].issued = 0;
                    // entries[inds[0]].cnt = -1;
                    continue;
                end
                entries[inLocs[i]] = '{1, inputUops[i].TMP_oid, 0, 0, -1}; 
            end
        end

        foreach (inputUopsE2[i]) begin
            if (inputUopsE2[i].active) begin 
                int inds[$] = entries.find_first_index with (item.uid == inputUopsE2[i].TMP_oid);

                if (!(inputUopsE2[i].status inside {ES_OK, ES_REFETCH})) begin
                    entries[inds[0]].cancel = 0;
                    entries[inds[0]].issued = 0;
                    entries[inds[0]].cnt = -1;
                    continue;
                end

                if (inds.size() > 0) begin
                    entries[inds[0]].cancel = 1;
                    entries[inds[0]].issued = 0;
                    entries[inds[0]].cnt = -1;
                    //continue;
                end
                //entries[inLocs[i]] = '{1, inputUops[i].TMP_oid, 0, -1}; 
            end//


            // if (inPackets[i].active) begin
            //     assert (numUsed < SIZE) else $fatal(2, "RQ full but writing");
                
            //     content[inLocs[i]] = '{inPackets[i].active, 15, 0,
            //                             inPackets[i].active, inPackets[i].TMP_oid,
            //                             inPackets[i].memClass, inPackets[i].status, inPackets[i].result,
            //                             theExecBlock.adsReplayQueue[i], theExecBlock.trsReplayQueue[i]
            //                             };
            //     putMilestone(inPackets[i].TMP_oid, InstructionMap::RqEnter);
            // end
        end
    endtask


    task automatic removeIssued();
        foreach (content[i]) begin
            if (content[i].used && !content[i].active) begin
                content[i] = EMPTY_ENTRY;
                putMilestone(content[i].uid, InstructionMap::RqExit);
            end
        end
    endtask


    task automatic wakeup();
        UopPacket wrInput = AbstractCore.theSq.submod.storeDataD2_E;
        logic storeDataActive = wrInput.active && (decUname(wrInput.TMP_oid) inside {UOP_data_int, UOP_data_fp});

        foreach (content[i]) begin
            case (content[i].execStatus)
                ES_TLB_MISS: begin
                    if (getPageBaseM(content[i].accessDesc.vadr) === getPageBaseM(AbstractCore.dataCache.tlbFillEngine.notifiedTr.vadr)) begin
                        content[i].ready_N = 1;                    
                    end
                end

                ES_DATA_MISS: begin
                    if (getBlockBaseD(content[i].translation.padr) === getBlockBaseD(AbstractCore.dataCache.dataFillEngine.notifiedTr.padr)) begin
                        content[i].ready_N = 1;
                    end
                end

                ES_UNCACHED_2: begin
                    if (AbstractCore.dataCache.uncachedSubsystem.uncachedReads[0].ready || isStoreMemUop(decUname(content[i].uid))) begin
                        content[i].ready_N = 1;
                    end
                end

                ES_SQ_MISS: begin
                    if (storeDataActive && U2M(content[i].uid) > U2M(wrInput.TMP_oid))
                        content[i].ready_N = 1;
                end

                ES_UNCACHED_1, ES_BARRIER_1, ES_AQ_REL_1: begin
                    if (U2M(content[i].uid) == theRob.indToCommitSig.mid && AbstractCore.wqFree)
                        content[i].ready_N = 1;
                end

                ES_LOWER_DONE:
                    content[i].ready_N = 1;

                default: begin
                    if (content[i].active && content[i].readyCnt > 0) begin
                        content[i].readyCnt--;
                        content[i].ready_N = (content[i].readyCnt == 0);
                    end
                end
            endcase
        end

    endtask


    task automatic issue();
        UopPacket newPacket = EMPTY_UOP_PACKET;
        int found[$];

        selected <= EMPTY_ENTRY;

        foreach (content[i]) begin
            if (content[i].active && (content[i].ready_N)) begin
                selected <= content[i];
                
                newPacket = '{1, content[i].uid, content[i].memClass, content[i].execStatus, EMPTY_POISON, content[i].value};
                
                putMilestone(content[i].uid, InstructionMap::RqIssue);
                content[i].active = 0;

                    found = entries.find_first_index with (item.used && item.uid == content[i].uid);
                    assert (found.size() == 1) else $error("wtf %d", found.size()); 

                    entries[found[0]].issued = 1;
                    entries[found[0]].cnt = 0;
                break;
            end
        end

        issued0 <= tickP(newPacket);
    endtask


    task automatic flush();
        foreach (content[i]) begin
            if (shouldFlushId(U2M(content[i].uid))) begin
                if (content[i].used) putMilestone(content[i].uid, InstructionMap::RqFlush);
                content[i] = EMPTY_ENTRY;
            end
        end

        if (shouldFlushId(U2M(selected.uid))) begin
            selected <= EMPTY_ENTRY;
        end


        foreach (entries[i]) begin
            if (shouldFlushId(U2M(entries[i].uid))) begin
                //if (entries[i].used) putMilestone(content[i].uid, InstructionMap::RqFlush);
                entries[i] = TMP_EMPTY_ENTRY;
            end
        end
    endtask


    function automatic int getNumUsed();
        int res = 0;
        foreach (content[i]) if (content[i].used) res++;
        return res;
    endfunction


    function automatic int New_getNumUsed();
        int res = 0;
        foreach (entries[i]) if (entries[i].used) res++;
        return res;
    endfunction


    task automatic removeCanceled();
        foreach (entries[i]) begin
            // if (entries[i].cancel && entries[i].cnt == -1) begin
            //     //entries[i] = TMP_EMPTY_ENTRY;
            //     entries[i].cnt = 0;
            // end
            if (0) ;
            else if (entries[i].cnt == 2) entries[i] = TMP_EMPTY_ENTRY;
            else if (entries[i].used && entries[i].cancel) entries[i].cnt++;
        end    
    endtask


    assign accept = numUsed < SIZE - 10; // TODO: make a sensible condition
    always_comb outPacket = effP(issued0);

endmodule
