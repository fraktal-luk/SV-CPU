
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

        return res;
    endfunction


    function automatic EventInfo eventFromOp(input InsId id, input InstructionInfo ii, input EventDesc eDesc);
        Mword adr = ii.basicData.adr;
        EventInfo res = '{1, id, CO_none, eDesc.etype, 1, adr, 'x};

        if (eDesc.etype == PE_EXT_DEBUG)
            res = DB_EVENT; 
        else if (eDesc.etype inside {PE_HW_SYNC, PE_HW_SEND})
            res.target = adr + 4;
        else if (eDesc.etype == PE_HW_REFETCH)
            res.target = adr;
        else
            res.target = programEvent2trg(eDesc.etype);

        res.cOp = CO_none;

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
