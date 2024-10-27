
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;


module MemSubpipe#(
    parameter logic HANDLE_UNALIGNED = 0
)
(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input UopPacket opP,
    
    output DataReadReq readReq,
    input DataReadResp readResp,
    
    input UopPacket sqResp,
    input UopPacket lqResp
);
    Mword result = 'x;
    UopPacket p0, p1 = EMPTY_UOP_PACKET, pE0 = EMPTY_UOP_PACKET, pE1 = EMPTY_UOP_PACKET, pE2 = EMPTY_UOP_PACKET, pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
    UopPacket p0_E, p1_E, pE0_E, pE1_E, pE2_E, pD0_E, pD1_E;

    UopPacket stateE0 = EMPTY_UOP_PACKET, stateE1 = EMPTY_UOP_PACKET, stateE2 = EMPTY_UOP_PACKET;

    UopPacket stage0, stage0_E;
    
    logic readActive = 0;
    Mword effAdr = 'x, storeValue = 'x;

    assign stage0 = setResult(pE2, result);
    assign stage0_E = setResult(pE2_E, result);

    assign p0 = opP;


    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);

        performE0();
        performE1();
        performE2();
        
        pD0 <= tickP(pE2);
        pD1 <= tickP(pD0);
    end

    assign readReq = '{/*pE0_E.active*/readActive, effAdr};


    assign p0_E = effP(p0);
    assign p1_E = effP(p1);
    assign pE0_E = effP(pE0);
    assign pE1_E = effP(pE1);
    assign pE2_E = effP(pE2);
    assign pD0_E = effP(pD0);
    assign pD1_E = effP(pD1);
    
    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -3: p1_E,
        -2: pE0_E,
        -1: pE1_E,
        0: pE2_E,
        1: pD0_E,
        default: EMPTY_FORWARDING_ELEMENT
    };
    


    /////////////////////////////////////////////////////////////////////////////////////
    
    function automatic UopPacket updateE0(input UopPacket p, input Mword adr);
        UopPacket res = p;
        
        if (p.active && isLoadSysIns(decId(p.TMP_oid)) && adr > 31) begin
            insMap.setException(p.TMP_oid);
            return res;
        end
        
        if (p.active && isStoreSysIns(decId(p.TMP_oid)) && adr > 31) begin
            insMap.setException(p.TMP_oid);
            return res;
        end
        
        if (p.active && isMemIns(decId(p.TMP_oid)) && (adr % 4) != 0 && !HANDLE_UNALIGNED) res.status = ES_UNALIGNED;
        
        res.result = adr;
        
        return res; 
    endfunction
    
    
    task automatic performE0();
        Mword adr;
        Mword val;
    
        stateE0 = tickP(p1);

        adr = getEffectiveAddress(stateE0.TMP_oid);
        val = getStoreValue(stateE0.TMP_oid);

        readActive <= stateE0.active;
        effAdr <= adr;
        storeValue <= val;

        pE0 <= updateE0(stateE0, adr);
    endtask
    
    task automatic performE1();
        stateE1 = tickP(pE0);
        
        if (stateE1.active && stateE1.status == ES_OK) performStore_Dummy(stateE1.TMP_oid, effAdr, storeValue);
        
        pE1 <= stateE1;
    endtask
    
    task automatic performE2();
        Mword resultE2;
    
        stateE2 = tickP(pE1);
        
        resultE2 = 'x;
        if (stateE2.active) stateE2 = calcMemE2(stateE2, stateE2.TMP_oid, readResp, sqResp, lqResp);
        result <= stateE2.result;
        
        pE2 <= stateE2;
    endtask



    function automatic Mword getEffectiveAddress(input InsId id);
        if (id == -1) return 'x;
        
        begin
            AbstractInstruction abs = decId(id);
            Mword3 args = getAndVerifyArgs(id);
            return calculateEffectiveAddress(abs, args);
        end
    endfunction

    function automatic Mword getStoreValue(input InsId id);
        if (id == -1) return 'x;
        
        begin
            AbstractInstruction abs = decId(id);
            Mword3 args = getAndVerifyArgs(id);
            return args[2];
        end
    endfunction




    task automatic performStore_Dummy(input InsId id, input Mword adr, input Mword val);
        AbstractInstruction abs = decId(id);
        
        if (isStoreMemIns(abs)) begin
            checkStoreValue(id, adr, val);
            
            putMilestone(id, InstructionMap::WriteMemAddress);
            putMilestone(id, InstructionMap::WriteMemValue);
        end
    endtask

    // TOPLEVEL
    function automatic UopPacket calcMemE2(input UopPacket p, input InsId id, input DataReadResp readResp, input UopPacket sqResp, input UopPacket lqResp);
        UopPacket res = p;
        AbstractInstruction abs = decId(id);
        Mword3 args = getAndVerifyArgs(id);

        InsId writerAllId = AbstractCore.memTracker.checkWriter(id);
            InsId writerOverlapId = AbstractCore.memTracker.checkWriter_Overlap(id);
            InsId writerInsideId = AbstractCore.memTracker.checkWriter_Inside(id);
        
        logic forwarded = (writerAllId !== -1);
        
        Mword fwValue = AbstractCore.memTracker.getStoreValue(writerAllId);
        Mword memData = forwarded ? fwValue : readResp.result;
        Mword data = isLoadSysIns(abs) ? getSysReg(args[1]) : memData;

            if (writerOverlapId != writerInsideId) begin
               // $error("Cannot forward from last overlapping store!");
                if (HANDLE_UNALIGNED) begin
                    res.status = ES_REDO;
                   // $error("setting refetch, id = %d", id);
                    insMap.setRefetch(id);
                end
            end
            
            // Resp from LQ indicating that a younger load has a hazard
            if (isStoreMemIns(decId(id))) begin
                if (lqResp.active) begin
                    insMap.setRefetch(lqResp.TMP_oid);
                end
            end
            
            if (isLoadMemIns(decId(id)))  assert (forwarded === sqResp.active) else begin
                InstructionInfo thisInfo, writerInfo;
                if (id != -1) thisInfo = insMap.get(id);
                if (writerAllId != -1) writerInfo = insMap.get(writerAllId);

            end
            
        if (forwarded && isLoadMemIns(decId(id))) begin
              //  assert (writerInsideId == sqResp.i d) else $error("SQ i d not matchinf memTracker id");
            putMilestoneC(writerAllId, InstructionMap::MemFwProduce);
            putMilestone(id, InstructionMap::MemFwConsume);
        end

        insMap.setActualResult(id, data);

        res.result = data;

        return //data;
                res;
    endfunction

    // Used once by Mem subpipes
    function automatic void checkStoreValue(input InsId id, input Mword adr, input Mword value);
        Transaction tr[$] = AbstractCore.memTracker.stores.find with (item.owner == id);
        assert (tr[0].adr === adr && tr[0].val === value) else $error("Wrong store: op %d, %d@%d", id, value, adr);
    endfunction

endmodule


