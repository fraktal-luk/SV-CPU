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
    const string DEFAULT_RESET_HANDLER[$] = {"ja -512", "ja 0"};
    const string DEFAULT_ERROR_HANDLER[$] = {"sys error", "ja 0"};
    const string DEFAULT_CALL_HANDLER[$] =  {"sys send", "ja 0"};

    const string CALL_HANDLER[$] = {"add_i r20, r0, 55",
                                    "sys rete",
                                    "ja 0"
                                   };
    const string INT_HANDLER[$] = {"add_i r21, r0, 77",
                                   "sys reti",
                                   "ja 0"
                                  };

    Section common;
    squeue tests;
    string emulTestName, simTestName;

    initial tests = readFile("tests_all.txt");
    initial common = processLines(readFile({"common_asm", ".txt"}));


    Emulator emulSig;
    Word progMem[4096];
    logic[7:0] dataMem[] = new[4096]('{default: 0});



    initial runEmul();


    task automatic runEmul();
        Emulator emul = new();
        //squeue tests = readFile("tests_all.txt");
        
        emul.reset();
        emulSig = emul;
        #1;

        foreach (tests[i]) begin
            squeue lineParts = breakLine(tests[i]);

            if (lineParts.size() > 1) $error("There should be 1 test per line");
            else if (lineParts.size() == 0);
            else begin            
                emulTestName = lineParts[0];
                runTestEmul({lineParts[0], ".txt"}, emul);
            end
            #1;
        end

        emulTestName = "err signal";
        runErrorTestEmul(emul);
        #1;
        
        emulTestName = "event";
        runEventTestEmul(emul);
        #1;
        
        emulTestName = "event2";
        runIntTestEmul(emul);
        #1;
                
    endtask


    task automatic setBasicHandlers(ref Word progMem[4096]);
        writeProgram(progMem, IP_RESET, processLines(DEFAULT_RESET_HANDLER).words);
        writeProgram(progMem, IP_ERROR, processLines(DEFAULT_ERROR_HANDLER).words);
        writeProgram(progMem, IP_CALL,  processLines(DEFAULT_CALL_HANDLER).words);
    endtask


    // Emul-only run
    task automatic runTestEmul(input string name, ref Emulator emul);
        int iter;
        squeue fileLines = readFile(name);
        Section testSection = processLines(fileLines);
        testSection = fillImports(testSection, 0, common, COMMON_ADR);

        dataMem = '{default: 0};
        progMem = '{default: 'x};
        
        writeProgram(progMem, 0, testSection.words);
        writeProgram(progMem, COMMON_ADR, common.words);
        setBasicHandlers(progMem);
        
        emul.reset();
        #1;
        
        for (iter = 0; iter < ITERATION_LIMIT; iter++)
        begin
            emul.executeStep(progMem);
            
            if (emul.status.error == 1) $fatal(">>>> Emulation in error state\n");
            if (emul.status.send == 1) break;
            
            if (emul.writeToDo.active) writeArrayW(dataMem, emul.writeToDo.adr, emul.writeToDo.value);
            emul.drain();

            emulSig = emul;
            #1;
        end
        
        if (iter >= ITERATION_LIMIT) $fatal("Exceeded max iterations in test %s", name);
    endtask


    task automatic runErrorTestEmul(ref Emulator emul);
        int iter;

        dataMem = '{default: 0};
        progMem = '{default: 'x};

        progMem[0] = processLines({"undef"}).words[0];
        progMem[1] = processLines({"ja 0"}).words[0];
        
        writeProgram(progMem, COMMON_ADR, common.words);
        setBasicHandlers(progMem);
        
        emul.reset();
        #1;
        
        for (iter = 0; iter < ITERATION_LIMIT; iter++)
        begin
            emul.executeStep(progMem);
            
            if (emul.status.error == 1) break;
            
            if (emul.writeToDo.active) writeArrayW(dataMem, emul.writeToDo.adr, emul.writeToDo.value);            
            emul.drain();

            emulSig = emul;
            #1;
        end
        
        if (iter >= ITERATION_LIMIT) $fatal("Exceeded max iterations in test %s", "error sig");
    endtask


    task automatic runEventTestEmul(ref Emulator emul);
        int iter;
        squeue fileLines = readFile("events.txt");
        Section testSection = processLines(fileLines);
        testSection = fillImports(testSection, 0, common, COMMON_ADR);

        dataMem = '{default: 0};
        progMem = '{default: 'x};
        
        writeProgram(progMem, 0, testSection.words);
        writeProgram(progMem, COMMON_ADR, common.words);
        setBasicHandlers(progMem);

        //writeProgram(progMem, IP_CALL, '{0, 0, 0, 0});
        writeProgram(progMem, IP_CALL, processLines(CALL_HANDLER).words);

        emul.reset();
        #1;
        
        for (iter = 0; iter < ITERATION_LIMIT; iter++)
        begin
            emul.executeStep(progMem);
            
            if (emul.status.error == 1) $fatal(">>>> Emulation in error state\n");            
            if (emul.status.send == 1) break;
            
            if (emul.writeToDo.active) writeArrayW(dataMem, emul.writeToDo.adr, emul.writeToDo.value);
            emul.drain();
                
            emulSig = emul;
            #1;
        end
        
        if (iter >= ITERATION_LIMIT) $fatal("Exceeded max iterations in test %s", "event");
    endtask


    task automatic runIntTestEmul(ref Emulator emul);
        int iter;

        squeue fileLines = readFile("events2.txt");
        Section testSection = processLines(fileLines);
        testSection = fillImports(testSection, 0, common, COMMON_ADR);

        dataMem = '{default: 0};
        progMem = '{default: 'x};
        
        writeProgram(progMem, 0, testSection.words);
        writeProgram(progMem, COMMON_ADR, common.words);
        setBasicHandlers(progMem);
        
        writeProgram(progMem, IP_CALL, processLines(CALL_HANDLER).words);
        writeProgram(progMem, IP_INT, processLines(INT_HANDLER).words);

        emul.reset();
        #1;
        
        for (iter = 0; iter < ITERATION_LIMIT; iter++)
        begin
            if (iter == 3) begin 
                emul.interrupt;
                #1;
            end

            emul.executeStep(progMem);
            
            if (emul.status.error == 1) $fatal(">>>> Emulation in error state\n");
            if (emul.status.send == 1) break;
            
            if (emul.writeToDo.active) writeArrayW(dataMem, emul.writeToDo.adr, emul.writeToDo.value);
            emul.drain();

            emulSig = emul;
            #1;
        end
        
        if (iter >= ITERATION_LIMIT) $fatal("Exceeded max iterations in test %s", "event2");
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
            //squeue tests = readFile("tests_all.txt");
            #CYCLE;
            
            foreach (tests[i]) begin
                squeue lineParts = breakLine(tests[i]);

                if (lineParts.size() > 1) $error("There should be 1 test per line");
                else if (lineParts.size() == 0) continue;
                
                //    TMP_setTest(lineParts[0]);
                runTestSim(lineParts[0]);
            end
                
               // TMP_prepareErrorTest();
            runErrorTestSim();
               // TMP_prepareEventTest();
            runEventTestSim();
                //TMP_prepareIntTest();
            runIntTestSim();
            
            $display("All tests done;");
            $stop(1);
        endtask
        
        
        task announce(input string name);
            simTestName = name;
            $display("> RUN: %s", name);
        endtask


        task automatic setPrograms(input Section testSec);
            programMem.clear();
            programMem.setContentAt(common/*commonSim*/.words, COMMON_ADR);            
            programMem.setContent(testSec.words);
            programMem.setBasicHandlers();
        endtask

        task automatic runTestSim(input string name);
            Section testProg = fillImports(processLines(readFile({name, ".txt"})), 0, common/*commonSim*/, COMMON_ADR);
                TMP_setTest(name);
                   // cmpMems(programMem.content, TMP_getP());

            #CYCLE announce(name);
            setPrograms(testProg);
                    //        programMem.content[900] = 27;
                   // cmpMems(programMem.content, TMP_getP());
                TMP_setP(programMem.content);
            
            #CYCLE pulseReset();

            wait (done | wrong);
            if (wrong) $fatal("TEST FAILED: %s", name);
            #CYCLE;
        endtask



        task automatic runErrorTestSim();
            Section testProg = processLines({"undef",
                                             "ja 0"});
                TMP_prepareErrorTest();

            #CYCLE announce("err");
            setPrograms(testProg);
            
                        //        cmpMems(programMem.content, TMP_getP());
                TMP_setP(programMem.content);

            #CYCLE pulseReset();

            wait (wrong);
            #CYCLE;
        endtask

        task automatic runEventTestSim();
            Section testProg = fillImports(processLines(readFile({"events", ".txt"})), 0, common/*commonSim*/, COMMON_ADR);
                TMP_prepareEventTest();

            #CYCLE announce("event");
            setPrograms(testProg);
            programMem.setContentAt(processLines(CALL_HANDLER).words, IP_CALL);
            
                           //     cmpMems(programMem.content, TMP_getP());
                TMP_setP(programMem.content);

            #CYCLE pulseReset();

            wait (done | wrong);
            if (wrong) $fatal("TEST FAILED: %s", "events");      
            #CYCLE;
        endtask

        task automatic runIntTestSim();
            Section testProg = fillImports(processLines(readFile({"events2", ".txt"})), 0, common/*commonSim*/, COMMON_ADR);
                TMP_prepareIntTest();

            #CYCLE announce("int");
            setPrograms(testProg);
            programMem.setContentAt(processLines(CALL_HANDLER).words, IP_CALL);
            programMem.setContentAt(processLines(INT_HANDLER).words, IP_INT);
            
                             //   cmpMems(programMem.content, TMP_getP());
                TMP_setP(programMem.content);

            #CYCLE pulseReset();
            
            wait (fetchAdr == IP_CALL);
            #CYCLE;
            
            pulseInt0();

            wait (done | wrong);
            if (wrong) $fatal("TEST FAILED: %s", "int");
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
