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


    typedef Mbyte DynamicDataMem[];


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

    Word progMem[4096];
    Mbyte dataMem[] = new[4096]('{default: 0});

    Emulator emul_N = new();


    class Runner1 extends TestRunner;
        task automatic runTest(input string name);
            runTestEmul(name, emul_N, DEFAULT_CALL_SECTION);
            #1;
        endtask
    endclass

    function automatic logic isValidTest(input squeue line);
        if (line.size() > 1) $error("There should be 1 test per line");
        return line.size() == 1;
    endfunction

    task automatic setPrograms(ref Word mem[4096], input Section testSec, input Section resetSec, input Section errorSec, input Section callSec, input Section intSec, input Section excSec);
        mem = '{default: 'x};
        writeProgram(mem, COMMON_ADR, common.words);          
        writeProgram(mem, 0, testSec.words);
        writeProgram(mem, IP_RESET, resetSec.words);
        writeProgram(mem, IP_ERROR, errorSec.words);
        writeProgram(mem, IP_CALL, callSec.words);
        writeProgram(mem, IP_INT, intSec.words);
        writeProgram(mem, IP_EXC, excSec.words);
    endtask



    task automatic prepareTest(ref Word mem[4096], input string name, input Section callSec, input Section intSec, input Section excSec);
        Section testProg = fillImports(processLines(readFile({name, ".txt"})), 0, common, COMMON_ADR);
        setPrograms(mem, testProg, DEFAULT_RESET_SECTION, DEFAULT_ERROR_SECTION, callSec, intSec, excSec);
    endtask

    initial common = processLines(readFile({"common_asm", ".txt"}));

    initial runEmul();


    
    task automatic runEmul();
        Runner1 runner1 = new();
        #1 runner1.runSuites(allSuites);
        #1 runErrorTestEmul(emul_N);
        #1 runTestEmul("events", emul_N, TESTED_CALL_SECTION);
        #1 runIntTestEmul(emul_N);
        #1;      
    endtask


    // Emul-only run
    task automatic runTestEmul(input string name, ref Emulator emul, input Section callSec);
        emulTestName = name;
        prepareTest(progMem, name, callSec, FAILING_SECTION, DEFAULT_EXC_SECTION);
        
            saveProgramToFile({"ZZZ_", name, ".txt"}, progMem);

        resetAll(emul);
        performEmul(emul, dataMem);
    endtask


    task automatic runErrorTestEmul(ref Emulator emul);
        emulTestName = "err signal";
        writeProgram(progMem, 0, FAILING_SECTION.words);
        
        resetAll(emul);

        for (int iter = 0; 1; iter++) begin
            emul.executeStep(progMem);
            
            if (emul.status.error == 1) break;
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", "error sig");

            if (emul.writeToDo.active) writeArrayW(dataMem, emul.writeToDo.adr, emul.writeToDo.value);            
            emul.drain();
            #1;
        end
    endtask

    task automatic runIntTestEmul(ref Emulator emul);
        emulTestName = "int";
        prepareTest(progMem, "events2", TESTED_CALL_SECTION, DEFAULT_INT_SECTION, DEFAULT_EXC_SECTION);

        resetAll(emul);

        for (int iter = 0; 1; iter++) begin
            if (iter == 3) begin 
                emul.interrupt();
                #1;
            end

            emul.executeStep(progMem);
            
            if (emul.status.error == 1) $fatal(2, ">>>> Emulation in error state\n");
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", "events2");
            if (emul.status.send == 1) break;

            if (emul.writeToDo.active) writeArrayW(dataMem, emul.writeToDo.adr, emul.writeToDo.value);
            emul.drain();
            #1;
        end
    endtask


    task automatic performEmul(ref Emulator emul, ref DynamicDataMem dmem);
        for (int iter = 0; 1; iter++) begin
            emul.executeStep(progMem);
            
            if (emul.status.error == 1) $fatal(2, ">>>> Emulation in error state\n");
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", emulTestName);
            if (emul.status.send == 1) break;
            if (emul.writeToDo.active) writeArrayW(dmem, emul.writeToDo.adr, emul.writeToDo.value);
            emul.drain();
            #1;
        end
    endtask

    task automatic resetAll(ref Emulator emul);
        dataMem = '{default: 0};
        emul.reset();
        #1;
    endtask

    //////////////////////////////////////////////////////
    ////////////////////////////////////////////////

    // Core sim
    generate
        class SimRunner extends TestRunner;
            task automatic runTest(input string name);
                runTestSim(name, DEFAULT_CALL_SECTION);
            endtask
        endclass
    
        Word programMem[4096];

        logic reset = 0, int0 = 0, done, wrong;

        Mword fetchAdr;       
        logic writeEn;
        Mword writeAdr, writeValue;

        
        task automatic runSim();
            SimRunner runner = new();
        
            #CYCLE runner.runSuites(allSuites);  
            
                core.insMap.assertReissue();
            
            runTestSim("events", TESTED_CALL_SECTION);
            runIntTestSim();
            
            $display("All tests done;");
                // Now assure that a pullback and reissue has happened because of mem replay 
            $stop(2);
        endtask
        
        
        task automatic runTestSim(input string name, input Section callSec);
            #CYCLE announce(name);
            prepareTest(programMem, name, callSec, FAILING_SECTION, DEFAULT_EXC_SECTION);
            
            startSim();
            awaitResult();
        endtask

        task automatic runIntTestSim();
            #CYCLE announce("int");
            prepareTest(programMem, "events2", TESTED_CALL_SECTION, DEFAULT_INT_SECTION, DEFAULT_EXC_SECTION);
            
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
            core.dbProgMem = programMem; // NOTE: duplication - remove?
            core.instructionCache.setProgram(programMem);
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
        assign writeEn = core.writeInfo.req;
        assign writeAdr = core.writeInfo.adr;
        assign writeValue = core.writeInfo.value;
        
        
        AbstractCore core(
            .clk(clk),
            
            .interrupt(int0),
            .reset(reset),
            .sig(done),
            .wrong(wrong)
        );

    endgenerate


    
    task automatic saveProgramToFile(input string fname, input Word progMem[4096]);
        int file = $fopen(fname, "w");
        squeue lines = disasmBlock(progMem);
        foreach (lines[i])
            $fdisplay(file, lines[i]);
        $fclose(file);
    endtask

    localparam int DISASM_LIMIT = 64;

    function automatic squeue disasmBlock(input Word words[]);
        squeue res;
        string s;
        foreach (words[i]) begin
            $swrite(s, "%h: %h  %s", 4*i , words[i], disasm(words[i]));
            res.push_back(s);
            
            if (i == DISASM_LIMIT) break;
        end
        return res;
    endfunction


endmodule
