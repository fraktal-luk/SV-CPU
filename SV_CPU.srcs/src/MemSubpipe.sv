
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
    output DataReadReq sysReadReq,
    output AccessDesc accessDescOut,
    
    input Translation cacheTranslation,
    input DataCacheOutput cacheResp,
    input DataCacheOutput sysRegResp,
    input UopPacket sqResp,
    input UopPacket lqResp
);

    UopMemPacket p0, p1 = EMPTY_UOP_PACKET, pE0 = EMPTY_UOP_PACKET, pE1 = EMPTY_UOP_PACKET, pE2 = EMPTY_UOP_PACKET, pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
    UopMemPacket p0_E, p1_E, pE0_E, pE1_E, pE2_E, pD0_E, pD1_E;
        UopPacket p0_Emp, p1_Emp, pE0_Emp, pE1_Emp, pE2_Emp, pD0_Emp, pD1_Emp;

    UopMemPacket stage0, stage0_E;
    
    AccessDesc accessDesc = DEFAULT_ACCESS_DESC;
    logic readActive = 0, sysReadActive = 0, storeFlag = 0, uncachedFlag = 0;
    AccessSize readSize = SIZE_NONE;
    Mword effAdrE0 = 'x;


    assign accessDescOut = accessDesc;

    //assign stage0 = pE2;
    assign stage0_E = pE2_E;
    assign p0 = TMP_toMemPacket(opP);


    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);

        performE0();
        performE1();
        performE2();
        
        pD0 <= tickP(pE2);
        pD1 <= tickP(pD0);
    end

    assign readReq = '{
        readActive, storeFlag, uncachedFlag, effAdrE0, readSize
    };

    assign sysReadReq = '{
        sysReadActive, 'x, 'x, effAdrE0, readSize
    };

    assign p0_E = effP(p0);
    assign p1_E = effP(p1);
    assign pE0_E = effP(pE0);
    assign pE1_E = effP(pE1);
    assign pE2_E = effP(pE2);
    assign pD0_E = effP(pD0);
    assign pD1_E = effP(pD1);


        assign p0_Emp = TMP_mp(p0_E);
        assign p1_Emp = TMP_mp(p1_E);
        assign pE0_Emp = TMP_mp(pE0_E);
        assign pE1_Emp = TMP_mp(pE1_E);
        assign pE2_Emp = TMP_mp(pE2_E);
        assign pD0_Emp = TMP_mp(pD0_E);
        assign pD1_Emp = TMP_mp(pD1_E);


    ForwardingElement image_E[-3:1];
    
    assign image_E = '{
        -3: p1_Emp,
        -2: pE0_Emp,
        -1: pE1_Emp,
        0: pE2_Emp,
        1: pD0_Emp,
        default: EMPTY_FORWARDING_ELEMENT
    };
    


    /////////////////////////////////////////////////////////////////////////////////////

    // 
    function automatic AccessDesc getAccessDesc(input UopMemPacket p, input Mword adr);
        AccessDesc res;
        UopName uname = decUname(p.TMP_oid);

        AccessInfo aInfo = analyzeAccess(adr, getTransactionSize(uname));

        if (!p.active) return res;

        res.active = 1;

        res.size = getTransactionSize(uname);
        
        res.store = isStoreUop(uname);
        res.sys = isLoadSysUop(uname) || isStoreSysUop(uname);
        res.uncachedReq = (p.status == ES_UNCACHED_1);
        res.uncachedCollect = (p.status == ES_UNCACHED_2);
        
//            readActive <= stateE0.active && isMemUop(uname);
//            sysReadActive <= stateE0.active && (isLoadSysUop(uname) || isStoreSysUop(uname));
//            storeFlag <= ;
//            uncachedFlag <= ;
        res.vadr = adr;

        res.unaligned = aInfo.unaligned;
        res.blockCross = aInfo.blockCross;
        res.pageCross = aInfo.pageCross;
    
        return res;
    endfunction 


 
    task automatic performE0();    
        UopMemPacket stateE0 = tickP(p1);
        Mword adr = getEffectiveAddress(stateE0.TMP_oid);
        UopName uname = decUname(stateE0.TMP_oid);
        
            accessDesc <= getAccessDesc(stateE0, adr);
        // TODO: structure this as extracting the "basic description" stage of mem uop
            readSize = getTransactionSize(uname);
            if (!stateE0.active) readSize = SIZE_NONE;
            
            readActive <= stateE0.active && isMemUop(uname);
            sysReadActive <= stateE0.active && (isLoadSysUop(uname) || isStoreSysUop(uname));
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
        UopMemPacket stateE2 = tickP(pE1);
        stateE2 = updateE2(stateE2, cacheResp, sysRegResp, sqResp, lqResp);
        pE2 <= stateE2;
    endtask



    function automatic UopMemPacket updateE0(input UopMemPacket p, input Mword adr);
        UopMemPacket res = p;

        if (!p.active) return res;
      
        res.result = adr;
        
        return res; 
    endfunction



    function automatic UopMemPacket updateE1(input UopMemPacket p);
        UopMemPacket res = p;
        return res;
    endfunction


    function automatic UopMemPacket updateE2(input UopMemPacket p, input DataCacheOutput cacheResp, input DataCacheOutput sysResp, input UopPacket sqResp, input UopPacket lqResp);
        UopMemPacket res = p;
        UidT uid = p.TMP_oid;

        if (!p.active) return res;

        if (isLoadSysUop(decUname(uid)) || isStoreSysUop(decUname(uid))) begin
            return TMP_updateSysTransfer(res, sysResp);
        end

        case (p.status)
            ES_UNCACHED_1: begin // 1st replay (2nd pass) of uncached mem access: send load request if it's a load, move to ES_UNCACHED_2
                res.status = ES_UNCACHED_2;
                return res; // To RQ again
            end

            ES_UNCACHED_2: begin // 2nd replay (3rd pass) of uncached mem access: final result
                res.status = ES_OK; // Go on to handle mem result
                // Continue processing
            end 

            ES_SQ_MISS, ES_OK,   ES_DATA_MISS,  ES_TLB_MISS: begin
                if (cacheResp.status == CR_TAG_MISS) begin
                    res.status = ES_DATA_MISS;
                    return res;
                end
                else if (cacheResp.status == CR_TLB_MISS) begin
                    res.status = ES_TLB_MISS;
                    return res;
                end

                if (!cacheResp.desc.cached) begin
                    res.status = ES_UNCACHED_1;  
                    return res; // go to RQ
                end
            end

            default: $fatal(2, "Wrong status of memory op");
        endcase
        
        return updateE2_Regular(p, cacheResp, sqResp, lqResp);
    endfunction



    function automatic UopMemPacket TMP_updateSysTransfer(input UopMemPacket p, input DataCacheOutput sysResp);
        UopMemPacket res = p;
        UidT uid = p.TMP_oid;

        if (sysResp.status == CR_INVALID) begin
            insMap.setException(U2M(p.TMP_oid)); // Exception on invalid sys reg access: set in relevant of SQ/LQ
            res.status = ES_ILLEGAL;
        end
        else begin
            res.status = ES_OK;
        end
        
        if (isLoadSysUop(decUname(uid))) begin
            insMap.setActualResult(uid, sysResp.data);
            res.result = sysResp.data;            
        end

        return res;
    endfunction
    

    function automatic UopMemPacket updateE2_Regular(input UopMemPacket p, input DataCacheOutput cacheResp, input UopPacket sqResp, input UopPacket lqResp);
        UopPacket res = p;
        UidT uid = p.TMP_oid;

        // No misses or special actions, typical load/store
        if (isLoadMemUop(decUname(uid))) begin
            if (sqResp.active) begin
                if (sqResp.status == ES_CANT_FORWARD) begin
                    res.status = ES_REFETCH;
                    insMap.setRefetch(U2M(uid)); // Refetch load that cannot be forwarded; set in LQ
                    res.result = 0; // TMP
                end
                else if (sqResp.status == ES_SQ_MISS) begin            
                    res.status = ES_SQ_MISS;
                    res.result = 0; // TMP
                end
                else begin
                    res.status = ES_OK;
                    res.result = loadValue(sqResp.result, decUname(uid));
                    putMilestone(uid, InstructionMap::MemFwConsume);
                end
            end
            else begin //no forwarding 
                res.status = ES_OK;
                res.result = loadValue(cacheResp.data, decUname(uid));
            end

            insMap.setActualResult(uid, res.result);
        end

        // Resp from LQ indicating that a younger load has a hazard
        if (isStoreMemUop(decUname(uid))) begin
            if (lqResp.active) begin
                insMap.setRefetch(U2M(lqResp.TMP_oid)); // Refetch oldest load that violated ordering; set in LQ
            end
            
            res.status = ES_OK;
        end

        return res;
    endfunction


    function automatic Mword getEffectiveAddress(input UidT uid);
        return (uid == UIDT_NONE) ? 'x : calcEffectiveAddress(getAndVerifyArgs(uid));
    endfunction

endmodule
