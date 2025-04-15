
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
    output UopPacket outPacket
);

    localparam int SIZE = 16;

    typedef struct {
        // Scheduling state
        logic used;
        logic active;
        logic ready;
          int readyCnt;
          logic ready_N;
        
        // uop status
        ExecStatus execStatus; 
        
        UidT uid;       // constant
            Mword adr;        // transaction desc
            AccessSize size;  // t.d.
    } Entry;

    localparam Entry EMPTY_ENTRY = '{0, 0, 0, -1, 0, ES_OK, UIDT_NONE, 'x, SIZE_NONE};

    int numUsed = 0;
    logic accept;
    Entry content[SIZE] = '{default: EMPTY_ENTRY};

    Entry selected = EMPTY_ENTRY;


    typedef int InputLocs[N_MEM_PORTS];
    InputLocs inLocs = '{default: -1};

    function automatic InputLocs getInputLocs();
        InputLocs res = '{default: -1};
        int nFound = 0;

        foreach (content[i])
            if (!content[i].used) res[nFound++] = i;

        return res;
    endfunction


    UopPacket issued1 = EMPTY_UOP_PACKET, issued0 = EMPTY_UOP_PACKET, issued0__ = EMPTY_UOP_PACKET;


    always @(posedge clk) begin
        if (lateEventInfo.redirect || branchEventInfo.redirect) begin
           flush();
        end
        
        
        issue();
        
        wakeup();
        
        writeInput();
       
        removeIssued();

        
          issued0__ <= tickP(inPackets[0]);
          issued0__.status <= ES_OK;

        issued1 <= tickP(issued0);
        
        numUsed <= getNumUsed();
    end


    task automatic writeInput();
        inLocs = getInputLocs();
        
        foreach (inPackets[i]) begin
            Mword effAdr;
            AccessSize trSize;
            
            if (!inPackets[i].active) continue;
            
            effAdr = calcEffectiveAddress(insMap.getU(inPackets[i].TMP_oid).argsA);
            trSize = getTransactionSize(decUname(inPackets[i].TMP_oid));
            
            content[inLocs[i]] = '{inPackets[i].active, inPackets[i].active, 0, 15,  0, inPackets[i].status, inPackets[i].TMP_oid, effAdr, trSize};
            putMilestone(inPackets[i].TMP_oid, InstructionMap::RqEnter);
        end
    endtask



    task automatic removeIssued();
        foreach (content[i]) begin
            if (content[i].used && !content[i].active) begin
                putMilestone(content[i].uid, InstructionMap::RqExit);
                content[i] = EMPTY_ENTRY;
            end
        end
    endtask



    task automatic wakeup();
        UopPacket wrInput = AbstractCore.theSq.submod.storeDataD2_E;
            
            // Temporary wakeup on timer for cases under development
            foreach (content[i]) begin
                // Exclude cases already implemented, leave only dev ones
                if (content[i].execStatus inside {ES_SQ_MISS, ES_UNCACHED_1,   ES_DATA_MISS    /*, ES_TLB_MISS*/   }) continue;
            
                if (content[i].active && content[i].readyCnt > 0) begin
                    content[i].readyCnt--;
                    content[i].ready = (content[i].readyCnt == 0);
                end
            end

        // Entries waiting for SQ data fill
        for (int i = 0; i < 1; i++) begin // Dummy loop to enable continue
            UopName uname;
            
            if (wrInput.active !== 1) continue;
        
            uname = decUname(wrInput.TMP_oid);            
            if (!(uname inside {UOP_data_int, UOP_data_fp})) continue;
           
            begin
               // FUTURE: Here we wake on every store data that is older than waiting op. Wait only for the latest store, already identified at FW scan?
               int found[$] = content.find_index with ((item.execStatus == ES_SQ_MISS) && (U2M(item.uid) > U2M(wrInput.TMP_oid)));
               foreach (found[j]) begin
                   content[found[j]].ready_N = 1;
               end
            end
        end
        
        // Entry waiting for uncached read data
        if (AbstractCore.dataCache.uncachedReads[0].ready) begin
            foreach (content[i]) begin
                if (content[i].execStatus == ES_UNCACHED_2) begin
                    content[i].ready_N = 1;
                end
            end
        end
        
        
        // Entry waiting to be nonspeculative
        // TODO: assure that this wakeup can't happen while preceding uncached store is being committed - hazard between setting wqFree to 0 and setting this Mid to next committed
        if (AbstractCore.wqFree) begin // Must wait for uncached writes to complete
            int found[$] = content.find_index with (!item.ready_N && item.execStatus == ES_UNCACHED_1 && U2M(item.uid) == theRob.indToCommitSig.mid);            
            assert (found.size() <= 1) else $fatal(2, "Repeated mid in RQ");
            
            if (found.size() != 0) begin
                content[found[0]].ready_N = 1;
            end
        end
        
        // Wakeup data misses
        if (AbstractCore.dataCache.notifyFill) begin
            foreach (content[i]) begin
                if (blockBaseD(content[i].adr) === blockBaseD(AbstractCore.dataCache.notifiedAdr)) begin// TODO: consider that cache fill by physical adr!
                    content[i].ready_N = 1;
                end
            end
        end
        
        // Wakeup TLB misses
        if (AbstractCore.dataCache.notifyTlbFill) begin
            foreach (content[i]) begin
                if (adrHigh(content[i].adr) === adrHigh(AbstractCore.dataCache.notifiedTlbAdr)) begin// TODO: consider that cache fill by physical adr!
                    content[i].ready_N = 1;                    
                end
            end
        end
    endtask
    
    
    task automatic issue();
        UopPacket newPacket = EMPTY_UOP_PACKET;
    
        selected <= EMPTY_ENTRY;

        foreach (content[i]) begin
            if (content[i].active && (content[i].ready_N || content[i].ready)) begin
                selected <= content[i];
                
                newPacket = '{1, content[i].uid, content[i].execStatus, EMPTY_POISON, 'x};
                
                putMilestone(content[i].uid, InstructionMap::RqIssue);
                content[i].active = 0;
                break;
            end
        end
           
        issued0 <= tickP(newPacket);
    endtask


    task automatic flush();
        foreach (content[i]) begin
            if (lateEventInfo.redirect || (branchEventInfo.redirect && U2M(content[i].uid) > branchEventInfo.eventMid)) begin
                if (content[i].used) putMilestone(content[i].uid, InstructionMap::RqFlush);
                content[i] = EMPTY_ENTRY;
            end
        end
        
        if (lateEventInfo.redirect || (branchEventInfo.redirect && U2M(selected.uid) > branchEventInfo.eventMid)) begin
            selected = EMPTY_ENTRY;
        end
    endtask

    function automatic int getNumUsed();
        int res = 0;
        
        foreach (content[i]) if (content[i].used) res++;
        
        return res;
    endfunction



    assign accept = numUsed < SIZE - 5;
    assign outPacket = effP(issued0);

endmodule
