`timescale 1ns / 1fs

import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import AbstractSim::*;
    
module ArchDesc0();

    localparam CYCLE = 10;

    logic clk = 1;

    always #(CYCLE/2) clk = ~clk; 


    const int ITERATION_LIMIT = 2000;
    const Word COMMON_ADR = 1024;
    const string DEFAULT_RESET_HANDLER[$] = {"ja -512",   "ja 0", "undef"};
    const string DEFAULT_ERROR_HANDLER[$] = {"sys error", "ja 0", "undef"};

    const string DEFAULT_CALL_HANDLER[$]  = {"sys send", "ja 0", "undef"};
    const string CALL_HANDLER[$] = {"add_i r20, r0, 55", "sys rete", "ja 0"};

    const string INT_HANDLER[$]  = {"add_i r21, r0, 77", "sys reti", "ja 0"};
    const string FAILING_INT_HANDLER[$]  = {"undef", "ja 0", "undef"};

    Section common;
    squeue tests;
    string emulTestName, simTestName;

    initial tests = readFile("tests_all.txt");
    initial common = processLines(readFile({"common_asm", ".txt"}));

    function automatic logic isValidTest(input squeue line);
        if (line.size() > 1) $error("There should be 1 test per line");
        return line.size() == 1;
    endfunction

    task automatic setPrograms(ref Word mem[4096], input Section testSec, input Section callSec, input Section intSec);
        mem = '{default: 'x};
        writeProgram(mem, COMMON_ADR, common.words);          
        writeProgram(mem, 0, testSec.words);
        writeProgram(mem, IP_RESET, processLines(DEFAULT_RESET_HANDLER).words);
        writeProgram(mem, IP_ERROR, processLines(DEFAULT_ERROR_HANDLER).words);
        writeProgram(mem, IP_CALL, callSec.words);
        writeProgram(mem, IP_INT, intSec.words);
    endtask

    Emulator emulSig;
    Word progMem[4096];
    logic[7:0] dataMem[] = new[4096]('{default: 0});

    typedef logic[7:0] DynamicDataMem[];

    task automatic prepareTest(ref Word mem[4096], input string name, input Section callSec, input Section intSec);
        Section testProg = fillImports(processLines(readFile({name, ".txt"})), 0, common/*commonSim*/, COMMON_ADR);
        setPrograms(mem, testProg, callSec, intSec);
    endtask


    initial runEmul();

    task automatic runEmul();
        Emulator emul = new();
        
        emul.reset();
        emulSig = emul;
        //#1;

        foreach (tests[i]) begin
            squeue lineParts = breakLine(tests[i]);
            if (!isValidTest(lineParts)) continue;
            emulTestName = lineParts[0];
            #1 runTestEmul(lineParts[0], emul, processLines(DEFAULT_CALL_HANDLER), processLines(FAILING_INT_HANDLER));
            //#1;
        end
        #1;

        emulTestName = "err signal";
        runErrorTestEmul(emul);
        #1;
        
        emulTestName = "events";
        runTestEmul("events", emul, processLines(CALL_HANDLER), processLines(FAILING_INT_HANDLER));
        #1;
        
        emulTestName = "int";
        runIntTestEmul(emul);
        #1;
                
    endtask


    task automatic performEmul(ref Emulator emul, ref DynamicDataMem dmem);
        for (int iter = 0; 1; iter++)
        begin
            emul.executeStep(progMem);
            
            if (emul.status.error == 1) $fatal(2, ">>>> Emulation in error state\n");
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", emulTestName);
            if (emul.status.send == 1) break;
            
            if (emul.writeToDo.active) writeArrayW(dmem, emul.writeToDo.adr, emul.writeToDo.value);
            emul.drain();

            emulSig = emul;
            #1;
        end
        
         //   $display("emul done %s, %d", emulTestName, emul.ip);
    endtask


    task automatic runErrorTestEmul(ref Emulator emul);
        writeProgram(progMem, 0, processLines({"undef", "ja 0"}).words);
        dataMem = '{default: 0};
        emul.reset();
        #1;
        
        for (int iter = 0; 1; iter++)
        begin
            emul.executeStep(progMem);
            
            if (emul.status.error == 1) break;
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", "error sig");
   
            if (emul.writeToDo.active) writeArrayW(dataMem, emul.writeToDo.adr, emul.writeToDo.value);            
            emul.drain();

            emulSig = emul;
            #1;
        end
        
    endtask


    // Emul-only run
    task automatic runTestEmul(input string name, ref Emulator emul, input Section callSec, input Section intSec);
        prepareTest(progMem, name, callSec, intSec);

        dataMem = '{default: 0};
        emul.reset();
        #1;
        
        performEmul(emul, dataMem);
    endtask

    task automatic runIntTestEmul(ref Emulator emul);
        prepareTest(progMem, "events2", processLines(CALL_HANDLER), processLines(INT_HANDLER));

        dataMem = '{default: 0};
        emul.reset();
        #1;
        
        for (int iter = 0; 1; iter++)
        begin
            if (iter == 3) begin 
                emul.interrupt;
                #1;
            end

            emul.executeStep(progMem);
            
            if (emul.status.error == 1) $fatal(2, ">>>> Emulation in error state\n");
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", "events2");
            if (emul.status.send == 1) break;

            if (emul.writeToDo.active) writeArrayW(dataMem, emul.writeToDo.adr, emul.writeToDo.value);
            emul.drain();

            emulSig = emul;
            #1;
        end
        
    endtask



    // Core sim
    generate
        typedef ProgramMemory#(4) ProgMem;
        typedef DataMemory#(4) DataMem;

        ProgMem programMem;
        DataMem dmem;
        ProgMem::Line icacheOut;
        
        Word fetchAdr;

        logic reset = 0, int0 = 0, done, wrong;
        
        logic readEns[4], writeEn;
        Word writeAdr, readAdrs[4], readValues[4], writeValue;
        
        
        task automatic runSim();
            #CYCLE;
            foreach (tests[i]) begin
                squeue lineParts = breakLine(tests[i]);
                if (!isValidTest(lineParts)) continue;
                runTestSim(lineParts[0], processLines(DEFAULT_CALL_HANDLER), processLines(FAILING_INT_HANDLER));
            end
            runTestSim("events", processLines(CALL_HANDLER), processLines(FAILING_INT_HANDLER));
            runIntTestSim();
            
            $display("All tests done;");
            $stop(1);
        endtask
        
        
        task announce(input string name);
            simTestName = name;
            $display("> RUN: %s", name);
        endtask


        task automatic runTestSim(input string name, input Section callSec, input Section intSec);
            #CYCLE announce(name);
            prepareTest(programMem.content, name, callSec, intSec);
            TMP_setP(programMem.content);
            #CYCLE pulseReset();

            wait (done | wrong);
            if (wrong) $fatal(2, "TEST FAILED: %s", name);
            #CYCLE;
        endtask

        task automatic runIntTestSim();
            #CYCLE announce("int");
            prepareTest(programMem.content, "events2", processLines(CALL_HANDLER), processLines(INT_HANDLER));
            TMP_setP(programMem.content);
            #CYCLE pulseReset();
            
            wait (fetchAdr == IP_CALL);
            #CYCLE; // TODO: should be wait for clock instead of delay?
            pulseInt0();

            wait (done | wrong);
            if (wrong) $fatal(2, "TEST FAILED: %s", "int");
            #CYCLE;
        endtask

        task pulseReset();
            reset <= 1;
            #CYCLE;
            reset <= 0;
            #CYCLE;
        endtask

        task pulseInt0();
            int0 <= 1;
            #CYCLE;
            int0 <= 0;
            #CYCLE;
        endtask

        initial begin
            programMem = new();
            dmem = new();
            dmem.clear();
        end
        
        
        initial runSim();

        
        always_ff @(posedge clk) icacheOut <= programMem.read(fetchAdr);
        
        always @(posedge clk) begin
            if (readEns[0]) readValues[0] <= dmem.read(readAdrs[0]);
            if (writeEn) dmem.write(writeAdr, writeValue);
            if (reset) dmem.clear();
        end
                
        AbstractCore core(
            .clk(clk),
            .insReq(), .insAdr(fetchAdr), .insIn(icacheOut),
            .readReq(readEns), .readAdr(readAdrs), .readIn(readValues),
            .writeReq(writeEn), .writeAdr(writeAdr), .writeOut(writeValue),
            
            .interrupt(int0),
            .reset(reset),
            .sig(done),
            .wrong(wrong)
        );

    endgenerate  

endmodule
