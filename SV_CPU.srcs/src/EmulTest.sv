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


    localparam Translation DEFAULT_PAGE0 = '{1, 0, '{1, 1, 1, 1, 1}, 0};


    Emulator emul = new();


    initial run();

    
    task automatic run();
        emul.progMem.createPage(0);
        
        testFetch();
        testSys();
        testMem();
        testExt();
        
        $display("DONE\n");
        //$stop(2);
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



    task automatic testSys();

//        PE_SYS_INVALID_ADDRESS = 5*16 + 0,
        test_SYS_INVALID_ADR();
//        PE_SYS_DISALLOWED_ACCESS = 5*16 + 1,
//        PE_SYS_UNDEFINED_INSTRUCTION = 5*16 + 2,
        test_SYS_UNDEF();
//        PE_SYS_ERROR = 5*16 + 3,
        test_SYS_ERROR();
//        PE_SYS_CALL = 5*16 + 4,
        test_SYS_CALL();
//        PE_SYS_DISABLED_INSTRUCTION = 5*16 + 5, // FP op when SIMD off, etc

        test_OK();
        
        
        $display("Sys tests done");
        
    endtask


    task automatic testMem();

//        PE_MEM_INVALID_ADDRESS = 3*16 + 0,
      //  test_MEM_INVALID();  // TODO: when adr ranges are fixed
//        PE_MEM_UNALIGNED_ADDRESS = 3*16 + 1, // when crossing blocks/pages
//        PE_MEM_TLB_MISS = 3*16 + 2, // HW
//        PE_MEM_UNMAPPED_ADDRESS = 3*16 + 3,
        test_MEM_UNMAPPED();
//        PE_MEM_DISALLOWED_ACCESS = 3*16 + 4,
//        PE_MEM_UNCACHED = 3*16 + 5, // HW
//        PE_MEM_CACHE_MISS = 3*16 + 6, // HW
//        PE_MEM_NONEXISTENT_ADDRESS = 3*16 + 7,
        test_MEM_NONEXISTENT();

        test_OK();
        
        
        $display("Mem tests done");
        
    endtask


    task automatic testExt();

//        FP_EXT_INTERRUPT = 6*16 + 0,
        test_INTERRUPT();
//        FP_EXT_RESET = 6*16 + 1,
//        FP_EXT_DEBUG = 6*16 + 2

        test_OK();
        
        
        $display("Ext tests done");
        
    endtask

    
    task automatic test_INTERRUPT();
        emul.resetCoreAndMappings();
     
        emul.status.enableMmu = 1;
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("ja 0")});

            emul.programMappings.push_back(DEFAULT_PAGE0);

        emul.interrupt();

        // Check
        check(emul, PE_EXT_INTERRUPT, IP_INT, "ext interrupt");
    endtask



    task automatic test_SYS_INVALID_ADR();
        emul.resetCoreAndMappings();

        emul.status.enableMmu = 1;
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("lds r0, r0, 99")});

            emul.programMappings.push_back(DEFAULT_PAGE0);

        emul.executeStep();

        // Check
        check(emul, PE_SYS_INVALID_ADDRESS, IP_EXC, "sys wrong adr ins");
    endtask


    task automatic test_SYS_UNDEF();
        emul.resetCoreAndMappings();

        emul.status.enableMmu = 1;
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("undef")});

            emul.programMappings.push_back(DEFAULT_PAGE0);

        emul.executeStep();

        // Check
        check(emul, PE_SYS_UNDEFINED_INSTRUCTION, IP_ERROR, "sys undefined");
    endtask

    task automatic test_SYS_ERROR();
        emul.resetCoreAndMappings();

        emul.status.enableMmu = 1;     
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("sys_error")});

            emul.programMappings.push_back(DEFAULT_PAGE0);

        emul.executeStep();

        // Check
        check(emul, PE_SYS_ERROR, IP_ERROR, "sys_error");
    endtask
    
    task automatic test_SYS_CALL();
        emul.resetCoreAndMappings();

        emul.status.enableMmu = 1;     
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("sys_call")});

            emul.programMappings.push_back(DEFAULT_PAGE0);

        emul.executeStep();

        // Check
        check(emul, PE_SYS_CALL, IP_CALL, "sys call");
    endtask



    task automatic test_OK();
        emul.resetCoreAndMappings();

        emul.status.enableMmu = 1;     
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("ja 0")});

            emul.programMappings.push_back(DEFAULT_PAGE0);

        emul.executeStep();

        // Check
        check(emul, PE_NONE, 0, "Normal ins");
    endtask
    
    
    task automatic test_FETCH_INVALID_ADDRESS();
        emul.resetCoreAndMappings();

        //emul.status.enableMmu = 1;        
        emul.coreState.target = 'x;
            
        emul.executeStep();
                    
        check(emul, PE_FETCH_INVALID_ADDRESS, IP_FETCH_EXC, "Invalid fetch adr");
    endtask

    task automatic test_FETCH_UNALIGNED_ADDRESS();
        emul.resetCoreAndMappings();
        
        emul.coreState.target = 3;
            
        emul.executeStep();
                    
        check(emul, PE_FETCH_UNALIGNED_ADDRESS, IP_FETCH_EXC, "Unaligned fetch adr");
    endtask


    task automatic test_FETCH_UNMAPPED();
        emul.resetCoreAndMappings();

        emul.status.enableMmu = 1;                
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("ja 0")});
            
        emul.executeStep();
                
        // Check
        check(emul, PE_FETCH_UNMAPPED_ADDRESS, IP_FETCH_EXC, "Fetch unmapped");
    endtask


    task automatic test_FETCH_DISALLOWED();
        emul.resetCoreAndMappings();

        emul.status.enableMmu = 1;                
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("ja 0")});

             emul.programMappings.push_back('{1, 0, '{1, 1, 1, 0, 1}, 0});

        emul.executeStep();
                
        // Check
        check(emul, PE_FETCH_DISALLOWED_ACCESS, IP_FETCH_EXC, "Fetch disallowed");
    endtask


    task automatic test_FETCH_NONEXISTENT();
        emul.resetCoreAndMappings();

        emul.status.enableMmu = 1;               
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("ja 0")});

             emul.programMappings.push_back('{1, 0, '{1, 1, 1, 1, 1}, 'h0000010000000000});
          
        emul.executeStep();
                
        // Check
        check(emul, PE_FETCH_NONEXISTENT_ADDRESS, IP_FETCH_EXC, "Fetch nonexistent");
    endtask


    task automatic test_MEM_INVALID();
//        emul.resetCoreAndMappings();
     
//        emul.coreState.target = 0;
//        emul.progMem.writePage(0, '{0: asm("l 0")});

//        emul.programMappings.push_back('{0, 0,  1, 1, 1, 1});

//        emul.executeStep();

//        // Check
//        check(emul, PE_NONE, 0, "mem invalid");
    endtask

    task automatic test_MEM_UNMAPPED();
        emul.resetCoreAndMappings();

        emul.status.enableMmu = 1;    
        emul.coreState.target = 0;
        emul.progMem.writePage(0, '{0: asm("ldi_i r10, r0, 24")});

            emul.programMappings.push_back(DEFAULT_PAGE0);

        emul.executeStep();

        // Check
        check(emul, PE_MEM_UNMAPPED_ADDRESS, IP_MEM_EXC, "mem unmapped");
    endtask
    
    task automatic test_MEM_NONEXISTENT();
        emul.resetCoreAndMappings();

        emul.status.enableMmu = 1;     
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
