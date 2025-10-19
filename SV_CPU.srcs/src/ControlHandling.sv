
package ControlHandling;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import EmulationDefs::*;
    import Emulation::*;
    import AbstractSim::*;
    import UopList::*;


    function automatic EventInfo getLateEvent(input EventInfo info, input Mword adr, input Mword sr2, input Mword sr3, input Mword specificTarget);
        EventInfo res = EMPTY_EVENT_INFO;
        
        case (info.cOp)
            CO_specificException: begin
                res.target = specificTarget;
                res.redirect = 1;
            end
            CO_exception: begin
                res.target = IP_EXC;
                res.redirect = 1;
            end
            CO_fetchError: begin
                res.target = IP_FETCH_EXC;
                res.redirect = 1;
            end
            CO_error: begin
                res.target = IP_ERROR;
                res.redirect = 1;
            end
            CO_undef: begin
                res.target = IP_ERROR;
                res.redirect = 1;
            end
            CO_call: begin
                res.target = IP_CALL;
                res.redirect = 1;
            end
            CO_dbcall: begin
                res.target = IP_DB_CALL;
                res.redirect = 1;
            end
            CO_retE: begin
                res.target = sr2;
                res.redirect = 1;
            end 
            CO_retI: begin
                res.target = sr3;
                res.redirect = 1;
            end 
            CO_sync: begin
                res.target = adr + 4;
                res.redirect = 1;
            end
            CO_refetch: begin
                res.target = adr;
                res.redirect = 1;
            end 
            CO_send: begin
                res.target = adr + 4;
                res.redirect = 1;
            end
            CO_break: begin
                res.target = IP_DB_BREAK;
                res.redirect = 1;
            end
            default: ;                            
        endcase

        res.active = 1;
        res.eventMid = info.eventMid;
        res.cOp = info.cOp;

        return res;
    endfunction


    function automatic EventInfo eventFromOp(input InsId id, input UopName uname, input Mword adr, input logic refetch, input logic exception, input ProgramEvent evtType, input logic dbStep);
        EventInfo res = '{1, id, CO_none, 1, adr, 'x};
        
        if (refetch) res.cOp = CO_refetch;
        else if (exception) begin
            if (evtType == PE_NONE)
                res.cOp = CO_exception;
            else begin
                res.cOp = CO_specificException;
                res.target = programEvent2trg(evtType);
            end
        end
        else begin
            case (uname)
                UOP_ctrl_fetchError: res.cOp = CO_fetchError;
                UOP_ctrl_error:    res.cOp = CO_error;
                UOP_ctrl_undef:    res.cOp = CO_undef;
                UOP_ctrl_call:     res.cOp = CO_call;
                UOP_ctrl_dbcall:   res.cOp = CO_dbcall;
                UOP_ctrl_rete:     res.cOp = CO_retE;
                UOP_ctrl_reti:     res.cOp = CO_retI;

                UOP_ctrl_refetch:  res.cOp = CO_refetch;
                UOP_ctrl_sync:     res.cOp = dbStep ? CO_break : CO_sync;
                UOP_ctrl_send:     res.cOp = CO_send; // TODO: implement CO_send_break which will work like CO_break but also sends signal
                default:           res.cOp = dbStep ? CO_break : CO_none;
            endcase
        end
        return res;
    endfunction

    task automatic checkUnimplementedInstruction(input AbstractInstruction ins);
        if (ins.def.o == O_halt) $error("halt not implemented");
    endtask

    // core logic
    function automatic Mword getCommitTarget(input UopName uname, input logic taken, input Mword prev, input Mword executed, input logic refetch, input logic exception);
        if (isBranchUop(uname) && taken) return executed;
        else if (exception) return 'x;
        else if (uname == UOP_ctrl_sync) return prev + 4;
        else if (isControlUop(uname)) return 'x;
        else if (refetch) return prev;
        else return prev + 4;
    endfunction;

endpackage
