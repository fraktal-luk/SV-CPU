
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import EmulationDefs::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;


module MemSubpipe#()
(
    ref InstructionMap insMap,
    input EventInfo branchEventInfo,
    input EventInfo lateEventInfo,
    input UopPacket opP,

    output AccessDesc accessDescOut,

    input Translation cacheTranslation,
    input DataCacheOutput cacheResp,
    input DataCacheOutput uncachedResp,
    input DataCacheOutput sysRegResp,
    input UopPacket sqResp
);

    UopMemPacket p0, p1 = EMPTY_UOP_PACKET, pE0 = EMPTY_UOP_PACKET, pE1 = EMPTY_UOP_PACKET, pE2 = EMPTY_UOP_PACKET, pD0 = EMPTY_UOP_PACKET, pD1 = EMPTY_UOP_PACKET;
    UopMemPacket p0_E, p1_E, pE0_E, pE1_E, pE2_E, pD0_E, pD1_E;
        UopPacket p0_Emp, p1_Emp, pE0_Emp, pE1_Emp, pE2_Emp, pD0_Emp, pD1_Emp;
    Translation trE0, trE1 = DEFAULT_TRANSLATION, trE2 = DEFAULT_TRANSLATION;


    UopMemPacket stage0, stage0_E;
    
    AccessDesc accessDescE0 = DEFAULT_ACCESS_DESC, accessDescE1 = DEFAULT_ACCESS_DESC, accessDescE2 = DEFAULT_ACCESS_DESC;

    assign accessDescOut = accessDescE0;

    always_comb stage0_E = pE2_E;
    always_comb p0 = TMP_toMemPacket(opP);

    assign trE0 = cacheTranslation;


    always @(posedge AbstractCore.clk) begin
        p1 <= tickP(p0);

        performE0();
        performE1();
        performE2();

        pD0 <= tickP(pE2);
        pD1 <= tickP(pD0);

        trE1 <= trE0;
        trE2 <= trE1;

        accessDescE1 <= accessDescE0;
        accessDescE2 <= accessDescE1;
    end


    always_comb p0_E = effP(p0);
    always_comb p1_E = effP(p1);
    always_comb pE0_E = effP(pE0);
    always_comb pE1_E = effP(pE1);
    always_comb pE2_E = effP(pE2);
    always_comb pD0_E = effP(pD0);
    always_comb pD1_E = effP(pD1);


        always_comb p0_Emp = TMP_mp(p0_E);
        always_comb p1_Emp = TMP_mp(p1_E);
        always_comb pE0_Emp = TMP_mp(pE0_E);
        always_comb pE1_Emp = TMP_mp(pE1_E);
        always_comb pE2_Emp = TMP_mp(pE2_E);
        always_comb pD0_Emp = TMP_mp(pD0_E);
        always_comb pD1_Emp = TMP_mp(pD1_E);


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
        res.uncachedReq = (p.status == ES_UNCACHED_1) && !res.store;
        res.uncachedCollect = (p.status == ES_UNCACHED_2) && !res.store;
        res.uncachedStore = (p.status == ES_UNCACHED_2) && res.store;

            res.acq = isLoadAqUop(uname) && p.status == ES_AQ_REL_1;
            res.rel = isStoreRelUop(uname) && p.status == ES_AQ_REL_1;

        res.vadr = adr;

        res.blockIndex = aInfo.block;
        res.blockOffset = aInfo.blockOffset;

        res.unaligned = aInfo.unaligned;
        res.blockCross = aInfo.blockCross;
        res.pageCross = aInfo.pageCross;
    
        return res;
    endfunction 


 
    task automatic performE0();    
        UopMemPacket stateE0 = tickP(p1);
        Mword adr = getEffectiveAddress(stateE0.TMP_oid);

        accessDescE0 <= getAccessDesc(stateE0, adr);
        pE0 <= updateE0(stateE0, adr);
    endtask
    
    task automatic performE1();
        UopPacket stateE1 = tickP(pE0);
        stateE1 = updateE1(stateE1);
        pE1 <= stateE1;
    endtask
    
    task automatic performE2();    
        UopMemPacket stateE2 = tickP(pE1);
        stateE2 = updateE2(stateE2, cacheResp, uncachedResp, sysRegResp, sqResp);
        pE2 <= stateE2;
    endtask



    function automatic UopMemPacket updateE0(input UopMemPacket p, input Mword adr);
        UopMemPacket res = p;
        UopName uname;

        if (!p.active) return res;
      
        uname = decUname(p.TMP_oid);

        res.result = adr;

            // Classify
            if (p.memClass == MC_NONE) begin
                if (isLoadAqUop(uname) || isStoreRelUop(uname)) begin
                    res.memClass = MC_AQ_REL;
                end
                else if (isMemBarrierUop(uname)) begin
                    res.memClass = MC_BARRIER;
                end
                else if (isLoadSysUop(uname) || isStoreSysUop(uname)) begin
                    res.memClass = MC_SYS;
                end
                else begin
                    res.memClass = MC_NORMAL;
                end

            end
        
        return res; 
    endfunction



    function automatic UopMemPacket updateE1(input UopMemPacket p);
        UopMemPacket res = p;
        return res;
    endfunction


    function automatic UopMemPacket updateE2(input UopMemPacket p, input DataCacheOutput cacheResp, input DataCacheOutput uncachedResp, input DataCacheOutput sysResp, input UopPacket sqResp);
        UopMemPacket res = p;
        UidT uid = p.TMP_oid;
        UopName uname;

        if (!p.active) return res;

        uname = decUname(uid);


        // Sys flow
        // TODO: can use accessDesc for this choice
        if (isLoadSysUop(uname) || isStoreSysUop(uname)) begin

                assert (p.memClass == MC_SYS) else $fatal(2, "Wrong class for sys");

            return TMP_updateSysTransfer(res, sysResp);
        end


        case (p.status)

            // Uncached flow
            ES_UNCACHED_1: begin // 1st replay (2nd pass) of uncached mem access: send load request if it's a load, move to ES_UNCACHED_2
                    assert (p.memClass == MC_UNCACHED) else $fatal(2, "Wrong class for uncached");


                res.status = ES_UNCACHED_2;
                return res; // To RQ again
            end

            ES_UNCACHED_2: begin // 2nd replay (3rd pass) of uncached mem access: final result
                assert (!cacheResp.active) else $error("Why cache resp\n%p\n%p", uncachedResp, cacheResp);

                        assert (p.memClass == MC_UNCACHED) else $fatal(2, "Wrong class for uncached");


                if (uncachedResp.status == CR_HIT) begin 
                    res.status = ES_OK; // Go on to handle mem result
                    res.result = loadValue(uncachedResp.data, uname);
                    insMap.setActualResult(uid, res.result);
                    return res;
                end
                else if (uncachedResp.status == CR_INVALID) begin
                    res.status = ES_ILLEGAL;
                    res.result = 0;
                    insMap.setException(U2M(p.TMP_oid), PE_MEM_INVALID_ADDRESS);
                    return res;
                end
                else
                    $fatal(2, "Wrong status %p", cacheResp.status);
            end

            // Barrier flow
            ES_BARRIER_1: begin
                    assert (p.memClass == MC_BARRIER) else $fatal(2, "Wrong class for barrier");

                res.status = ES_OK;
                return res;
            end

            // Aq-rel flow
            ES_AQ_REL_1: begin
                        assert (p.memClass == MC_AQ_REL) else $fatal(2, "Wrong class for aq-rel");

                if (0) begin
                end

                // The same flow as for normal mem ops
                else if (cacheResp.status == CR_TAG_MISS) begin
                    res.status = ES_DATA_MISS;
                    return res;
                end
                else if (cacheResp.status == CR_TLB_MISS) begin
                    res.status = ES_TLB_MISS;
                    return res;
                end
                else if (cacheResp.status == CR_NOT_ALLOWED) begin
                    insMap.setException(U2M(p.TMP_oid), PE_MEM_DISALLOWED_ACCESS);
                    res.status = ES_ILLEGAL;
                    return res;
                end
                else if (cacheResp.status == CR_UNCACHED) begin
                        $fatal(2, "Dont use aq-rel on uncached memory!");
                    res.status = ES_UNCACHED_1;  
                    return res; // go to RQ
                end
                //else: _Regular
            end

            // Normal or aq-rel flow
            ES_SQ_MISS, ES_OK,   ES_DATA_MISS,  ES_TLB_MISS,   ES_BEGIN: begin
                if (isLoadAqUop(uname) || isStoreRelUop(uname)) begin
                        assert (p.memClass == MC_AQ_REL) else $fatal(2, "Wrong class for aq-rel");

                    res.status = ES_AQ_REL_1;           // other flow 
                    return res; // go to RQ
                end
                else if (isMemBarrierUop(uname)) begin
                        assert (p.memClass == MC_BARRIER) else $fatal(2, "Wrong class for barrier");

                    res.status = ES_BARRIER_1;          // other flow 
                    return res; // go to RQ
                end

                // Normal mem flow
                else if (cacheResp.status == CR_TAG_MISS) begin
                    res.status = ES_DATA_MISS;
                    return res;
                end
                else if (cacheResp.status == CR_TLB_MISS) begin
                    res.status = ES_TLB_MISS;
                    return res;
                end
                else if (cacheResp.status == CR_NOT_ALLOWED) begin
                    insMap.setException(U2M(p.TMP_oid), PE_MEM_DISALLOWED_ACCESS);
                    res.status = ES_ILLEGAL;
                    return res;
                end
                else if (cacheResp.status == CR_UNCACHED) begin
                        res.memClass = MC_UNCACHED;   // other flow
                    res.status = ES_UNCACHED_1;  
                    return res; // go to RQ
                end
                // else: _Regular
            end

            default: $fatal(2, "Wrong status of memory op");
        endcase
        
        assert (!uncachedResp.active) else $error("Why uncched\n%p\n%p", uncachedResp, cacheResp);
        
        return updateE2_Regular(p, cacheResp, sqResp);
    endfunction



    function automatic UopMemPacket TMP_updateSysTransfer(input UopMemPacket p, input DataCacheOutput sysResp);
        UopMemPacket res = p;
        UidT uid = p.TMP_oid;

        if (sysResp.status == CR_INVALID) begin
            insMap.setException(U2M(p.TMP_oid), PE_SYS_INVALID_ADDRESS); // Exception on invalid sys reg access: set in relevant of SQ/LQ
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

    // TODO: sqResp - change to DataCacheOutput?
    function automatic UopMemPacket updateE2_Regular(input UopMemPacket p, input DataCacheOutput cacheResp, input UopPacket sqResp);
        UopPacket res = p;
        UidT uid = p.TMP_oid;

            assert (!(p.memClass inside {MC_UNCACHED, MC_SYS, MC_BARRIER})) else $fatal(2, "Wrong class for %p", p.memClass);


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
                assert (cacheResp.status != CR_UNCACHED) else $error("unc response"); // NEVER
                res.status = ES_OK;
                res.result = loadValue(cacheResp.data, decUname(uid));
            end

            insMap.setActualResult(uid, res.result);
        end

        if (isStoreMemUop(decUname(uid))) begin            
            res.status = ES_OK;
        end

        return res;
    endfunction


    function automatic Mword getEffectiveAddress(input UidT uid);
        return (uid == UIDT_NONE) ? 'x : calcEffectiveAddress(getAndVerifyArgs(uid));
    endfunction

endmodule
