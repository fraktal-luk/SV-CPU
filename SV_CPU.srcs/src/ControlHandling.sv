
package ControlHandling;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import EmulationDefs::*;
    import Emulation::*;
    import AbstractSim::*;
    import UopList::*;
    import Insmap::*;



    function automatic Mword takenTarget(input UopName uname, input Mword adr, input Mword args[3]);
        case (uname)
            UOP_br_z, UOP_br_nz:  return args[1];
            UOP_bc_z, UOP_bc_nz, UOP_bc_a, UOP_bc_l: return adr + args[1];  
            default: $fatal(2, "Wrong branch uop");
        endcase  
    endfunction

    function automatic Mword finalTarget(input UopName uname, input logic dir, input Mword regValue, input Mword bqTarget, input Mword bqLink);
        if (dir === 0) return bqLink;

        case (uname)
            UOP_br_z, UOP_br_nz:  return regValue;
            UOP_bc_z, UOP_bc_nz, UOP_bc_a, UOP_bc_l: return bqTarget;  
            default: $fatal(2, "Wrong branch uop");
        endcase 
    endfunction


    function automatic InsId replaceEvId(input InsId prev, input InsId next);
        if (prev == -1) return next;
        else if (next != -1 && prev > next) return next;
        else return prev;
    endfunction


    function automatic EventInfo getLateEvent(input EventInfo info, input Mword sr2, input Mword sr3);
        EventInfo res = EMPTY_EVENT_INFO;

        res.target = info.target;
        res.active = 1;
        res.eventMid = info.eventMid;
        res.etype = info.etype;
        res.redirect = 1;

        if (info.etype == PE_HW_RETE) res.target = sr2;
        if (info.etype == PE_HW_RETI) res.target = sr3;

        return res;
    endfunction


    task automatic checkUnimplementedInstruction(input AbstractInstruction ins);
        if (ins.def.o == O_halt) $error("halt not implemented");
    endtask



    function automatic EventInfo eventFromOp(input Mword adr, input EventDesc eDesc);
        EventInfo res = '{1, eDesc.id, eDesc.etype, 1, 'x, adr, 'x};

        case (eDesc.etype)
            PE_EXT_DEBUG: $fatal(2, "DB event should not be here");
            PE_HW_SYNC, PE_HW_SEND: res.target = adr + 4;
            PE_HW_REFETCH: res.target = adr;
            default: res.target = programEvent2trg(eDesc.etype);
        endcase

        return res;
    endfunction


endpackage
