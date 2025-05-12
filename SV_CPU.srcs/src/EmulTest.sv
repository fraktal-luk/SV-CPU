`timescale 1ns / 1fs

import Base::*;
import InsDefs::*;
import Asm::*;
import EmulationDefs::*;
import Emulation::*;
import AbstractSim::*;
import Insmap::*;

import Testing::*;


module EmulTest();

    
    function automatic Word asm(input string str);
        squeue q = '{str};
        Section s = processLines(q);
        return s.words[0];
    endfunction

    Emulator emul = new();


    initial run();
    
    
    task automatic run();
        //PageBasedProgramMemory progMem = new();
        emul.progMem.createPage(0);
        //emul.progMem.createPage(2*PAGE_SIZE);
        
        emul.resetCore();
        
        emul.coreState.target = 'x;
        
            emul.coreState.target = 0;
            emul.progMem.writePage(0, '{0: asm("ja 0")});
            
            emul.executeStep();
        
        $display("\n%x, %x\n", emul.progMem.fetch(0), emul.progMem.fetch(4));
        
        $display("%p", emul);
        
        #5
        $display("Done");
        $stop(2);
    endtask

endmodule
