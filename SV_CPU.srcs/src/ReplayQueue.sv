
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
        logic used;
        logic active;
        logic ready;
            int readyCnt;
            logic ready_N;
        ExecStatus execStatus;
        UidT uid;
        Mword adr;
    } Entry;

    localparam Entry EMPTY_ENTRY = '{0, 0, 0, -1, 0, ES_OK, UIDT_NONE, 'x};

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
        
        if (!(lateEventInfo.redirect || branchEventInfo.redirect)) // TODO: chek if condition not needed (flush is before)
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
            
            if (!inPackets[i].active) continue;
            
             //   if (inPackets[i].status == ES_NOT_READY) $error("RQ accepts not ready FW");
            effAdr = calcEffectiveAddress(insMap.getU(inPackets[i].TMP_oid).argsA);
            
            content[inLocs[i]] = '{inPackets[i].active, inPackets[i].active, 0 /*inPackets[i].active*/, 5,  0, inPackets[i].status, inPackets[i].TMP_oid, effAdr};
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
        UopPacket wrInput = AbstractCore.theSq.storeDataD2_E;

            foreach (content[i]) begin
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
               int found[$] = content.find_index with ((item.execStatus == ES_SQ_MISS) && (item.adr === wrInput.result) && (U2M(item.uid) > U2M(wrInput.TMP_oid))); // TODO: overlap
               foreach (found[j]) begin
                   content[found[j]].ready_N = 1;
                    //    putMilestone(wrInputs[p].TMP_oid, InstructionMap::WriteMemAddress);
               end
            end
        end
        
        // Entries waiting to be nonspeculative
        begin
            //int found[$] = content.find_index with (item.execStatus == ES_UNCACHED_1 && U2M(item.uid) == );
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
