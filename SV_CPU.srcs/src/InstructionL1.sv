
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;


module InstructionL1(
                input logic clk
              );

    Word content[4096];
    

    function automatic void setProgram(input Word p[4096]);
        content = p;
    endfunction

endmodule
