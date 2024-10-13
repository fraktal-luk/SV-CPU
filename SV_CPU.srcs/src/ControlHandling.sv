
package ControlHandling;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    import AbstractSim::*;
    


        function automatic EventInfo getLateEvent(input OpSlot op, input AbstractInstruction abs, input Mword adr, input Mword sr2, input Mword sr3);
            EventInfo res = EMPTY_EVENT_INFO;
            
            case (abs.def.o)
                O_sysStore: ;
                O_undef: begin
                    res.target = IP_ERROR;
                    res.redirect = 1;
                    res.sigWrong = 1;
                end
                O_call: begin
                    res.target = IP_CALL;
                    res.redirect = 1;
                end
                O_retE: begin
                    res.target = sr2;
                    res.redirect = 1;
                end 
                O_retI: begin
                    res.target = sr3;
                    res.redirect = 1;
                end 
                O_sync: begin
                    res.target = adr + 4;
                    res.redirect = 1;
                end
                
                O_replay: begin
                    res.target = adr;
                    res.redirect = 1;
                end 
                O_halt: begin                
                    res.target = adr + 4;
                    res.redirect = 1;
                end
                O_send: begin
                    res.target = adr + 4;
                    res.redirect = 1;
                    res.sigOk = 1;
                end
                default: ;                            
            endcase
    
            res.op = op;
    
            return res;
        endfunction
    
        
        function automatic EventInfo getLateEventExc(input OpSlot op, input AbstractInstruction abs, input Mword adr, input Mword sr2, input Mword sr3);
            EventInfo res = EMPTY_EVENT_INFO;
            
            res.target = IP_EXC;
            res.redirect = 1;
    
            res.op = op;
    
            return res;
        endfunction



    function automatic EventInfo getLateEvent_N(input ControlOp cOp, input OpSlot op, input AbstractInstruction abs, input Mword adr, input Mword sr2, input Mword sr3, input logic exc, input logic refetch);
        EventInfo res = EMPTY_EVENT_INFO;
        
            if (exc) begin
                assert (cOp == CO_exception) else $error("exc not");
            end
            
            if (refetch) begin
                assert (cOp == CO_refetch) else $error("refe not");
            end
            
        if (exc) begin
            return getLateEventExc(op, abs, adr, sr2, sr3);
        end
        
        case (abs.def.o)
            O_sysStore: ;
            O_undef: begin
                res.target = IP_ERROR;
                res.redirect = 1;
                res.sigWrong = 1;
            end
            O_call: begin
                res.target = IP_CALL;
                res.redirect = 1;
            end
            O_retE: begin
                res.target = sr2;
                res.redirect = 1;
            end 
            O_retI: begin
                res.target = sr3;
                res.redirect = 1;
            end 
            O_sync: begin
                res.target = adr + 4;
                res.redirect = 1;
            end
            
            O_replay: begin
                res.target = adr;
                res.redirect = 1;
            end 
            O_halt: begin                
                res.target = adr + 4;
                res.redirect = 1;
            end
            O_send: begin
                res.target = adr + 4;
                res.redirect = 1;
                res.sigOk = 1;
            end
            default: ;                            
        endcase

        res.op = op;
        res.cOp = cOp;

        return res;
    endfunction




        function automatic void modifyStateSync(ref Mword sysRegs[32], input Mword adr, input AbstractInstruction abs);
            case (abs.def.o)
                O_undef: begin
                    sysRegs[4] = sysRegs[1];
                    sysRegs[2] = adr + 4;
                    
                    sysRegs[1] |= 1; // TODO: handle state register correctly
                end
                O_call: begin                    
                    sysRegs[4] = sysRegs[1];
                    sysRegs[2] = adr + 4;
                    
                    sysRegs[1] |= 1; // TODO: handle state register correctly
                end
                O_retE: sysRegs[1] = sysRegs[4];
                O_retI: sysRegs[1] = sysRegs[5];
            endcase
        endfunction
    
        function automatic void modifyStateSyncExc(ref Mword sysRegs[32], input Mword adr, input AbstractInstruction abs);
            begin
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr;
                
                sysRegs[1] |= 1; // TODO: handle state register correctly
            end
        endfunction


    function automatic void modifyStateSync_N(input ControlOp cOp, ref Mword sysRegs[32], input Mword adr, input AbstractInstruction abs, input logic exc, input logic refetch);

            if (exc) begin
                assert (cOp == CO_exception) else $error("exc not.");
            end

            if (refetch) begin
                assert (cOp == CO_refetch) else $error("refe not.");
            end
           
        if (exc) begin
            modifyStateSyncExc(sysRegs, adr, abs);
            return;
        end
        
        case (abs.def.o)
            O_undef: begin
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr + 4;
                
                sysRegs[1] |= 1; // TODO: handle state register correctly
            end
            O_call: begin                    
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr + 4;
                
                sysRegs[1] |= 1; // TODO: handle state register correctly
            end
            O_retE: sysRegs[1] = sysRegs[4];
            O_retI: sysRegs[1] = sysRegs[5];
        endcase
    endfunction
    
    

    function automatic void saveStateAsync(ref Mword sysRegs[32], input Mword prevTarget);
        sysRegs[5] = sysRegs[1];
        sysRegs[3] = prevTarget;
        
        sysRegs[1] |= 2; // TODO: handle state register correctly
    endfunction


    function automatic EventInfo eventFromOp(input OpSlot op, input AbstractInstruction abs, input logic refetch, input logic exception);
        EventInfo res = '{op, CO_none, 0, 0, 1, 0, 0, 'x};
        
        if (refetch) res.cOp = CO_refetch;
        else if (exception) res.cOp = CO_exception;
        else begin
            case (abs.def.o)
                O_undef:    res.cOp = CO_undef;
                O_call:     res.cOp = CO_call;
                O_retE:     res.cOp = CO_retE;
                O_retI:     res.cOp = CO_retI;
                O_sync:     res.cOp = CO_sync;
                O_replay:   res.cOp = CO_refetch;
                //O_halt:     res.cOp = CO_undef;
                O_send:     res.cOp = CO_send;
                default:    res.cOp = CO_none;
            endcase
        end
        
        return res;
    endfunction


    task automatic checkUnimplementedInstruction(input AbstractInstruction ins);
        if (ins.def.o == O_halt) $error("halt not implemented");
    endtask

    // core logic
    function automatic Mword getCommitTarget(input AbstractInstruction ins, input Mword prev, input Mword executed, input logic refetch, input logic exception);
        if (isBranchIns(ins))
            return executed;
        else if (isSysIns(ins) || exception)
            return 'x;
        else if (refetch)
            return prev;
        else
            return prev + 4;
    endfunction;

endpackage
