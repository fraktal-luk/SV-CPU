
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;


module DataL1(
                input logic clk,
                
                input DataReadReq readReqs[N_MEM_PORTS],
                output DataReadResp readResps[N_MEM_PORTS],
                
                input Word readAddresses[N_MEM_PORTS],
                output Word readData[N_MEM_PORTS],
                
                input logic writeReqs[2],
                input Word writeAddresses[2],
                input Word writeData[2]
              );

    logic[7:0] content[4096];




    always @(posedge clk) begin
        handleReads();
        handleWrites();
        
    end
    
    assign readResps[0] = '{0, readData[0]};


    function automatic void reset();
        content = '{default: 0};
    endfunction


    task automatic handleWrites();
        logic[7:0] writing[4];
        
        foreach (writing[i])
            writing[i] = writeData[0] >> 8*(3-i);
        
        foreach (writing[i])
            if (writeReqs[0]) content[writeAddresses[0] + i] <= writing[i];

    endtask


    task automatic handleReads();
        logic[7:0] selected[4];        
        
        foreach (selected[i])
            selected[i] = content[readAddresses[0] + i];
    
        readData[0] <= (selected[0] << 24) | (selected[1] << 16) | (selected[2] << 8) | selected[3];
    endtask

endmodule
