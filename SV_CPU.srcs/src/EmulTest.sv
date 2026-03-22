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
    
    localparam Translation DEFAULT_PAGE0 = '{1, 0, '{1, 1, 1, 1, 1}, 0};


    Emulator emul = new();


    initial run();

    
    task automatic run();
        emul.progMem.createPage(0);

        test_FETCH_UNMAPPED();
        test_SYS_ERROR();

        test_MEM_UNMAPPED();
        test_MEM_NONEXISTENT();

        test_INTERRUPT();

        $display("DONE\n");
        //$stop(2);
    endtask

    
    task automatic test_INTERRUPT();
        emul.resetCoreAndMappings();
            
        emul.DB_enableMmu();
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("ja 0")});

            emul.programMappings.push_back(DEFAULT_PAGE0);

        emul.interrupt();

        // Check
        check(emul, PE_EXT_INTERRUPT, IP_INT, "ext interrupt");
    endtask


    task automatic test_SYS_ERROR();
        emul.resetCoreAndMappings();

        emul.DB_enableMmu();
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("sys_error")});

            emul.programMappings.push_back(DEFAULT_PAGE0);

        emul.executeStep();

        // Check
        check(emul, PE_SYS_ERROR, IP_ERROR, "sys_error");
    endtask
    

    task automatic test_FETCH_UNMAPPED();
        emul.resetCoreAndMappings();

        emul.DB_enableMmu();
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("ja 0")});
            
        emul.executeStep();
                
        // Check
        check(emul, PE_FETCH_UNMAPPED_ADDRESS, IP_FETCH_EXC, "Fetch unmapped");
    endtask


    task automatic test_MEM_UNMAPPED();
        emul.resetCoreAndMappings();

        emul.DB_enableMmu();
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("ldi_i r10, r0, 24")});

            emul.programMappings.push_back(DEFAULT_PAGE0);

        emul.executeStep();

        // Check
        check(emul, PE_MEM_UNMAPPED_ADDRESS, IP_MEM_EXC, "mem unmapped");
    endtask
    
    task automatic test_MEM_NONEXISTENT();
        emul.resetCoreAndMappings();

        emul.DB_enableMmu();
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("ldi_i r10, r0, 24")});

            emul.programMappings.push_back(DEFAULT_PAGE0);
            emul.dataMappings.push_back('{1, 0, '{1, 1, 1, 1, 1}, 'h0100000000000000});

        emul.executeStep();

        // Check
        check(emul, PE_MEM_NONEXISTENT_ADDRESS, IP_MEM_EXC, "mem nonexistent");
    endtask



    function automatic void check(input Emulator em, input Mword et, input Mword trg, input string msg);
        assert (emul.status.eventType === et) else $error({"%p\n", msg, "; Wrong ET"}, em);
        assert (emul.coreState.target === trg) else $error({"%p\n", msg, "; Wrong trg"}, em);
    endfunction 


endmodule
