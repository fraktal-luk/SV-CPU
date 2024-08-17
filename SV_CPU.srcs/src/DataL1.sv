
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;


module DataL1(
                input logic clk,
                
                input Word readAddresses[N_MEM_PORTS],
                output Word readData[N_MEM_PORTS],
                
                input logic writeReqs[2],
                input Word writeAddresses[2],
                input Word writeData[2]
              );

    logic[7:0] content[4096];

    function automatic void reset();
        content = '{default: 0};
    endfunction


    always @(posedge clk) begin
        automatic logic[7:0] selected[4];
        automatic logic[7:0] writing[4];
        
        
        foreach (selected[i])
            selected[i] = content[readAddresses[0] + i];
    
        readData[0] <= (selected[0] << 24) | (selected[1] << 16) | (selected[2] << 8) | selected[3];
        
        
        foreach (writing[i])
            writing[i] = writeData[0] >> 8*(3-i);
        
        foreach (writing[i])
            if (writeReqs[0]) content[writeAddresses[0] + i] <= writing[i];

    end

endmodule
