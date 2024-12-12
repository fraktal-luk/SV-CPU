
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;


module InstructionL1(
                input logic clk,
                input Mword readAddress,
                output Word readData[FETCH_WIDTH]
              );

    Word content[4096];
    

    function automatic void setProgram(input Word p[4096]);
        content = p;
    endfunction

    always @(posedge clk) begin
        automatic Mword truncatedAdr = readAddress & ~(4*FETCH_WIDTH-1);
    
        foreach (readData[i])
            readData[i] <= content[truncatedAdr/4 + i];
    end

endmodule
