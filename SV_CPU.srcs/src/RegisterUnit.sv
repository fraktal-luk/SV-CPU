
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;
import Queues::*;


module RegisterUnit();
    RegisterTracker #(N_REGS_INT, N_REGS_FLOAT) registerTracker = new();


    function automatic void reserve(input OpSlotAF ops);

    endfunction


    function automatic void releaseRegs(input RobDefs::OpRecordA ops);

    endfunction

endmodule
