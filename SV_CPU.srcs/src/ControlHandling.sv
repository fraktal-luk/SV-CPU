
package ControlHandling;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import EmulationDefs::*;
    import Emulation::*;
    import AbstractSim::*;
    import UopList::*;
    import Insmap::*;

    function automatic EventInfo getLateEvent(input EventInfo info, input Mword sr2, input Mword sr3);
        EventInfo res = EMPTY_EVENT_INFO;

        res.target = info.target;
        res.active = 1;
        res.eventMid = info.eventMid;
        res.cOp = info.cOp;
        res.etype = info.etype;
        res.redirect = 1;

            if (info.etype == PE_HW_RETE) res.target = sr2;
            if (info.etype == PE_HW_RETI) res.target = sr3;

            return res;


        case (info.cOp)
            // Dynamic exceptions
            CO_specificException: ;

            // Events known at Decode
            CO_fetchError, CO_error, CO_undef, CO_call, CO_dbcall: ;

            // Returns
            CO_retE: begin
                res.target = sr2;
                    $error("rete: %p", info.etype);
            end 
            CO_retI: begin
                res.target = sr3;
                    $error("reti: %p", info.etype);
            end 

            // 
            CO_sync, CO_refetch, CO_send:  ;

            default: $fatal(2, "Unknown control op");
        endcase

        return res;
    endfunction


    function automatic EventInfo eventFromOp(input InsId id, input InstructionInfo ii,
                                             input EventDesc eDesc,
                                             input logic dbStep);
        UopName uname = ii.mainUop;
        Mword adr = ii.basicData.adr;
        logic refetch = ii.refetch;
        logic exception = ii.exception;
        ProgramEvent evtType = ii.eventType;

        EventInfo res = '{1, id, CO_none, PE_NONE, 1, adr, 'x};
            Mword estTarget = programEvent2trg(eDesc.etype);

        res.etype = eDesc.etype;

        if (eDesc.etype == PE_EXT_DEBUG) res = DB_EVENT; 

        // Refetch event (dynamic?)  
        else if (refetch) begin
                assert (eDesc.etype == PE_HW_REFETCH) else $error("Wrg refetch? %p", eDesc.etype);
            res.target = adr;
        end
        else if (exception && !isStaticEventUop(uname)) begin // dynamic exception
            assert (evtType != PE_NONE) else $fatal(2, "Unspecified exception reached Commit");
            res.target = programEvent2trg(evtType);
        end
        else begin // Decode events

            case (uname)
                // exc
                UOP_ctrl_fetchError, UOP_ctrl_error, UOP_ctrl_undef, UOP_ctrl_call, UOP_ctrl_dbcall, UOP_ctrl_rete, UOP_ctrl_reti:
                    res.target = programEvent2trg(evtType);

                // sync
                UOP_ctrl_sync, UOP_ctrl_send:     begin
                                      res.target = adr + 4;
                                   end

                default:           begin
                                      assert (eDesc.etype == PE_NONE) else $error("WTF??: %p", eDesc.etype);
                                      res.target = 'x;
                                   end
            endcase

                assert(dbStep || isSilentEventUop(uname) || estTarget === res.target) else $error("targets: %X / %X\n%p / %p", estTarget, res.target, eDesc, evtType);

            res.cOp = CO_none;

        end


        return res;
    endfunction

    task automatic checkUnimplementedInstruction(input AbstractInstruction ins);
        if (ins.def.o == O_halt) $error("halt not implemented");
    endtask

    // core logic
    function automatic Mword getCommitTarget(input UopName uname, input logic taken, input Mword own, input Mword executed, input logic refetch, input logic exception);
        if (isBranchUop(uname) && taken) return executed;
        else if (exception) return 'x;
        else if (uname == UOP_ctrl_sync) return own + 4;
        else if (isControlUop(uname)) return 'x;
        else if (refetch) return own;
        else return own + 4;
    endfunction;

endpackage
