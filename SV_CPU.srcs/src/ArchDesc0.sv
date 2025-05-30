`timescale 1ns / 1fs

import Base::*;
import InsDefs::*;
import Asm::*;
import EmulationDefs::*;
import Emulation::*;
import AbstractSim::*;
import Insmap::*;

import Testing::*;


module ArchDesc0();
    EmulTest emulTest();

    localparam int ITERATION_LIMIT = 2000;
    localparam Mword COMMON_ADR = 4 * 1024;

    const string DEFAULT_RESET_HANDLER[$] = {/*"ja -512", /**/"ja -8704",/**/  "ja 0", "sys_error"};
    const string DEFAULT_ERROR_HANDLER[$] = {"sys_error", "ja 0", "sys_error"};

    const string DEFAULT_CALL_HANDLER[$]  = {"sys_send", "ja 0", "sys_error"};
    const string TESTED_CALL_HANDLER[$] = {"add_i r20, r0, 55", "sys_rete", "ja 0"};

    const string DEFAULT_INT_HANDLER[$]  = {"add_i r21, r0, 77", "sys_reti", "ja 0"};

    const string FAILING_HANDLER[$]  = {"sys_error", "ja 0", "sys_error"};

    const string DEFAULT_EXC_HANDLER[$]  = {"add_i r1, r0, 37", "lds r20, r0, 2", "add_i r21, r20, 4", "sts r21, r0, 2", "sys_rete", "ja 0"};


    const Section DEFAULT_RESET_SECTION = processLines(DEFAULT_RESET_HANDLER);

    const Section DEFAULT_ERROR_SECTION = processLines(DEFAULT_ERROR_HANDLER);

    const Section DEFAULT_CALL_SECTION = processLines(DEFAULT_CALL_HANDLER);
    const Section TESTED_CALL_SECTION = processLines(TESTED_CALL_HANDLER);

    const Section DEFAULT_INT_SECTION = processLines(DEFAULT_INT_HANDLER);
    const Section FAILING_SECTION = processLines(FAILING_HANDLER);

    const Section DEFAULT_EXC_SECTION = processLines(DEFAULT_EXC_HANDLER);


    const MemoryMapping DEFAULT_DATA_MAPPINGS[$] = '{
        '{0, 0, 1, 1, 1, 1},
        '{PAGE_SIZE, PAGE_SIZE, 1, 1, 1, 1},
        '{'h2000, 'h2000, 1, 1, 1, 1},
        '{'h20000000, 'h200000000, 1, 1, 1, 1},
        '{'h80000000, 'h800000000, 1, 1, 1, 0}
    };


    localparam CYCLE = 10;

    logic clk = 1;

    always #(CYCLE/2) clk = ~clk; 



    Section common;
    
    
    squeue allSuites = '{
        "Tests_basic.txt",
        "Tests_mem_simple.txt",
        
        "Tests_mem_advanced.txt",
        "Tests_mem_align.txt",
        "Tests_sys_transfers.txt",
        
        "Tests_all.txt"
    };
    
    string emulTestName, simTestName;

    Emulator emul_N = new();


    class Runner1 extends TestRunner;
        task automatic runTest(input string name);
            runTestEmul(name, emul_N, DEFAULT_CALL_SECTION);
            #1;
        endtask
    endclass



    function automatic void prepareTest(ref Word mem[], input string name);
        Section testProg = fillImports(processLines(readFile({codeDir, name, ".txt"})), 0, common, COMMON_ADR);
            mem = '{default: 'x};
        writeProgram(mem, 0, testProg.words);
    endfunction

    function automatic void prepareHandlers(ref Word mem[], input Section callSec, input Section intSec, input Section excSec);
        Section testProg;
        setBasicPrograms(mem, testProg, DEFAULT_RESET_SECTION, DEFAULT_ERROR_SECTION, callSec, intSec, excSec);
    endfunction

    
    function automatic void map3pages(ref Emulator em);
        em.programMappings.push_back('{0, 0,  1, 1, 1, 1});        
        em.programMappings.push_back('{PAGE_SIZE, PAGE_SIZE,  1, 1, 1, 1});        
        em.programMappings.push_back('{2*PAGE_SIZE, 2*PAGE_SIZE,  1, 1, 1, 1});
    endfunction

    function automatic void mapDataPages(ref Emulator em);
        em.dataMappings.push_back('{0, 0,  1, 1, 1, 1});        
       // em.dataMappings.push_back('{PAGE_SIZE, PAGE_SIZE,  1, 1, 1, 1});        
      //  em.dataMappings.push_back('{2*PAGE_SIZE, 2*PAGE_SIZE,  1, 1, 1, 1});
        em.dataMappings.push_back('{'h80000000, 'h80000000,  1, 1, 0, 0});
        em.dataMappings.push_back('{'h20000000, 'h20000000,  1, 1, 1, 1});
        em.dataMappings.push_back('{'h2000, 'h2000,  1, 1, 1, 1});
      
    endfunction


    // Emul-only run
    task automatic runTestEmul(input string name, ref Emulator emul, input Section callSec);
        Word emul_progMem[] = new[4096 / 4];

        emulTestName = name;
        prepareTest(emul_progMem, name);
        
        
        emul.progMem.assignPage(0, emul_progMem);
    
        saveProgramToFile({"../../../../sim_files/ZZZ_", name, ".txt"}, emul_progMem);

        resetAll(emul);
        map3pages(emul);
        mapDataPages(emul);
        
        performEmul(emul);
    endtask


    task automatic runErrorTestEmul(ref Emulator emul);
        time DELAY = 1;
        Word emul_progMem[] = new[4096 / 4];

        emulTestName = "err signal";
        writeProgram(emul_progMem, 0, FAILING_SECTION.words);
        emul.progMem.assignPage(0, emul_progMem);

        resetAll(emul);
        
        map3pages(emul);
        mapDataPages(emul);

        for (int iter = 0; 1; iter++) begin
            emul.executeStep();
            if (emul.status.error == 1) break;
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", "error sig");
            emul.drain();
            #DELAY;
        end
    endtask

    task automatic runIntTestEmul(ref Emulator emul);
        time DELAY = 1;
        Word emul_progMem[] = new[4096 / 4];

        emulTestName = "int";
        prepareTest(emul_progMem, "events2");
        emul.progMem.assignPage(0, emul_progMem);

        resetAll(emul);

        map3pages(emul);
        mapDataPages(emul);

        for (int iter = 0; 1; iter++) begin
            if (iter == 3) begin 
                emul.interrupt();
                #DELAY;
            end

            emul.executeStep();
            if (emul.status.error == 1) $fatal(2, ">>>> Emulation in error state\n");
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", "events2");
            if (emul.status.send == 1) break;
            emul.drain();
            #DELAY;
        end
    endtask


    task automatic performEmul(ref Emulator emul);
        time DELAY = 1;

        for (int iter = 0; 1; iter++) begin
            emul.executeStep();
            if (emul.status.error == 1) $fatal(2, ">>>> Emulation in error state\n%p", emul);
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", emulTestName);
            if (emul.status.send == 1) break;
            emul.drain();
            #DELAY;
        end
    endtask

    task automatic resetAll(ref Emulator emul);
        time DELAY = 1;
        emul.resetWithDataMem();
            emul.programMappings.delete();
            emul.dataMappings.delete();
        
        #DELAY;
    endtask


    task automatic runEmul();
        Runner1 runner1 = new();
            Word emul_progMem2[] = new[4096 / 4];
            
            emul_N.progMem.assignPage(PAGE_SIZE, common.words);
            prepareHandlers(emul_progMem2, DEFAULT_CALL_SECTION, FAILING_SECTION, DEFAULT_EXC_SECTION);
            emul_N.progMem.assignPage(2*PAGE_SIZE, emul_progMem2);
        runner1.announceSuites = 0;
        #1 runner1.runSuites(allSuites);
        
            prepareHandlers(emul_progMem2, TESTED_CALL_SECTION, FAILING_SECTION, DEFAULT_EXC_SECTION);
            emul_N.progMem.assignPage(2*PAGE_SIZE, emul_progMem2);       
        #1 runErrorTestEmul(emul_N);
        
            prepareHandlers(emul_progMem2, TESTED_CALL_SECTION, FAILING_SECTION, DEFAULT_EXC_SECTION);
            emul_N.progMem.assignPage(2*PAGE_SIZE, emul_progMem2);
        #1 runTestEmul("events", emul_N, TESTED_CALL_SECTION);
        
            prepareHandlers(emul_progMem2, TESTED_CALL_SECTION, DEFAULT_INT_SECTION, DEFAULT_EXC_SECTION);
            emul_N.progMem.assignPage(2*PAGE_SIZE, emul_progMem2);
        #1 runIntTestEmul(emul_N);
        #1;      
    endtask

    initial common = processLines(readFile({codeDir, "common_asm", ".txt"}));

    initial runEmul();

    //////////////////////////////////////////////////////
    ////////////////////////////////////////////////

    // Core sim
    generate
        class SimRunner extends TestRunner;
            task automatic runTest(input string name);
                runTestSim(name, DEFAULT_CALL_SECTION);
            endtask
        endclass

        logic reset = 0, int0 = 0, done, wrong;
        PageBasedProgramMemory theProgMem = new();
        Mword fetchAdr;       


        task automatic runTestSim(input string name, input Section callSec);
                Word emul_progMem[] = new[4096 / 4]; // TODO: refactor to set page 0 with test program in 1 line, without additional vars

            #CYCLE announce(name);
            prepareTest(emul_progMem, name);
            theProgMem.assignPage(0, emul_progMem);

            core.resetForTest();
            core.programMem = theProgMem;
                mapDataPages(core.renamedEmul);
                mapDataPages(core.retiredEmul);

            core.instructionCache.prefetchForTest();
            core.dataCache.prefetchForTest();
            startSim();
            
            awaitResult();
        endtask

        task automatic runIntTestSim();
                Word emul_progMem[] = new[4096 / 4];

            #CYCLE announce("int");
            prepareTest(emul_progMem, "events2");
            theProgMem.assignPage(0, emul_progMem);
 
            core.resetForTest();
            core.programMem = theProgMem;
            
            core.instructionCache.prefetchForTest();
            core.dataCache.prefetchForTest();
            startSim();

            // The part that differs from regular sim test
            wait (fetchAdr == IP_CALL);
            #CYCLE; // FUTURE: should be wait for clock instead of delay?
            pulseInt0();

            awaitResult();
        endtask


        task automatic startSim();
            #CYCLE reset <= 1;
            #CYCLE reset <= 0;
            #CYCLE;
        endtask

        task automatic awaitResult(); 
            wait (done | wrong);
            if (wrong) $fatal(2, "TEST FAILED: %s", simTestName);
            #CYCLE;
        endtask

        task announce(input string name);
            simTestName = name;
            $display("> RUN: %s", name);
        endtask

        task pulseInt0();
            int0 <= 1;
            #CYCLE;
            int0 <= 0;
            #CYCLE;
        endtask

        
        AbstractCore core(
            .clk(clk),
            
            .interrupt(int0),
            .reset(reset),
            .sig(done),
            .wrong(wrong)
        );


        task automatic runSim();
            SimRunner runner = new();
              Word emul_progMem2[] = new[4096 / 4];
              
                theProgMem.assignPage(PAGE_SIZE, common.words);
                prepareHandlers(emul_progMem2, DEFAULT_CALL_SECTION, FAILING_SECTION, DEFAULT_EXC_SECTION);
                theProgMem.assignPage(2*PAGE_SIZE, emul_progMem2);
            #CYCLE runner.runSuites(allSuites);  
            
                // Now assure that a pullback and reissue has happened because of mem replay
                core.insMap.assertReissue();
            
            $display("Event tests");
            
                prepareHandlers(emul_progMem2, TESTED_CALL_SECTION, FAILING_SECTION, DEFAULT_EXC_SECTION);
                theProgMem.assignPage(2*PAGE_SIZE, emul_progMem2);
            runTestSim("events", TESTED_CALL_SECTION);
            
                prepareHandlers(emul_progMem2, TESTED_CALL_SECTION, DEFAULT_INT_SECTION, DEFAULT_EXC_SECTION);
                theProgMem.assignPage(2*PAGE_SIZE, emul_progMem2);
            runIntTestSim();
            
            $display("All tests done;");
            $stop(2);
        endtask


        assign fetchAdr = core.insAdr; 

        initial runSim();

    endgenerate


endmodule
