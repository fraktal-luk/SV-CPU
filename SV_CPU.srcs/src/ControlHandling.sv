
package ControlHandling;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import EmulationDefs::*;
    import Emulation::*;
    import AbstractSim::*;
    import UopList::*;


    function automatic EventInfo getLateEvent(input EventInfo info, input Mword sr2, input Mword sr3);
        EventInfo res = EMPTY_EVENT_INFO;

        res.target = info.target;
        res.active = 1;
        res.eventMid = info.eventMid;
        res.cOp = info.cOp;
        res.redirect = 1;

        case (info.cOp)
            // Dynamic exceptions
            CO_specificException: ;

            // Events known at Decode
            CO_fetchError, CO_error, CO_undef, CO_call, CO_dbcall: ;

            // Returns
            CO_retE: begin
                res.target = sr2;
            end 
            CO_retI: begin
                res.target = sr3;
            end 

            // 
            CO_sync, CO_refetch, CO_send:  ;

            default: $fatal(2, "Unknown control op");
        endcase

        return res;
    endfunction


    function automatic EventInfo eventFromOp(input InsId id, input UopName uname, input Mword adr,
                                             input logic refetch, input logic exception, input ProgramEvent evtType, input logic dbStep);
        EventInfo res = '{1, id, CO_none, 1, adr, 'x};
        
        // Refetch event (dynamic?)  
        if (refetch) begin
            res.cOp = CO_refetch;
            res.target = adr;
        end
        else if (exception && !isStaticEventUop(uname)) begin // dynamic exception
            assert (evtType != PE_NONE) else $fatal(2, "Unspecified exception reached Commit");

            res.cOp = CO_specificException;
            res.target = programEvent2trg(evtType);
        end
        else begin // Decode events
            case (uname)
                // exc
                UOP_ctrl_fetchError: begin
                                        res.cOp = CO_fetchError;
                                        res.target = IP_FETCH_EXC;
                                     end
                // exc
                UOP_ctrl_error:      begin
                                        res.cOp = CO_error;
                                        res.target = IP_ERROR;
                                     end
                // exc
                UOP_ctrl_undef:      begin 
                                        res.cOp = CO_undef;
                                        res.target = IP_EXC;
                                     end
                // exc?
                UOP_ctrl_call:       begin
                                        res.cOp = CO_call;
                                        res.target = IP_CALL;
                                     end
                // exc?
                UOP_ctrl_dbcall:     begin
                                        res.cOp = CO_dbcall;
                                        res.target = IP_DB_CALL;
                                     end

                // ret
                UOP_ctrl_rete:       begin
                                        res.cOp = CO_retE;
                                        res.target = 'x;
                                     end
                // ret
                UOP_ctrl_reti:       begin
                                        res.cOp = CO_retI;
                                        res.target = 'x;
                                     end


                // Static refetch: does it make sense?
                UOP_ctrl_refetch:    begin
                                        res.cOp = CO_refetch;
                                        res.target = adr;
                                     end


                // sync
                UOP_ctrl_sync:     begin
                                      res.cOp = dbStep ? CO_break : CO_sync;
                                      res.target = adr + 4;
                                      if (dbStep) res = DB_EVENT;
                                   end
                
                // sync
                UOP_ctrl_send:     begin
                                      res.cOp = CO_send; // TODO: implement CO_send_break which will work like CO_break but also sends signal
                                      res.target = adr + 4;
                                   end
                default:           begin
                                      res.cOp = dbStep ? CO_break : CO_none;
                                      res.target = 'x;
                                      if (dbStep) res = DB_EVENT;
                                   end
            endcase

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
