
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;


module DataL1(
                input logic clk
              );

    logic[7:0] content[4096];

    function automatic void reset();
        content = '{default: 0};
    endfunction

endmodule
