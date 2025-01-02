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
    localparam Mword COMMON_ADR = 1024;

    const string DEFAULT_RESET_HANDLER[$] = {"ja -512",   "ja 0", "undef"};
    const string DEFAULT_ERROR_HANDLER[$] = {"sys_error", "ja 0", "undef"};

    const string DEFAULT_CALL_HANDLER[$]  = {"sys_send", "ja 0", "undef"};
    const string TESTED_CALL_HANDLER[$] = {"add_i r20, r0, 55", "sys_rete", "ja 0"};

    const string DEFAULT_INT_HANDLER[$]  = {"add_i r21, r0, 77", "sys_reti", "ja 0"};

    const string FAILING_HANDLER[$]  = {"undef", "ja 0", "undef"};

    const string DEFAULT_EXC_HANDLER[$]  = {"add_i r1, r0, 37", "lds r20, r0, 2", "add_i r21, r20, 4", "sts r21, r0, 2", "sys_rete", "ja 0"};


    //typedef Mbyte DynamicDataMem[];


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
    squeue allSuites = '{"tests_all.txt", "tests_some.txt"};
    
    string emulTestName, simTestName;

    Emulator emul_N = new();


    class Runner1 extends TestRunner;
        task automatic runTest(input string name);
            runTestEmul(name, emul_N, DEFAULT_CALL_SECTION);
            #1;
        endtask
    endclass


    task automatic setPrograms(ref Word mem[],
                              input Section testSec, input Section resetSec, input Section errorSec, input Section callSec, input Section intSec, input Section excSec);
        mem = '{default: 'x};
                 
        writeProgram(mem, 0, testSec.words);
        
        writeProgram(mem, IP_RESET, resetSec.words);
        writeProgram(mem, IP_ERROR, errorSec.words);
        writeProgram(mem, IP_CALL, callSec.words);
        writeProgram(mem, IP_INT, intSec.words);
        writeProgram(mem, IP_EXC, excSec.words);
        
        writeProgram(mem, COMMON_ADR, common.words);
    endtask


    task automatic prepareTest(ref Word mem[],
                               input string name, input Section callSec, input Section intSec, input Section excSec);
        Section testProg = fillImports(processLines(readFile({name, ".txt"})), 0, common, COMMON_ADR);
        setPrograms(mem, testProg, DEFAULT_RESET_SECTION, DEFAULT_ERROR_SECTION, callSec, intSec, excSec);
    endtask


    task automatic runEmul();
        Runner1 runner1 = new();
        
            emul_N.progMem_N.linkPage(0, emul_N.progMem);
        
          //  PageBasedProgramMem pmem =  emul_N.progMem_N;
        
          //  emul_N.progMem_N.createPage(0);
          //  emul_N.progMem_N.createPage(4096);
            
          //  PageBasedProgramMem pmem = new();
          //  pmem.linkPage(0, common.words);
        
         //   pmem.createPage(4096);
            
        
        #1 runner1.runSuites(allSuites);
        
           // pmem.linkPage(0, emul_N.progMem);
        
           // $error("!!! %x %x %x %x", pmem.fetch(0), pmem.fetch(4), pmem.fetch(8), pmem.fetch(5005));
        
        #1 runErrorTestEmul(emul_N);
        #1 runTestEmul("events", emul_N, TESTED_CALL_SECTION);
        #1 runIntTestEmul(emul_N);
        #1;      
    endtask


    // Emul-only run
    task automatic runTestEmul(input string name, ref Emulator emul, input Section callSec);
        emulTestName = name;
        prepareTest(emul.progMem, name, callSec, FAILING_SECTION, DEFAULT_EXC_SECTION);
            
            emul.progMem_N.linkPage(0, emul.progMem);
           // $error("  cmp: %x %x %x", emul.progMem[1], emul.progMem_N.pages[0][1], 'z);
        
            saveProgramToFile({"ZZZ_", name, ".txt"}, emul.progMem);

        resetAll(emul);
        performEmul(emul);
    endtask


    task automatic runErrorTestEmul(ref Emulator emul);
        emulTestName = "err signal";
        writeProgram(emul.progMem, 0, FAILING_SECTION.words);
                    emul.progMem_N.linkPage(0, emul.progMem);

        resetAll(emul);

        for (int iter = 0; 1; iter++) begin
            emul.executeStep();
            if (emul.status.error == 1) break;
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", "error sig");
            emul.drain();
            #1;
        end
    endtask

    task automatic runIntTestEmul(ref Emulator emul);
        emulTestName = "int";
        prepareTest(emul.progMem, "events2", TESTED_CALL_SECTION, DEFAULT_INT_SECTION, DEFAULT_EXC_SECTION);
            emul.progMem_N.linkPage(0, emul.progMem);

        resetAll(emul);

        for (int iter = 0; 1; iter++) begin
            if (iter == 3) begin 
                emul.interrupt();
                #1;
            end

            emul.executeStep();
            if (emul.status.error == 1) $fatal(2, ">>>> Emulation in error state\n");
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", "events2");
            if (emul.status.send == 1) break;
            emul.drain();
            #1;
        end
    endtask


    task automatic performEmul(ref Emulator emul);
        for (int iter = 0; 1; iter++) begin
            emul.executeStep();
            if (emul.status.error == 1) $fatal(2, ">>>> Emulation in error state\n");
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", emulTestName);
            if (emul.status.send == 1) break;
            emul.drain();
            #1;
        end
    endtask

    task automatic resetAll(ref Emulator emul);
        emul.reset();
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


        task automatic runSim();
            SimRunner runner = new();

                core.renamedEmul.progMem_N.linkPage(0, core.renamedEmul.progMem);

            #CYCLE runner.runSuites(allSuites);  
            
                // Now assure that a pullback and reissue has happened because of mem replay
                core.insMap.assertReissue();
            
            runTestSim("events", TESTED_CALL_SECTION);
            runIntTestSim();
            
            $display("All tests done;");
            $stop(2);
        endtask
        
        
        task automatic runTestSim(input string name, input Section callSec);
            #CYCLE announce(name);
            prepareTest(core.renamedEmul.progMem, name, callSec, FAILING_SECTION, DEFAULT_EXC_SECTION);
                core.renamedEmul.progMem_N.linkPage(0, core.renamedEmul.progMem);
            
            startSim();
            awaitResult();
        endtask

        task automatic runIntTestSim();
            #CYCLE announce("int");
            prepareTest(core.renamedEmul.progMem, "events2", TESTED_CALL_SECTION, DEFAULT_INT_SECTION, DEFAULT_EXC_SECTION);
                core.renamedEmul.progMem_N.linkPage(0, core.renamedEmul.progMem);

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
            core.instructionCache.setProgram(core.renamedEmul.progMem);
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

        initial runSim();

        assign fetchAdr = core.insAdr; 

        
        AbstractCore core(
            .clk(clk),
            
            .interrupt(int0),
            .reset(reset),
            .sig(done),
            .wrong(wrong)
        );

    endgenerate


endmodule
