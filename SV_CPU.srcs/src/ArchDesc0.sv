`timescale 1ns / 1fs

import Base::*;
import InsDefs::*;
import ControlRegisters::*;
import Asm::*;
import EmulationDefs::*;
import Emulation::*;
import AbstractSim::*;
import Insmap::*;

import Testing::*;


module ArchDesc0();
    localparam logic RUN_EMUL_TESTS = 1;
    localparam logic RUN_SIM_TESTS = 1;

    localparam time DELAY = 1;

    localparam int ITERATION_LIMIT = 2000;
    localparam Mword COMMON_ADR = 4 * 1024;


    EmulTest emulTest(); // Checks basic behaviors


    localparam CYCLE = 10;

    logic clk = 1;

    always #(CYCLE/2) clk = ~clk; 


    squeue uncachedSuites = '{
        "Tests_basic",
        "Tests_only_uncached"
    };

    squeue cachedFetchSuites = '{
        "Tests_icache_fetch"
    };
   
    squeue normalSuites = '{
        "Tests_basic",
        "Tests_mem_simple",

        "Tests_mem_advanced",
        "Tests_mem_align",
        "Tests_sys_transfers",
        
        "Tests_barriers",

        "Tests_all", // TODO: Not all, name is misleading
        
        "Tests_events"
    };

        squeue devTests = '{
            "Tests_DEV"
        };

        squeue newTests = '{
            "Tests_DEV",
            "Tests_NEW"
        };


    string emulTestName, simTestName;

    CodeSec common;

    function automatic WordArray prepareTestPage(input string name, input Mword commonAdr);
        CodeSecArr testSections = processFile(readFile({codeDir, name, ".txt"}));
        CodeSec testProg = fillImports(testSections[0], 0, common, commonAdr);
        return testProg.words;
    endfunction


    function automatic void setTestMemories(input string name, ref PageBasedProgramMemory pmem, ref SparseDataMemory dmem);
        CodeSecArr testSections = processFile(readFile({codeDir, name, ".txt"}));
        CodeSecArr handlers = processFile(readFile({codeDir, "handlers.txt"}));

        // TODO: fill imports of every section using lib section (should be provided separately)
        foreach (testSections[i]) testSections[i] = fillImports(testSections[i], 0, common, 0 /*TODO: lib section and proper load addresses*/);

        allocateSections(testSections, pmem, dmem);
        allocateSections(handlers, pmem, dmem);

    endfunction



    /* Emulation */
    Emulator emul_N = new();


    function automatic logic isErrorStatus(input Emulator emul);            
        return emul.status.eventType inside {PE_SYS_ERROR, PE_SYS_UNDEFINED_INSTRUCTION};
    endfunction

    function automatic logic isSendingStatus(input Emulator emul);            
        return emul.status.send == 1;
    endfunction
    
    task automatic resetAll(ref Emulator emul);
        emul.resetWithDataMem();
        #DELAY;
    endtask


    class EmulRunner extends TestRunner;        
        task automatic runTest(input string suiteName, input string name);
            runTestEmul(suiteName, name, emul_N, gp, programMem);
            #DELAY;
        endtask
    endclass

    class EmulRunner_N extends TestRunner;        
        task automatic runTest(input string suiteName, input string name);
            runTestEmul_N(suiteName, name, emul_N, gp);
            #DELAY;
        endtask
    endclass


    task automatic runEmulEvents();
        $display("Emulation event/int tests");

        emul_N.progMem.assignPage(PAGE_SIZE, common.words);
        emul_N.progMem.assignPage(4*PAGE_SIZE, prepareHandlersPage());

        #DELAY runIntTestEmul(emul_N);
        #DELAY;
    endtask
    
    
    task automatic runTestEmul(input string suiteName, input string name, ref Emulator emul, input GlobalParams gp, input PageBasedProgramMemory progMem);
        string prefix = {"dir_", suiteName, "/"};

        emulTestName = name;

        resetAll(emul);
        emul.progMem = progMem;

        emul.progMem.assignPage(0, prepareTestPage({prefix, name}, COMMON_ADR));
        emul.progMem.assignPage(3*PAGE_SIZE, emul.progMem.getPage(0)); // copy of page 0, not preloaded
        emul.progMem.assignPage(5*PAGE_SIZE, emul.progMem.getPage(0)); // copy of page 0, not preloaded

        emul.initCore(gp.initialCregs, gp.preloadedInsTlbL2, gp.preloadedDataTlbL2);

        performEmul(emul);
    endtask

        task automatic runTestEmul_N(input string suiteName, input string name, ref Emulator emul, input GlobalParams gp);
            string prefix = {"dir_", suiteName, "/"};
            CodeSecArr testSections = processFile(readFile({codeDir, prefix, name, ".txt"}));

            emulTestName = name;

            resetAll(emul);
            emul.progMem = new();
            emul.dataMem = new();


            setTestMemories({prefix, name}, emul.progMem, emul.dataMem);

            // // TODO: fill imports of every section using lib section (should be provided separately)
            // foreach (testSections[i]) testSections[i] = fillImports(testSections[i], 0, common, 0 /*TODO: lib section and proper load addresses*/);

            // allocateSections(testSections, emul.progMem, emul.dataMem);

                //emul.progMem.assignPage(4*PAGE_SIZE, prepareHandlersPage()); // TODO: change to new mode

            emul.initCore(gp.initialCregs, gp.preloadedInsTlbL2, gp.preloadedDataTlbL2);

            performEmul(emul);

            // Compare outputs
            // TODO

            checkOutput(emul.dataMem, testSections);

        endtask


        function automatic void checkOutput(input SparseDataMemory actualMem, input CodeSecArr sections);
            Dword OUTPUT_BASE = 4*PAGE_SIZE;
            CodeSec found[$] = sections.find with (item.desc == "output");
            if (found.size() == 0) return;

            foreach (found[0].words[i]) begin
                Word expected = found[0].words[i];
                Word actual = actualMem.readWord(OUTPUT_BASE + 4*i);

                assert (actual === expected) else begin
                    
                    $error("Mem compare: actual %x, expected %x", actual, expected);

                    $error("%p", actualMem.content);
                end

            end

        endfunction


    task automatic runIntTestEmul(ref Emulator emul);
        GlobalParams gp = Test_fillGpCached();

        emulTestName = "int";

        resetAll(emul);
        emul.progMem.assignPage(0, prepareTestPage("events2", COMMON_ADR));

        emul.initCore(gp.initialCregs, gp.preloadedInsTlbL2, gp.preloadedDataTlbL2);

        for (int iter = 0; 1; iter++) begin
            if (iter == 3) begin 
                emul.interrupt();
                #DELAY;
            end

            emul.executeStep();
            if (isErrorStatus(emul)) $fatal(2, ">>>> Emulation in error state\nTest name: events2");
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", "events2");
            if (isSendingStatus(emul)) break;
            emul.drain();
            emul.catchDbTrap();
            #DELAY;
        end
    endtask

    task automatic performEmul(ref Emulator emul);
        for (int iter = 0; 1; iter++) begin
            emul.executeStep();
            if (isErrorStatus(emul)) begin
                emul.getBasicDbView();
                $fatal(2, ">>>> Emulation in error state\nTest name: %s\n%p", emulTestName, emul);
            end
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", emulTestName);
            if (isSendingStatus(emul)) break;
            emul.drain();
            emul.catchDbTrap();
            #DELAY;
        end
    endtask


    /* Core sim */
    
    logic reset = 0, int0 = 0, done, wrong;
    PageBasedProgramMemory theProgMem = new();
    Mword fetchAdr;

    AbstractCore core(
        .clk(clk),
        .interrupt(int0),
        .reset(reset),
        .sig(done),
        .wrong(wrong) // UNUSED
    );

    assign fetchAdr = core.insAdr; 

    task automatic startSim();
        #CYCLE reset <= 1;
        #CYCLE reset <= 0;
        #CYCLE;
    endtask

    task automatic awaitResult(); 
        wait (done);
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


    class SimRunner extends TestRunner;
        task automatic runTest(input string suiteName, input string name);            
            runTestSim(suiteName, name, gp, programMem);
        endtask
    endclass


    class SimRunner_N extends TestRunner;
        task automatic runTest(input string suiteName, input string name);            
            runTestSim_N(suiteName, name, gp);
        endtask
    endclass



    task automatic runTestSim(input string suiteName, input string name, input GlobalParams gp, input PageBasedProgramMemory progMem);
        string prefix = {"dir_", suiteName, "/"};

        #CYCLE announce(name);
        progMem.assignPage(0, prepareTestPage({prefix, name}, COMMON_ADR));
        progMem.assignPage(3*PAGE_SIZE, progMem.getPage(0)); // copy of page 0, not preloaded
        progMem.assignPage(5*PAGE_SIZE, progMem.getPage(0)); // copy of page 0, not preloaded

        core.resetForTest();
        core.programMem = progMem;
        core.dataMem = new();
        core.globalParams = gp;
        core.preloadForTest();

        startSim();
        
        awaitResult();
    endtask



        task automatic runTestSim_N(input string suiteName, input string name, input GlobalParams gp);
            string prefix = {"dir_", suiteName, "/"};

            #CYCLE announce(name);
            core.resetForTest();

            core.programMem = new();
            core.dataMem = new();

            setTestMemories({prefix, name}, core.programMem, core.dataMem);

                core.programMem.assignPage(PAGE_SIZE, common.words);
                core.programMem.assignPage(3*PAGE_SIZE, core.programMem.getPage(0)); // copy of page 0, not preloaded
                core.programMem.assignPage(5*PAGE_SIZE, core.programMem.getPage(0)); // copy of page 0, not preloaded

                //core.programMem.assignPage(4*PAGE_SIZE, prepareHandlersPage());


            core.globalParams = gp;
            core.preloadForTest();

            startSim();
            
            awaitResult();

            // Compare outputs
            // TODO
        endtask



    task automatic runIntTestSim(input GlobalParams gp, input PageBasedProgramMemory progMem);
        #CYCLE announce("int");
        progMem.assignPage(0, prepareTestPage("events2", COMMON_ADR));

        core.resetForTest();
        core.programMem = progMem;
        core.dataMem = new();
        core.globalParams = gp;
        core.preloadForTest();

        startSim();

        // The part that differs from regular sim test
        wait (fetchAdr == IP_CALL);
        #CYCLE; // FUTURE: should be wait for clock instead of delay?
        pulseInt0();

        awaitResult();
    endtask


    task automatic runSim(ref TestRunner runner);
        PageBasedProgramMemory thisProgMem = theProgMem;
        runner.programMem = thisProgMem;

        thisProgMem.assignPage(PAGE_SIZE, common.words);
        thisProgMem.assignPage(4*PAGE_SIZE, prepareHandlersPage());

            runner.gp = Test_fillGpCached();
            runner.gp.initialCregs.memControl = 0;

            #CYCLE $display("Uncached suites");
            runner.runSuites(uncachedSuites);

        runner.gp.initialCregs.memControl = 7;

        #CYCLE $display("Cached fetch suites");
        runner.runSuites(cachedFetchSuites); 

        #CYCLE $display("Normal suites"); 
        runner.runSuites(normalSuites);  
    endtask


    task automatic runEventSim(ref TestRunner runner);
        PageBasedProgramMemory thisProgMem = theProgMem;
        runner.programMem = thisProgMem;
        runner.gp = Test_fillGpCached();
        runner.gp.initialCregs.memControl = 7;

        thisProgMem.assignPage(PAGE_SIZE, common.words);

        startSim(); // Pulse reset to flush old mem content from pipeline
        thisProgMem.assignPage(4*PAGE_SIZE, prepareHandlersPage());

        #CYCLE $display("Event/int tests");

        runIntTestSim(runner.gp, runner.programMem);
    endtask


    task automatic simMain();
        EmulRunner emRunner = new();
        TestRunner trEm = emRunner;

            EmulRunner_N emRunner_N = new();
            TestRunner trEm_N = emRunner_N;

        SimRunner runner = new();
        TestRunner trSim = runner;

            SimRunner_N runner_N = new();
            TestRunner trSim_N = runner_N;

        common = processLines(readFile({codeDir, "common_asm", ".txt"}));
                
        if (RUN_EMUL_TESTS) begin

           // DEV_testEmul();

            runSim(trEm);
            runEmulEvents();

            // runTestEmul_N("DEV_tests", "dev_test", emul_N, Test_fillGpCached());
            // runTestEmul_N("DEV_tests", "dev_test_2", emul_N, Test_fillGpCached());

                trEm_N.gp = Test_fillGpCached();
                trEm_N.gp.initialCregs.memControl = 7;
                #CYCLE $display("\n>>>>>> Em  Dev tests");
                trEm_N.runSuites(newTests);


                trEm_N.gp.initialCregs.memControl = 0;
                #CYCLE $display("\n>>>>>> Em  Dev tests unc");
                trEm_N.runSuites(devTests);

        end

        if (RUN_SIM_TESTS) begin
                   GlobalParams gp_N = Test_fillGpCached();
                   gp_N.initialCregs.memControl = 7;

                trSim_N.gp = Test_fillGpCached();
                trSim_N.gp.initialCregs.memControl = 0;

                #CYCLE $display("\n>>>>>> Sim  Dev tests unc");
                trSim_N.runSuites(devTests);

            runSim(trSim);
            // Now assure that a pullback and reissue has happened because of mem replay
            core.insMap.assertReissue();
            
            runEventSim(trSim);

                trSim_N.gp = Test_fillGpCached();
                trSim_N.gp.initialCregs.memControl = 7;

                #CYCLE $display("\n>>>>>> Sim  Dev tests");
                trSim_N.runSuites(newTests);

        end
        
        $display("All tests done;");
        $stop(2);
    endtask


    initial simMain();

endmodule
