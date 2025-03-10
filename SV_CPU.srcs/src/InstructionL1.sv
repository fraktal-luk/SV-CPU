
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
                //output Word readData[FETCH_WIDTH],
                output InstructionCacheOutput readOut
              );

    Word content[4096];
    

    function automatic void setProgram(input Word p[4096]);
        content = p;
    endfunction

    always @(posedge clk) begin
        automatic Mword truncatedAdr = readAddress & ~(4*FETCH_WIDTH-1);
    
        foreach (readOut.words[i]) begin
            //readData[i] <= content[truncatedAdr/4 + i];
            
            readOut.active <= 1;
            readOut.status <= CR_HIT;
            readOut.desc <= '{1};
            readOut.words[i] <= content[truncatedAdr/4 + i];
        end
    end

endmodule
