`timescale 1ns / 1fs

import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import AbstractSim::*;
import Insmap::*;

import Testing::*;


module ArchDesc0();

    localparam int ITERATION_LIMIT = 2000;
    localparam Mword COMMON_ADR = 4 * 1024;

    const string DEFAULT_RESET_HANDLER[$] = {"ja -512",   "ja 0", "undef"};
    const string DEFAULT_ERROR_HANDLER[$] = {"sys_error", "ja 0", "undef"};

    const string DEFAULT_CALL_HANDLER[$]  = {"sys_send", "ja 0", "undef"};
    const string TESTED_CALL_HANDLER[$] = {"add_i r20, r0, 55", "sys_rete", "ja 0"};

    const string DEFAULT_INT_HANDLER[$]  = {"add_i r21, r0, 77", "sys_reti", "ja 0"};

    const string FAILING_HANDLER[$]  = {"undef", "ja 0", "undef"};

    const string DEFAULT_EXC_HANDLER[$]  = {"add_i r1, r0, 37", "lds r20, r0, 2", "add_i r21, r20, 4", "sts r21, r0, 2", "sys_rete", "ja 0"};


    const Section DEFAULT_RESET_SECTION = processLines(DEFAULT_RESET_HANDLER);

    const Section DEFAULT_ERROR_SECTION = processLines(DEFAULT_ERROR_HANDLER);

    const Section DEFAULT_CALL_SECTION = processLines(DEFAULT_CALL_HANDLER);
    const Section TESTED_CALL_SECTION = processLines(TESTED_CALL_HANDLER);

    const Section DEFAULT_INT_SECTION = processLines(DEFAULT_INT_HANDLER);
    const Section FAILING_SECTION = processLines(FAILING_HANDLER);

    const Section DEFAULT_EXC_SECTION = processLines(DEFAULT_EXC_HANDLER);



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
        //"tests_some.txt" - TODO: remove this file
    };
    
    string emulTestName, simTestName;

    Emulator emul_N = new();


    class Runner1 extends TestRunner;
        task automatic runTest(input string name);
            runTestEmul(name, emul_N, DEFAULT_CALL_SECTION);
            #1;
        endtask
    endclass



    task automatic prepareTest(ref Word mem[],
                               input string name, input Section callSec, input Section intSec, input Section excSec, input Mword commonAdr);
        Section testProg = fillImports(processLines(readFile({name, ".txt"})), 0, common, COMMON_ADR);
        setPrograms(mem, testProg, DEFAULT_RESET_SECTION, DEFAULT_ERROR_SECTION, callSec, intSec, excSec, common, commonAdr);
    endtask


    // Emul-only run
    task automatic runTestEmul(input string name, ref Emulator emul, input Section callSec);
            Word emul_progMem[] = new[4096];

        emulTestName = name;
        prepareTest(emul_progMem, name, callSec, FAILING_SECTION, DEFAULT_EXC_SECTION, COMMON_ADR);
            
            emul.progMem_N.assignPage(0, emul_progMem);
            emul.progMem_N.assignPage(4096, common.words);
        
            saveProgramToFile({"ZZZ_", name, ".txt"}, emul_progMem);

        resetAll(emul);
        performEmul(emul);
    endtask


    task automatic runErrorTestEmul(ref Emulator emul);
        time DELAY = 1;
            Word emul_progMem[] = new[4096];

        emulTestName = "err signal";
        writeProgram(emul_progMem, 0, FAILING_SECTION.words);
                    emul.progMem_N.assignPage(0, emul_progMem);

        resetAll(emul);

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
            Word emul_progMem[] = new[4096];

        emulTestName = "int";
        prepareTest(emul_progMem, "events2", TESTED_CALL_SECTION, DEFAULT_INT_SECTION, DEFAULT_EXC_SECTION, COMMON_ADR);
            emul.progMem_N.assignPage(0, emul_progMem);

        resetAll(emul);

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
            if (emul.status.error == 1) $fatal(2, ">>>> Emulation in error state\n");
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", emulTestName);
            if (emul.status.send == 1) break;
            emul.drain();
            #DELAY;
        end
    endtask

    task automatic resetAll(ref Emulator emul);
        time DELAY = 1;
        emul.reset();
        #DELAY;
    endtask


    task automatic runEmul();
        Runner1 runner1 = new();
        runner1.announceSuites = 0;
        #1 runner1.runSuites(allSuites);
        #1 runErrorTestEmul(emul_N);
        #1 runTestEmul("events", emul_N, TESTED_CALL_SECTION);
        #1 runIntTestEmul(emul_N);
        #1;      
    endtask

    initial common = processLines(readFile({"common_asm", ".txt"}));

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
        Mword fetchAdr;       


        task automatic runTestSim(input string name, input Section callSec);
                Word emul_progMem[] = new[4096];

            #CYCLE announce(name);
            prepareTest(emul_progMem, name, callSec, FAILING_SECTION, DEFAULT_EXC_SECTION, COMMON_ADR);
                core.renamedEmul.progMem_N.assignPage(0, emul_progMem);
                core.renamedEmul.progMem_N.assignPage(4096, common.words);
            
            startSim();
            awaitResult();
        endtask

        task automatic runIntTestSim();
                Word emul_progMem[] = new[4096];

            #CYCLE announce("int");
            prepareTest(emul_progMem, "events2", TESTED_CALL_SECTION, DEFAULT_INT_SECTION, DEFAULT_EXC_SECTION, COMMON_ADR);
                core.renamedEmul.progMem_N.assignPage(0, emul_progMem);
                core.renamedEmul.progMem_N.assignPage(4096, common.words);

            startSim();

            // The part that differs from regular sim test
            wait (fetchAdr == IP_CALL);
            #CYCLE; // FUTURE: should be wait for clock instead of delay?
            pulseInt0();

            awaitResult();
        endtask


        task announce(input string name);
            simTestName = name;
            $display("> RUN: %s", name);
        endtask

        task automatic startSim();
            core.instructionCache.setProgram(core.renamedEmul.progMem_N.getPage(0));
            core.dataCache.reset();
            
            #CYCLE reset <= 1;
            #CYCLE reset <= 0;
            #CYCLE;
        endtask

        task automatic awaitResult(); 
            wait (done | wrong);
            if (wrong) $fatal(2, "TEST FAILED: %s", simTestName);
            #CYCLE;
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

            #CYCLE runner.runSuites(allSuites);  
            
                // Now assure that a pullback and reissue has happened because of mem replay
                core.insMap.assertReissue();
            
            $display("Event tests");
            
            runTestSim("events", TESTED_CALL_SECTION);
            runIntTestSim();
            
            $display("All tests done;");
            $stop(2);
        endtask


        assign fetchAdr = core.insAdr; 

        initial runSim();

    endgenerate


endmodule
