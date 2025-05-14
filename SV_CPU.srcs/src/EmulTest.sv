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
        emul.progMem.createPage(0);
        
        testFetch();
        
        $display("DONE");
        $stop(2);
    endtask


    task automatic testFetch();

//        PE_FETCH_INVALID_ADDRESS = 16 + 0,
        test_FETCH_INVALID_ADDRESS();
//        PE_FETCH_UNALIGNED_ADDRESS = 16 + 1,
        test_FETCH_UNALIGNED_ADDRESS();
//        PE_FETCH_TLB_MISS = 16 + 2,

//        PE_FETCH_UNMAPPED_ADDRESS = 16 + 3,
        test_FETCH_UNMAPPED();
//        PE_FETCH_DISALLOWED_ACCESS = 16 + 4,
        test_FETCH_DISALLOWED();
//        PE_FETCH_UNCACHED = 16 + 5,

//        PE_FETCH_CACHE_MISS = 16 + 6,

//        PE_FETCH_NONEXISTENT_ADDRESS = 16 + 7,        
        test_FETCH_NONEXISTENT();
        
        

        test_OK();
        
        
        $display("Fetch tests done");
        
    endtask


    task automatic test_OK();
        emul.resetCore();
     
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("ja 0")});

        emul.programMappings.push_back('{0, 0,  1, 1, 1, 1});

        emul.executeStep();

        // Check
        check(emul, PE_NONE, 0, "Normal ins");
    endtask
    
    
    task automatic test_FETCH_INVALID_ADDRESS();
        emul.resetCore();
        
        emul.coreState.target = 'x;
            
        emul.executeStep();
                    
        check(emul, PE_FETCH_INVALID_ADDRESS, IP_FETCH_EXC, "Invalid fetch adr");
    endtask

    task automatic test_FETCH_UNALIGNED_ADDRESS();
        emul.resetCore();
        
        emul.coreState.target = 3;
            
        emul.executeStep();
                    
        check(emul, PE_FETCH_UNALIGNED_ADDRESS, IP_FETCH_EXC, "Unaligned fetch adr");
    endtask


    task automatic test_FETCH_UNMAPPED();
        emul.resetCore();
                
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("ja 0")});
            
        emul.executeStep();
                
        // Check
        check(emul, PE_FETCH_UNMAPPED_ADDRESS, IP_FETCH_EXC, "Fetch unmapped");
    endtask


    task automatic test_FETCH_DISALLOWED();
        emul.resetCore();
                
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("ja 0")});

        emul.programMappings.push_back('{0, 0,  1, 1, 0, 1});
           
        emul.executeStep();
                
        // Check
        check(emul, PE_FETCH_DISALLOWED_ACCESS, IP_FETCH_EXC, "Fetch disallowed");
    endtask


    task automatic test_FETCH_NONEXISTENT();
        emul.resetCore();
                
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("ja 0")});

        emul.programMappings.push_back('{0, 'h0000010000000000,  1, 1, 1, 1});
           
        emul.executeStep();
                
        // Check
        check(emul, PE_FETCH_NONEXISTENT_ADDRESS, IP_FETCH_EXC, "Fetch nonexistent");
    endtask



    function automatic void check(input Emulator em, input Mword et, input Mword trg, input string msg);
        assert (emul.status.eventType === et) else $error({"%p\n", msg, "; Wrong ET"}, em);
        assert (emul.coreState.target === trg) else $error({"%p\n", msg, "; Wrong trg"}, em);
    endfunction 


endmodule
