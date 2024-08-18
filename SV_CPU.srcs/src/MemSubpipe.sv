
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;


module MemSubpipe(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input OpPacket opP,
    
    output DataReadReq readReq,
    input DataReadResp readResp
);
    Word result = 'x;
    OpPacket p0, p1 = EMPTY_OP_PACKET, pE0 = EMPTY_OP_PACKET, pE1 = EMPTY_OP_PACKET, pE2 = EMPTY_OP_PACKET, pD0 = EMPTY_OP_PACKET, pD1 = EMPTY_OP_PACKET;
    OpPacket p0_E, p1_E, pE0_E, pE1_E, pE2_E, pD0_E, pD1_E;

    OpPacket stateE0 = EMPTY_OP_PACKET, stateE1 = EMPTY_OP_PACKET, stateE2 = EMPTY_OP_PACKET;

    OpPacket stage0, stage0_E;
    
    logic readActive = 0;
    Word effAdr = 'x, storeValue = 'x;

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
    
    task automatic performE0();
        Word adr;
        Word val;
    
        stateE0 = tickP(p1);

        adr = getEffectiveAddress(stateE0.id);
        val = getStoreValue(stateE0.id);

        readActive <= stateE0.active;
        effAdr <= adr;
        storeValue <= val;

        if (stateE0.active) //performMemE0(stateE0.id);
                            performStore_Dummy(stateE0.id, adr, val);

        pE0 <= stateE0;
    endtask
    
    task automatic performE1();
        stateE1 = tickP(pE0);
        
        pE1 <= stateE1;
    endtask
    
    task automatic performE2();
        stateE2 = tickP(pE1);
        
        result <= 'x;
        if (pE1_E.active) result <= calcMemE2(pE1_E.id, readResp);
        
        pE2 <= stateE2;
    endtask



    function automatic Word getEffectiveAddress(input InsId id);
        if (id == -1) return 'x;
        
        begin
            AbstractInstruction abs = decId(id);
            Word3 args = getAndVerifyArgs(id);
            return calculateEffectiveAddress(abs, args);
        end
    endfunction

    function automatic Word getStoreValue(input InsId id);
        if (id == -1) return 'x;
        
        begin
            AbstractInstruction abs = decId(id);
            Word3 args = getAndVerifyArgs(id);
            return args[2];
        end
    endfunction


    // TOPLEVEL
//    task automatic performMemE0(input InsId id);
//        AbstractInstruction abs = decId(id);
//        Word adr = getEffectiveAddress(id);
//        Word val = getStoreValue(id);

//        if (isStoreMemIns(abs)) begin
//            checkStoreValue(id, adr, val);
            
//            putMilestone(id, InstructionMap::WriteMemAddress);
//            putMilestone(id, InstructionMap::WriteMemValue);
//        end
//    endtask

    task automatic performStore_Dummy(input InsId id, input Word adr, input Word val);
        AbstractInstruction abs = decId(id);

        if (isStoreMemIns(abs)) begin
            checkStoreValue(id, adr, val);
            
            putMilestone(id, InstructionMap::WriteMemAddress);
            putMilestone(id, InstructionMap::WriteMemValue);
        end
    endtask

    // TOPLEVEL
    function automatic Word calcMemE2(input InsId id, input DataReadResp readResp);
        AbstractInstruction abs = decId(id);
        Word3 args = getAndVerifyArgs(id);

        InsId writerAllId = AbstractCore.memTracker.checkWriter(id);

        logic forwarded = (writerAllId !== -1);
        Word fwValue = AbstractCore.memTracker.getStoreValue(writerAllId);
        Word memData = forwarded ? fwValue : readResp.result;
        Word data = isLoadSysIns(abs) ? getSysReg(args[1]) : memData;

        if (forwarded) begin
            putMilestone(writerAllId, InstructionMap::MemFwProduce);
            putMilestone(id, InstructionMap::MemFwConsume);
        end

        insMap.setActualResult(id, data);

        return data;
    endfunction

    // Used once by Mem subpipes
    function automatic void checkStoreValue(input InsId id, input Word adr, input Word value);
        Transaction tr[$] = AbstractCore.memTracker.stores.find with (item.owner == id);
        assert (tr[0].adr === adr && tr[0].val === value) else $error("Wrong store: op %d, %d@%d", id, value, adr);
    endfunction

endmodule


