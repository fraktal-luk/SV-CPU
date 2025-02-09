
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

    input DataCacheOutput cacheResp,
    input UopPacket sqResp,
    input UopPacket lqResp
);

        localparam logic DISP_UNCACHED = 0;

    UopPacket p0, p1 = EMPTY_UOP_PACKET, pE0 = EMPTY_UOP_PACKET, pE1 = EMPTY_UOP_PACKET, pE2 = EMPTY_UOP_PACKET, pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
    UopPacket p0_E, p1_E, pE0_E, pE1_E, pE2_E, pD0_E, pD1_E;

    UopPacket stage0, stage0_E;
    
    logic readActive = 0, storeFlag = 0, uncachedFlag = 0;
    Mword effAdrE0 = 'x;

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

    assign readReq = '{
        readActive, storeFlag, uncachedFlag, effAdrE0
    };


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
        UopPacket stateE0 = tickP(p1);
        Mword adr = getEffectiveAddress(stateE0.TMP_oid);
        UopName uname = decUname(stateE0.TMP_oid);

        readActive <= stateE0.active && isMemUop(uname);
        storeFlag <= isStoreUop(uname);
        uncachedFlag <= (stateE0.status == ES_UNCACHED_1);
        effAdrE0 <= adr;

        pE0 <= updateE0(stateE0, adr);
    endtask
    
    task automatic performE1();
        UopPacket stateE1 = tickP(pE0);
        stateE1 = updateE1(stateE1);
        pE1 <= stateE1;
    endtask
    
    task automatic performE2();    
        UopPacket stateE2 = tickP(pE1);
        stateE2 = updateE2(stateE2, cacheResp, sqResp, lqResp);
        pE2 <= stateE2;
    endtask



    function automatic UopPacket updateE0(input UopPacket p, input Mword adr);
        UopPacket res = p;

        if (!p.active) return res;
      
        res.result = adr;
        
        return res; 
    endfunction



    function automatic UopPacket updateE1(input UopPacket p);
        UopPacket res = p;
        return res;
    endfunction


    function automatic UopPacket updateE2(input UopPacket p, input DataCacheOutput cacheResp, input UopPacket sqResp, input UopPacket lqResp);
        UopPacket res = p;
        UidT uid = p.TMP_oid;

        if (!p.active) return res;

        if (isLoadSysUop(decUname(uid)) || isStoreSysUop(decUname(uid))) begin
            res = TMP_updateSysTransfer(res);
            return res;
        end

        case (p.status)
            ES_UNCACHED_1: begin // 1st replay (2nd pass) of uncached mem access: send load request if it's a load, move to ES_UNCACHED_2
                if (DISP_UNCACHED) $display("..........................E1: uncached another pass, adr: %h", res.result);
                res.status = ES_UNCACHED_2;
                return res; // To RQ again
            end

            ES_UNCACHED_2: begin // 2nd replay (3rd pass) of uncached mem access: final result
                if (DISP_UNCACHED) $display("..........................E1: uncached final pass, adr: %h", res.result);
                res.status = ES_OK; // Go on to handle mem result
            end 

            // ES_TLB_MISS, ES_DATA_MISS: // integrate with SQ_MISS?
            ES_SQ_MISS, ES_OK,   ES_DATA_MISS,  ES_TLB_MISS: begin // TODO: untangle ES_SQ_MISS from here? 
                if (cacheResp.status == CR_TAG_MISS) begin
                    res.status = ES_DATA_MISS;
                    return res;
                end
                else if (cacheResp.status == CR_TLB_MISS) begin
                    res.status = ES_TLB_MISS;
                    return res;
                end

                if (!cacheResp.desc.cached) begin
                    if (DISP_UNCACHED) $error("..........................E1: Uncache adr: %h", res.result);
                    res.status = ES_UNCACHED_1;  
                    return res; // go to RQ
                end
            end

            default: $fatal(2, "Wrong status of memory op");
        endcase

        return updateE2_Regular(p, cacheResp, sqResp, lqResp);
    endfunction



    function automatic UopPacket TMP_updateSysTransfer(input UopPacket p);
        UopPacket res = p;
        UidT uid = p.TMP_oid;

        Mword3 args = insMap.getU(uid).argsA;

        if (res.result > 31) begin
            insMap.setException(U2M(p.TMP_oid)); // Exception on invalid sys reg access: set in relevant of SQ/LQ
            res.status = ES_ILLEGAL;
               // res.result = 'x;  // TODO: In Emulation, if access causes exceptino, set value to 'x, and do it here
        end
        
        if (isLoadSysUop(decUname(uid))) begin
            Mword val = getSysReg(args[1]);
            insMap.setActualResult(uid, val);
            res.result = val;
        end

        if (isStoreSysUop(decUname(uid))) begin
        end

        return res;
    endfunction

    function automatic UopPacket updateE2_Regular(input UopPacket p, input DataCacheOutput cacheResp, input UopPacket sqResp, input UopPacket lqResp);
        UopPacket res = p;
        UidT uid = p.TMP_oid;

        // No misses or special actions, typical load/store
        if (isLoadMemUop(decUname(uid))) begin
            if (sqResp.active) begin
                if (sqResp.status == ES_CANT_FORWARD) begin
                    res.status = ES_REFETCH;
                    insMap.setRefetch(U2M(uid)); // Refetch load that cannot be forwarded; set in LQ
                    res.result = 'x; // TMP
                end
                else if (sqResp.status == ES_SQ_MISS) begin            
                    res.status = ES_SQ_MISS;
                    res.result = 'x; // TMP
                end
                else begin
                    res.status = ES_OK;
                    res.result = sqResp.result;
                    putMilestone(uid, InstructionMap::MemFwConsume);
                end
            end
            else begin //no forwarding 
                res.status = ES_OK;
                res.result = cacheResp.data;
            end

            insMap.setActualResult(uid, res.result);
        end

        // Resp from LQ indicating that a younger load has a hazard
        if (isStoreMemUop(decUname(uid))) begin
            if (lqResp.active) begin
                insMap.setRefetch(U2M(lqResp.TMP_oid)); // Refetch oldest load that violated ordering; set in LQ
            end
            
            res.status = ES_OK; // TODO: don't set to OK if misses etc
        end

        return res;
    endfunction


    function automatic Mword getEffectiveAddress(input UidT uid);
        return (uid == UIDT_NONE) ? 'x : calcEffectiveAddress(getAndVerifyArgs(uid));
    endfunction

endmodule
