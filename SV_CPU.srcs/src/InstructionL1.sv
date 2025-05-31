
import Base::*;
import InsDefs::*;
import Asm::*;
import EmulationDefs::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;


module InstructionL1(
                input logic clk,
                input Mword readAddress,
                output InstructionCacheOutput readOut
              );

    Word content[4096];
        Word way0[PAGE_SIZE/4] = '{default: 'x};
        Word way1[PAGE_SIZE/4] = '{default: 'x};
        Word way2[PAGE_SIZE/4] = '{default: 'x};


    
    function automatic void reset();
        way0 = '{default: 'x};
        way1 = '{default: 'x};
        way2 = '{default: 'x};
    endfunction


    always @(posedge clk) begin
        automatic Mword truncatedAdr = readAddress & ~(4*FETCH_WIDTH-1);
    
        foreach (readOut.words[i]) begin            
            readOut.active <= 1;
            readOut.status <= CR_HIT;
            readOut.desc <= '{1};
            readOut.words[i] <= content[truncatedAdr/4 + i];
        end
    end


    // Copy page 0 and page 1 to cache
    function automatic void prefetchForTest();
        PageBasedProgramMemory::Page page = AbstractCore.programMem.getPage(0);
        way0 = page[0+:PAGE_SIZE/4];
        page = AbstractCore.programMem.getPage(PAGE_SIZE);
        way1 = page[0+:PAGE_SIZE/4];
        page = AbstractCore.programMem.getPage(2*PAGE_SIZE);
        way2 = page[0+:PAGE_SIZE/4];
        
            content[0+:1024] = way0;
            content[1024+:1024] = way1;
            content[2048+:1024] = way2;
    endfunction


endmodule
