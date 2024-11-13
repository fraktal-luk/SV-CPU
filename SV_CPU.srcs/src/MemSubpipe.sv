
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
    UopPacket p0, p1 = EMPTY_UOP_PACKET, pE0 = EMPTY_UOP_PACKET, pE1 = EMPTY_UOP_PACKET, pE2 = EMPTY_UOP_PACKET, pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
    UopPacket p0_E, p1_E, pE0_E, pE1_E, pE2_E, pD0_E, pD1_E;

    UopPacket stage0, stage0_E;
    
    logic readActive = 0;
    Mword effAdr = 'x;//, storeValue = 'x;

    assign stage0 = pE2;
    assign stage0_E = pE2_E;
    assign p0 = opP;


    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);

        performE0();
        performE1();
        performE2();
        
        pD0 <= tickP(pE2);
        pD1 <= tickP(pD0);
    end

    assign readReq = '{readActive, effAdr};


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
        UidT uid = p.TMP_oid; 

        if (p.active && isLoadSysUop(decUname(uid)) && adr > 31) begin
            insMap.setException(U2M(p.TMP_oid));
            return res;
        end
        
        if (p.active && isStoreSysUop(decUname(uid)) && adr > 31) begin
            insMap.setException(U2M(p.TMP_oid));
            return res;
        end
        
        if (p.active && isMemUop(decUname(uid)) && (adr % 4) != 0 && !HANDLE_UNALIGNED) res.status = ES_UNALIGNED;
        
        res.result = adr;
        
        return res; 
    endfunction
    
    
    task automatic performE0();
        Mword adr;
        //Mword val;
    
        UopPacket stateE0 = tickP(p1);

        adr = getEffectiveAddress(stateE0.TMP_oid);
        //val = getStoreValue(stateE0.TMP_oid);

        readActive <= stateE0.active;
        effAdr <= adr;
        //storeValue <= val;

        pE0 <= updateE0(stateE0, adr);
    endtask
    
    task automatic performE1();
        UopPacket stateE1 = tickP(pE0);
        //if (stateE1.active && stateE1.status == ES_OK) performStore_Dummy(stateE1.TMP_oid, effAdr, storeValue);

        pE1 <= stateE1;
    endtask
    
    task automatic performE2();    
        UopPacket stateE2 = tickP(pE1);
        if (stateE2.active) stateE2 = calcMemE2(stateE2, stateE2.TMP_oid, readResp, sqResp, lqResp);
        
        pE2 <= stateE2;
    endtask


    function automatic Mword getEffectiveAddress(input UidT uid);
        if (uid == UIDT_NONE) return 'x;
        return calcEffectiveAddress(getAndVerifyArgs(uid));
    endfunction

//    function automatic Mword getStoreValue(input UidT uid);
//        if (uid == UIDT_NONE) return 'x;
//        begin
//            Mword3 args = getAndVerifyArgs(uid);
//            return args[2];
//        end
//    endfunction


    function automatic Mword calcEffectiveAddress(Mword3 args);
        return args[0] + args[1];
    endfunction



//    task automatic performStore_Dummy(input UidT uid, input Mword adr, input Mword val);
//        if (isStoreMemUop(decUname(uid))) begin
//        //    checkStore(uid, adr, val);
//            //putMilestone(uid, InstructionMap::WriteMemAddress);
////            putMilestone(uid, InstructionMap::WriteMemValue); // TODO: move this to SD subpipe
//        end
//    endtask

    // TOPLEVEL
    function automatic UopPacket calcMemE2(input UopPacket p, input UidT uid, input DataReadResp readResp, input UopPacket sqResp, input UopPacket lqResp);
        UopPacket res = p;
        Mword3 args = getAndVerifyArgs(uid);

        InsId writerAllId = AbstractCore.memTracker.checkWriter(U2M(uid));
        InsId writerOverlapId = AbstractCore.memTracker.checkWriter_Overlap(U2M(uid));
        InsId writerInsideId = AbstractCore.memTracker.checkWriter_Inside(U2M(uid));
    
        logic forwarded = (writerAllId !== -1);
        
        Mword fwValue = AbstractCore.memTracker.getStoreValue(writerAllId);
        Mword memData = forwarded ? fwValue : readResp.result;
        Mword data = isLoadSysUop(decUname(uid)) ? getSysReg(args[1]) : memData;

        if (writerOverlapId != writerInsideId) begin
            if (HANDLE_UNALIGNED) begin
                res.status = ES_REDO;
                insMap.setRefetch(U2M(uid));
            end
        end
        
        // Resp from LQ indicating that a younger load has a hazard
        if (isStoreMemUop(decUname(uid))) begin
            if (lqResp.active) begin
                insMap.setRefetch(U2M(lqResp.TMP_oid));
            end
        end
        
        if (isLoadMemUop(decUname(uid))) begin
            // TODO: make sure the behavior is correct
            //assert (forwarded === sqResp.active) else $error("Wrong forward state");
        end
            
        if (forwarded && isLoadMemUop(decUname(uid))) begin
                putMilestoneC(writerAllId, InstructionMap::MemFwProduce);
            putMilestone(uid, InstructionMap::MemFwConsume);
        end

        insMap.setActualResult(uid, data);

        res.result = data;

        return res;
    endfunction

//    // Used once by Mem subpipes
//    function automatic void checkStore(input UidT uid, input Mword adr, input Mword value);
//        Transaction tr[$] = AbstractCore.memTracker.stores.find with (item.owner == U2M(uid));
//        assert (tr[0].adr === adr && tr[0].val === value) else $error("Wrong store: op %p, %d@%d", uid, value, adr);
//    endfunction

endmodule


