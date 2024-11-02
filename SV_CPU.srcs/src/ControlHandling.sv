
package ControlHandling;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    import AbstractSim::*;
    import UopList::*;


    function automatic EventInfo getLateEvent(input EventInfo info, input Mword adr, input Mword sr2, input Mword sr3);
        EventInfo res = EMPTY_EVENT_INFO;
        
        case (info.cOp)
            CO_exception: begin
                res.target = IP_EXC;
                res.redirect = 1;
            end
            CO_undef: begin
                res.target = IP_ERROR;
                res.redirect = 1;
                res.sigWrong = 1;
            end
            CO_call: begin
                res.target = IP_CALL;
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
                res.sigOk = 1;
            end
            default: ;                            
        endcase

        res.active = 1;
        res.eventMid = info.eventMid;
        res.cOp = info.cOp;

        return res;
    endfunction


    function automatic void modifyStateSync(input ControlOp cOp, ref Mword sysRegs[32], input Mword adr);
        case (cOp)
            CO_exception: begin
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr;
                
                sysRegs[1] |= 1; // FUTURE: handle state register correctly
            end
            CO_undef: begin
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr + 4;
                
                sysRegs[1] |= 1; // FUTURE: handle state register correctly
            end
            CO_call: begin                  
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr + 4;
                
                sysRegs[1] |= 1; // FUTURE: handle state register correctly
            end
            CO_retE: begin
                sysRegs[1] = sysRegs[4];
            end
            CO_retI: begin
                sysRegs[1] = sysRegs[5];
            end
        endcase
    endfunction
    
    

    function automatic void saveStateAsync(ref Mword sysRegs[32], input Mword prevTarget);
        sysRegs[5] = sysRegs[1];
        sysRegs[3] = prevTarget;
        
        sysRegs[1] |= 2; // FUTURE: handle state register correctly
    endfunction


    function automatic EventInfo eventFromOp(input InsId id, input UopName uname, input Mword adr, input logic refetch, input logic exception);
        EventInfo res = '{1, id, CO_none, 1, 0, 0, adr, 'x};
        
        if (refetch) res.cOp = CO_refetch;
        else if (exception) res.cOp = CO_exception;
        else begin
            case (uname)
                // TODO: error
                UOP_ctrl_undef:    res.cOp = CO_undef;
                UOP_ctrl_call:     res.cOp = CO_call;
                UOP_ctrl_rete:     res.cOp = CO_retE;
                UOP_ctrl_reti:     res.cOp = CO_retI;
                UOP_ctrl_sync:     res.cOp = CO_sync;
                UOP_ctrl_refetch:   res.cOp = CO_refetch;
                //O_halt:     res.cOp = CO_undef;
                UOP_ctrl_send:     res.cOp = CO_send;
                default:    res.cOp = CO_none;
            endcase
        end
        return res;
    endfunction

    task automatic checkUnimplementedInstruction(input AbstractInstruction ins);
        if (ins.def.o == O_halt) $error("halt not implemented");
    endtask

    // core logic
    function automatic Mword getCommitTarget(input UopName uname, input Mword prev, input Mword executed, input logic refetch, input logic exception);
        if (isBranchUop(uname)) return executed;
        else if (isControlUop(uname) || exception) return 'x;
        else if (refetch) return prev;
        else return prev + 4;
    endfunction;

endpackage
