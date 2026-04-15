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

    localparam time CYCLE = 10;


    squeue devTestsUnc = '{
        "Tests_DEV",
        "Tests_DEV_unc",
        "Tests_DEV_basic"
    };

    squeue testsDevCached = '{
        "Tests_events_NEW",

        "Tests_all", // TODO: Not all, name is misleading
        "Tests_barriers",
        "Tests_mem_simple",
        "Tests_mem_align",
        "Tests_mem_advanced",
        "Tests_sys_transfers",

        "Tests_DEV",
        "Tests_NEW",
        "Tests_DEV_basic"
    };


    EmulTest emulTest(); // Checks basic behaviors

    string emulTestName, simTestName;

    CodeSecArr handlers;

    Emulator mainEmul = new();

    logic clk = 1;

    always #(CYCLE/2) clk = ~clk; 


    class EmulRunner extends TestRunner;        
        task automatic runTest(input string suiteName, input string name);
            runTestEmul(suiteName, name, mainEmul, gp);
            #DELAY;
        endtask
    endclass

    class SimRunner extends TestRunner;
        task automatic runTest(input string suiteName, input string name);            
            runTestSim(suiteName, name, gp);
        endtask
    endclass


    task automatic runIntTestEmul(ref Emulator emul);
        GlobalParams gp = Test_fillGpCached();

        $display("Emulation event/int tests");
        //#DELAY;

        emulTestName = "int";

        resetAll(emul);

        setTestMemories("events_int", emul.progMem, emul.dataMem, handlers);

        emul.initCore(gp.initialCregs, gp.preloadedInsTlbL2, gp.preloadedDataTlbL2);

        for (int iter = 0; 1; iter++) begin
            if (iter == 3) begin 
                emul.interrupt();
                #DELAY;
            end

            emul.executeStep();
            if (isErrorStatus(emul)) $fatal(2, ">>>> Emulation in error state\nTest name: events_int");
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", "events_int");
            if (isSendingStatus(emul)) break;
            emul.drain();
            emul.catchDbTrap();
            #DELAY;
        end

        #DELAY;
    endtask


    task automatic runTestEmul(input string suiteName, input string name, ref Emulator emul, input GlobalParams gp);
        string prefix = {"dir_", suiteName, "/"};
        CodeSecArr testSections = processFile(readFile({codeDir, prefix, name, ".txt"}));

        emulTestName = name;

        resetAll(emul);
        emul.progMem = new();
        emul.dataMem = new();
        setTestMemories({prefix, name}, emul.progMem, emul.dataMem, handlers);

        emul.initCore(gp.initialCregs, gp.preloadedInsTlbL2, gp.preloadedDataTlbL2);
        emul.resetSignal();

        performEmul(emul);
        checkOutput(emul.dataMem, testSections);
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
    Mword fetchAdr;

    AbstractCore core(
        .clk(clk),
        .interrupt(int0),
        .reset(reset),
        .sig(done),
        .wrong(wrong) // UNUSED
    );

    assign fetchAdr = core.insAdr; 


    task automatic runTestSim(input string suiteName, input string name, input GlobalParams gp);
        string prefix = {"dir_", suiteName, "/"};

        CodeSecArr testSections = processFile(readFile({codeDir, prefix, name, ".txt"}));
        WordArray outputWay;

        #CYCLE announce(name);
        core.resetForTest();
        setTestMemories({prefix, name}, core.programMem, core.dataMem, handlers);
        core.globalParams = gp;
        core.preloadForTest();

        startSim();
        awaitResult();

        // Compare outputs if cache enabled
        if (gp.initialCregs.memControl == 0) begin
            checkOutput(core.dataMem, testSections);
            return;
        end

        outputWay = core.dataCache.dataArray.readWholeWay(4);
        checkOutputWA(outputWay, testSections);
    endtask


    task automatic runIntTestSim();
        CodeSecArr testSections = processFile(readFile({codeDir, "events_int", ".txt"}));
        WordArray outputWay;

        GlobalParams gp = Test_fillGpCached();
        gp.initialCregs.memControl = 7;

        #CYCLE announce("int");
        core.resetForTest();
        setTestMemories("events_int", core.programMem, core.dataMem, handlers);
        core.globalParams = gp;
        core.preloadForTest();

        startSim();

        // The part that differs from regular sim test
        #(20*CYCLE); // FUTURE: should be wait for clock instead of delay?
        pulseInt0();
        awaitResult();

        outputWay = core.dataCache.dataArray.readWholeWay(4);
        checkOutputWA(outputWay, testSections);
    endtask


    task automatic simMain();
        EmulRunner emRunner = new();
        TestRunner trEm = emRunner;

        SimRunner runner = new();
        TestRunner trSim = runner;

        handlers = processFile(readFile({codeDir, "handlers.txt"}));;

        if (RUN_EMUL_TESTS) begin
            runIntTestEmul(mainEmul);

            trEm.gp = Test_fillGpCached();
            trEm.gp.initialCregs.memControl = 7;
            #CYCLE $display("\n>>>>>> Em  Dev tests");
            trEm.runSuites(testsDevCached);

            trEm.gp.initialCregs.memControl = 0;
            #CYCLE $display("\n>>>>>> Em  Dev tests unc");
            trEm.runSuites(devTestsUnc);
        end

        if (RUN_SIM_TESTS) begin
            trSim.gp = Test_fillGpCached();
            trSim.gp.initialCregs.memControl = 0;

            #CYCLE $display("\n>>>>>> Sim  Dev tests unc");
            trSim.runSuites(devTestsUnc);

            // TODO: why here?  Now assure that a pullback and reissue has happened because of mem replay
            core.insMap.assertReissue();

            #CYCLE $display("\n>>>>>> Event/int tests");
            runIntTestSim();

            trSim.gp = Test_fillGpCached();
            trSim.gp.initialCregs.memControl = 7;

            #CYCLE $display("\n>>>>>> Sim  Dev tests");
            trSim.runSuites(testsDevCached);
        end
        
        $display("All tests done;");
        $stop(2);
    endtask

    initial simMain();


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

endmodule
