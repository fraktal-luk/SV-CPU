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


    EmulTest emulTest();


    localparam CYCLE = 10;

    logic clk = 1;

    always #(CYCLE/2) clk = ~clk; 


    squeue uncachedSuites = '{
        "Tests_basic_uncached.txt"//,
        //"Tests_mem_simple.txt"
    };

    squeue cachedFetchSuites = '{
        "Tests_icache_fetch.txt"
    };
   
    squeue allSuites = '{
        "Tests_basic.txt",
        "Tests_mem_simple.txt",
        
        "Tests_mem_advanced.txt",
        "Tests_mem_align.txt",
        "Tests_sys_transfers.txt",
        
        "Tests_all.txt"
    };



    string emulTestName, simTestName;

    Section common;
    Mword commonAdr = COMMON_ADR;

    function automatic WordArray prepareTestPage(input string name, input Mword commonAdr);
        Section testProg = fillImports(processLines(readFile({codeDir, name, ".txt"})), 0, common, commonAdr);
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
        task automatic runTest(input string name);
            runTestEmul(name, emul_N, gp, programMem);
            #DELAY;
        endtask
    endclass


    task automatic runEmulEvents();
        $display("Emulation event tests");

        emul_N.progMem.assignPage(PAGE_SIZE, common.words);
        emul_N.progMem.assignPage(2*PAGE_SIZE, prepareHandlersPage());

        #DELAY runTestEmul("events", emul_N, Test_fillGpCached(), emul_N.progMem);

        emul_N.progMem.assignPage(2*PAGE_SIZE, prepareHandlersPage());

        #DELAY runIntTestEmul(emul_N);
        #DELAY;
    endtask
    
    
    task automatic runTestEmul(input string name, ref Emulator emul, input GlobalParams gp, input PageBasedProgramMemory progMem);
        emulTestName = name;
            
        resetAll(emul);
        emul.progMem = progMem;

        emul.progMem.assignPage(0, prepareTestPage(name, COMMON_ADR));
        emul.progMem.assignPage(3*PAGE_SIZE, emul.progMem.getPage(0)); // copy of page 0, not preloaded

        emul.status = gp.initialCoreStatus;
        emul.programMappings = gp.preloadedInsTlbL2;
        emul.dataMappings = gp.preloadedDataTlbL2;   

        // TODO: like the comment in AbstractCore
        emul.syncRegsFromStatus();
        emul.syncCregsFromSysRegs();

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
        
        // TODO: like the comment in AbstractCore
        emul.syncRegsFromStatus();
        emul.syncCregsFromSysRegs();
        
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
        .wrong(wrong)
    );

    assign fetchAdr = core.insAdr; 

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


    class SimRunner extends TestRunner;
        task automatic runTest(input string name);            
            runTestSim(name, gp, programMem);
        endtask
    endclass



    task automatic runTestSim(input string name, input GlobalParams gp, input PageBasedProgramMemory progMem);
        #CYCLE announce(name);
        progMem.assignPage(0, prepareTestPage(name, COMMON_ADR));
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
        thisProgMem.assignPage(2*PAGE_SIZE, prepareHandlersPage());//TESTED_CALL_SECTION));//, DEFAULT_INT_SECTION, DEFAULT_EXC_SECTION));

        runner.gp = Test_fillGpUncached();

        #CYCLE $display("Uncached suites");
        runner.runSuites(uncachedSuites);

        runner.gp = Test_fillGpCached();

        #CYCLE $display("Cached fetch suites");
        runner.runSuites(cachedFetchSuites); 

        #CYCLE $display("Normal suites"); 
        runner.runSuites(allSuites);  
    endtask


    task automatic runEventSim(ref TestRunner runner);
        PageBasedProgramMemory thisProgMem = theProgMem;
        runner.programMem = thisProgMem;
        runner.gp = Test_fillGpCached();
        
        thisProgMem.assignPage(PAGE_SIZE, common.words);

        startSim(); // Pulse reset to flush old mem content from pipeline
        thisProgMem.assignPage(2*PAGE_SIZE, prepareHandlersPage());//TESTED_CALL_SECTION));//, DEFAULT_INT_SECTION, DEFAULT_EXC_SECTION));

        #CYCLE $display("Event tests");

        runTestSim("events", Test_fillGpCached(), thisProgMem);

        runIntTestSim(Test_fillGpCached(), thisProgMem);
    endtask


    task automatic simMain();
        SimRunner runner = new();
        EmulRunner emRunner = new();
        TestRunner trSim = runner;
        TestRunner trEm = emRunner;        
        
        
            TMP_tst();
        
        common = processLines(readFile({codeDir, "common_asm", ".txt"}));
                
        if (RUN_EMUL_TESTS) begin
            runSim(trEm);
            runEmulEvents();
        end
        
        if (RUN_SIM_TESTS) begin
            runSim(trSim);
            // Now assure that a pullback and reissue has happened because of mem replay
            core.insMap.assertReissue();
            
            runEventSim(trSim);
        end
        
        $display("All tests done;");
        $stop(2);
    endtask


    initial simMain();

        // TODO: remove when referenced somewhere else
        task automatic TMP_tst();
            CpuControlRegisters cregs;
        endtask


    /*
        Test setup routines
    */

    function automatic GlobalParams Test_fillGpUncached();
        GlobalParams gp;
        gp.initialCoreStatus = DEFAULT_CORE_STATUS;
        
        Ins_prepareForUncachedTest(gp);
        return gp;
    endfunction

    function automatic GlobalParams Test_fillGpCached();
        GlobalParams gp;
        gp.initialCoreStatus = DEFAULT_CORE_STATUS;
        // TODO: bring in line with DB_enableMmu - API to work on status indepedently of Emulator object? 
        gp.initialCoreStatus.enableMmu = 1;
        gp.initialCoreStatus.memControl = 7;
        
        Ins_prefetchForTest(gp);
        Data_prefetchForTest(gp);
        return gp;
    endfunction


    function automatic void Data_prefetchForTest(ref GlobalParams params);
        DataLineDesc cachedDesc = '{allowed: 1, canRead: 1, canWrite: 1, canExec: 0, cached: 1};
        DataLineDesc uncachedDesc = '{allowed: 1, canRead: 1, canWrite: 1, canExec: 0, cached: 0};

        Translation physDataPage0 = '{present: 1, vadr: 0, desc: cachedDesc, padr: 0};
        Translation physDataPage1 = '{present: 1, vadr: PAGE_SIZE, desc: cachedDesc, padr: 4096};
        Translation physDataPage2000 = '{present: 1, vadr: 'h2000, desc: cachedDesc, padr: 'h2000};
        Translation physDataPage20000000 = '{present: 1, vadr: 'h20000000, desc: cachedDesc, padr: 'h20000000};
        Translation physDataPageUnc = '{present: 1, vadr: 'h40000000, desc: uncachedDesc, padr: 'h40000000};

        params.preloadedDataTlbL1 = '{physDataPage0, physDataPage1, physDataPage2000, physDataPageUnc};
        params.preloadedDataTlbL2 = '{physDataPage0, physDataPage1, physDataPage2000, physDataPageUnc, physDataPage20000000};

        params.preloadedDataWays = '{0};            
    endfunction

    function automatic void Ins_prefetchForTest(ref GlobalParams params);
        DataLineDesc cachedDesc = '{allowed: 1, canRead: 1, canWrite: 1, canExec: 1, cached: 1};
        DataLineDesc uncachedDesc = '{allowed: 1, canRead: 1, canWrite: 1, canExec: 1, cached: 0};

        Translation physInsPage0 = '{present: 1, vadr: 0, desc: cachedDesc, padr: 0};
        Translation physInsPage1 = '{present: 1, vadr: PAGE_SIZE, desc: cachedDesc, padr: PAGE_SIZE};
        Translation physInsPage2 = '{present: 1, vadr: 2*PAGE_SIZE, desc: cachedDesc, padr: 2*PAGE_SIZE};
        Translation physInsPage3 = '{present: 1, vadr: 3*PAGE_SIZE, desc: cachedDesc, padr: 3*PAGE_SIZE};
        Translation physInsPage3_alt = '{present: 1, vadr: 4*PAGE_SIZE, desc: cachedDesc, padr: 3*PAGE_SIZE};
        Translation physInsPage0_alt = '{present: 1, vadr: 8*PAGE_SIZE, desc: cachedDesc, padr: 0};

        params.copiedInsPages =   '{0, PAGE_SIZE, 2*PAGE_SIZE, 3*PAGE_SIZE};
        params.preloadedInsWays = '{0, PAGE_SIZE, 2*PAGE_SIZE};

        params.preloadedInsTlbL1 = '{physInsPage0, physInsPage1, physInsPage2, physInsPage3};
        params.preloadedInsTlbL2 = '{physInsPage0, physInsPage1, physInsPage2, physInsPage3, physInsPage3_alt, physInsPage0_alt};        
    endfunction
    
    function automatic void Ins_prepareForUncachedTest(ref GlobalParams params);
        params.copiedInsPages =   '{0, PAGE_SIZE, 2*PAGE_SIZE, 3*PAGE_SIZE};
        params.preloadedInsWays = {};

        params.preloadedInsTlbL1 = '{};
        params.preloadedInsTlbL2 = '{};        
    endfunction


endmodule
