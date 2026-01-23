
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
    Translation tr0;
    AccessDesc ad0;

    AccessDesc accessDescE0 = DEFAULT_ACCESS_DESC, accessDescE1 = DEFAULT_ACCESS_DESC, accessDescE2 = DEFAULT_ACCESS_DESC;

    assign accessDescOut = accessDescE0;

    always_comb stage0_E = pE2_E;
    assign tr0 = trE2;
    assign ad0 = accessDescE2;

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
    function automatic AccessDesc getAccessDesc(input UopMemPacket p, input Mword adr, input logic isUpper);
        AccessDesc res;
        UopName uname = decUname(p.TMP_oid);

        Mword vadr = isUpper ? adr - (adr % 4) + 4 : adr;

        AccessInfo aInfo = analyzeAccess(vadr, getTransactionSize(uname));

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

        if (isStoreRelUop(uname) && p.status == ES_BEGIN) res.active = 0; // Don't cause lock clearing by idle run
        if (isMemBarrierUop(uname) && !isLoadAqUop(uname)) res.active = 0; // Pure barriers don't make access

        res.vadr = vadr;

        res.blockIndex = aInfo.block;
        res.blockOffset = aInfo.blockOffset;

        res.unaligned = aInfo.unaligned;
        res.blockCross = aInfo.blockCross;
        res.pageCross = aInfo.pageCross;
    
        res.shift = isUpper ? (adr % 4) : 0;

        return res;
    endfunction 


 
    task automatic performE0();    
        UopMemPacket stateE0 = tickP(p1);
        Mword adr = getEffectiveAddress(stateE0.TMP_oid);
        accessDescE0 <= getAccessDesc(stateE0, adr, (p1.memClass == MC_UPPER_B));
        pE0 <= updateE0(stateE0, adr);
    endtask
    
    task automatic performE1();
        UopPacket stateE1 = tickP(pE0);
        stateE1 = updateE1(stateE1);
        pE1 <= stateE1;
    endtask
    
    task automatic performE2();    
        UopMemPacket stateE2 = tickP(pE1);
        stateE2 = updateE2(stateE2, accessDescE1, cacheResp, uncachedResp, sysRegResp, sqResp);
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


    function automatic UopMemPacket updateE2(input UopMemPacket p, input AccessDesc ad,
                                            input DataCacheOutput cacheResp, input DataCacheOutput uncachedResp, input DataCacheOutput sysResp, input UopPacket sqResp);
        UopMemPacket res = p;
        UidT uid = p.TMP_oid;
        UopName uname;

        if (!p.active) return res;

        uname = decUname(uid);

        case (p.memClass)
            MC_SYS: begin
                return TMP_updateSysTransfer(res, sysResp);
            end

            MC_BARRIER: begin
                case (p.status)
                    ES_BEGIN: res.status = ES_BARRIER_1;
                    ES_BARRIER_1: res.status = ES_OK;
                    default: $fatal(2, "blbleee");
                endcase
                return res;
            end

            MC_AQ_REL: begin
                case (p.status)
                    ES_BEGIN: begin
                        if (ad.unaligned) $fatal(2, "aq-rel uncached!");

                        res.status = ES_AQ_REL_1;
                        return res;
                    end
                    default: ; // Go on
                endcase
            end


            MC_UNCACHED: begin
                case (p.status)

                    // Uncached flow
                    ES_UNCACHED_1: begin // 1st replay (2nd pass) of uncached mem access: send load request if it's a load, move to ES_UNCACHED_2
                        res.status = ES_UNCACHED_2;
                        return res; // To RQ again
                    end

                    ES_UNCACHED_2: begin // 2nd replay (3rd pass) of uncached mem access: final result
                        assert (!cacheResp.active) else $error("Why cache resp\n%p\n%p", uncachedResp, cacheResp);

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
                    
                    default: $fatal(2, "wrong state");

                endcase
            end

            MC_NORMAL, MC_UPPER_B: ;

            default: $fatal(2, "Wrong memClass %p", p.memClass);
        endcase


        // Normal mem flow
        if (cacheResp.status == CR_TAG_MISS) begin
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
            if (p.memClass != MC_NORMAL) begin
                res.status = ES_ILLEGAL;
                return res;
            end
            if (ad.unaligned) begin
                res.status = ES_ILLEGAL;
                return res;
            end

            res.memClass = MC_UNCACHED;   // other flow
            if (p.status == ES_BEGIN) res.status = ES_UNCACHED_1;

            return res; // go to RQ
        end
        // else: _Regular

        assert (!uncachedResp.active) else $error("Why uncched\n%p\n%p", uncachedResp, cacheResp);
        
        return updateE2_Regular(p, ad, cacheResp, sqResp);
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


    function automatic UopMemPacket updateE2_Regular(input UopMemPacket p, input AccessDesc ad, input DataCacheOutput cacheResp, input UopPacket sqResp);
        UopPacket res = p;
        UidT uid = p.TMP_oid;

        assert (!(p.memClass inside {MC_UNCACHED, MC_SYS, MC_BARRIER})) else $fatal(2, "Wrong class for %p", p.memClass);

        // No misses or special actions, typical load/store
        if (isLoadMemUop(decUname(uid))) begin
            // First run of block-crossing load?
            if (ad.blockCross && res.memClass != MC_UPPER_B) begin
                res.memClass = MC_UPPER_B;
                res.status = ES_LOWER_DONE;
                res.result = cacheResp.data;
            end
            // Not block-crossing, or first run of block-crossing
            else begin
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

                    if (res.memClass == MC_UPPER_B) begin
                        Mword cacheVal = cacheResp.data;
                        Mword uopVal = p.result;
                        //$error("\nUpper (%p): %x, @%x: %x\nshift: %d", U2M(uid), uopVal, ad.vadr, cacheVal, ad.shift);
                        res.status = ES_OK;
                        res.result = combineLoadValues(uopVal, cacheResp.data, ad.shift, decUname(uid));
                    end
                    else begin
                        res.status = ES_OK;
                        res.result = loadValue(cacheResp.data, decUname(uid));
                    end
                end

                insMap.setActualResult(uid, res.result);
            end
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
