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



    string emulTestName, simTestName;

    CodeSec common;
    //Mword commonAdr = COMMON_ADR;

    function automatic WordArray prepareTestPage(input string name, input Mword commonAdr);
        CodeSec testProg = fillImports(processLines(readFile({codeDir, name, ".txt"})), 0, common, commonAdr);
        return testProg.words;
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


    task automatic runEmulEvents();
        $display("Emulation event/int tests");

        emul_N.progMem.assignPage(PAGE_SIZE, common.words);
        emul_N.progMem.assignPage(2*PAGE_SIZE, prepareHandlersPage());

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

        emul.programMappings = gp.preloadedInsTlbL2;
        emul.dataMappings = gp.preloadedDataTlbL2;

        emul.initStatus(gp.initialCregs);

        performEmul(emul);
    endtask


    task automatic runIntTestEmul(ref Emulator emul);
        GlobalParams gp;

        emulTestName = "int";

        resetAll(emul);
        emul.progMem.assignPage(0, prepareTestPage("events2", COMMON_ADR));

        Ins_prefetchForTest(gp);
        Data_prefetchForTest(gp);
        emul.programMappings = gp.preloadedInsTlbL2;
        emul.dataMappings = gp.preloadedDataTlbL2;

        emul.initStatus(gp.initialCregs);
        
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


    task automatic runTestSim(input string suiteName, input string name, input GlobalParams gp, input PageBasedProgramMemory progMem);
        string prefix = {"dir_", suiteName, "/"};

        #CYCLE announce(name);
        progMem.assignPage(0, prepareTestPage({prefix, name}, COMMON_ADR));
        progMem.assignPage(3*PAGE_SIZE, progMem.getPage(0)); // copy of page 0, not preloaded

        core.resetForTest();
        core.programMem = progMem;
        core.globalParams = gp;
        core.preloadForTest();

        startSim();
        
        awaitResult();
    endtask


    task automatic runIntTestSim(input GlobalParams gp, input PageBasedProgramMemory progMem);
        #CYCLE announce("int");
        progMem.assignPage(0, prepareTestPage("events2", COMMON_ADR));

        core.resetForTest();
        core.programMem = progMem;
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
        thisProgMem.assignPage(2*PAGE_SIZE, prepareHandlersPage());

        runner.gp = Test_fillGpUncached();

        #CYCLE $display("Uncached suites");
        runner.runSuites(uncachedSuites);

        runner.gp = Test_fillGpCached();

        #CYCLE $display("Cached fetch suites");
        runner.runSuites(cachedFetchSuites); 

        #CYCLE $display("Normal suites"); 
        runner.runSuites(normalSuites);  
    endtask


    task automatic runEventSim(ref TestRunner runner);
        PageBasedProgramMemory thisProgMem = theProgMem;
        runner.programMem = thisProgMem;
        runner.gp = Test_fillGpCached();
        
        thisProgMem.assignPage(PAGE_SIZE, common.words);

        startSim(); // Pulse reset to flush old mem content from pipeline
        thisProgMem.assignPage(2*PAGE_SIZE, prepareHandlersPage());

        #CYCLE $display("Event/int tests");

        runIntTestSim(Test_fillGpCached(), thisProgMem);
    endtask


    task automatic simMain();
        EmulRunner emRunner = new();
        TestRunner trEm = emRunner;        

        SimRunner runner = new();
        TestRunner trSim = runner;

        common = processLines(readFile({codeDir, "common_asm", ".txt"}));
                
        if (RUN_EMUL_TESTS) begin
            DEV_testEmul();

            runSim(trEm);
            runEmulEvents();
        end
        
        if (RUN_SIM_TESTS) begin
            DEV_testSim();

            runSim(trSim);
            // Now assure that a pullback and reissue has happened because of mem replay
            core.insMap.assertReissue();
            
            runEventSim(trSim);
        end
        
        $display("All tests done;");
        $stop(2);
    endtask


    initial simMain();


    task automatic DEV_testEmul();
        EmulRunner devRunner = new();
        TestRunner runner = devRunner; 
        DEV_runEmul(runner);
    endtask


    task automatic DEV_testSim();
        EmulRunner devRunner = new(); // type of runner is irrelevant here
        TestRunner runner = devRunner;


            processTest(readFile({codeDir, "dir_DEV_tests/dev_test.txt"}));

        DEV_runSim(runner);
    endtask


    task automatic DEV_runEmul(ref TestRunner runner);
        PageBasedProgramMemory thisProgMem = theProgMem;
        runner.programMem = thisProgMem;

        thisProgMem.assignPage(PAGE_SIZE, common.words);
        thisProgMem.assignPage(2*PAGE_SIZE, prepareHandlersPage());

        runner.gp = Test_fillGpCached();

        $error("DEV run"); 
        runTestEmul("DEV_tests", "dev_test", emul_N, runner.gp, runner.programMem);
        // TODO: check output page 

        $error("DEV run OK");


        #DELAY;
    endtask

    task automatic DEV_runSim(ref TestRunner runner);
        PageBasedProgramMemory thisProgMem = theProgMem;
        runner.programMem = thisProgMem;

        thisProgMem.assignPage(PAGE_SIZE, common.words);
        thisProgMem.assignPage(2*PAGE_SIZE, prepareHandlersPage());

        runner.gp = Test_fillGpCached();

        $error("DEV sim run"); 
        runTestSim("DEV_tests", "dev_test", runner.gp, runner.programMem);
        // TODO: check output page ???

        $error("DEV sim run OK");
        #DELAY;


    endtask


endmodule
