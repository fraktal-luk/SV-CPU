`timescale 1ns / 1fs

import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import AbstractSim::*;
import Insmap::*;

module ArchDesc0();

            class ProgramMemory #(parameter WIDTH = 4);
                typedef Word Line[WIDTH];
                
                Word content[4096];
                
                function void clear();
                    this.content = '{default: 'x};
                endfunction
                
                function Line read(input Word adr);
                    Line res;
                    Word truncatedAdr = adr & ~(4*WIDTH-1);
                    
                    foreach (res[i]) res[i] = content[truncatedAdr/4 + i];
                    return res;
                endfunction
        
            endclass
            
            
            class DataMemory;        
                Mbyte content[4096];
                
                function void setContent(Word arr[]);
                    foreach (arr[i]) content[i] = arr[i];
                endfunction
                
                function void clear();
                    content = '{default: '0};
                endfunction;
                
                function automatic Word read(input Word adr);
                    Word res = 0;
                    for (int i = 0; i < 4; i++) res = (res << 8) + content[adr + i];
                    return res;
                endfunction
        
                function automatic void write(input Word adr, input Word value);
                    Word data = value;            
                    for (int i = 0; i < 4; i++) begin
                        content[adr + i] = data[31:24];
                        data <<= 8;
                    end        
                endfunction    
                
            endclass
    ////////////////////////////////////////////////////////////////


    localparam int ITERATION_LIMIT = 2000;
    localparam Word COMMON_ADR = 1024;

    const string DEFAULT_RESET_HANDLER[$] = {"ja -512",   "ja 0", "undef"};
    const string DEFAULT_ERROR_HANDLER[$] = {"sys_error", "ja 0", "undef"};

    const string DEFAULT_CALL_HANDLER[$]  = {"sys_send", "ja 0", "undef"};
    const string CALL_HANDLER[$] = {"add_i r20, r0, 55", "sys_rete", "ja 0"};

    const string INT_HANDLER[$]  = {"add_i r21, r0, 77", "sys_reti", "ja 0"};
    const string FAILING_INT_HANDLER[$]  = {"undef", "ja 0", "undef"};

    const string EXC_HANDLER[$]  = {"add_i r1, r0, 37", "lds r20, r0, 2", "add_i r21, r20, 4", "sts r21, r0, 2", "sys_rete", "ja 0"};


    typedef Mbyte DynamicDataMem[];



    localparam CYCLE = 10;

    logic clk = 1;

    always #(CYCLE/2) clk = ~clk; 


    Section common;
    squeue tests;
    string emulTestName, simTestName;

    Emulator emulSig;
    Word progMem[4096];
    Mbyte dataMem[] = new[4096]('{default: 0});


    function automatic logic isValidTest(input squeue line);
        if (line.size() > 1) $error("There should be 1 test per line");
        return line.size() == 1;
    endfunction

    task automatic setPrograms(ref Word mem[4096], input Section testSec, input Section callSec, input Section intSec, input Section excSec);
        mem = '{default: 'x};
        writeProgram(mem, COMMON_ADR, common.words);          
        writeProgram(mem, 0, testSec.words);
        writeProgram(mem, IP_RESET, processLines(DEFAULT_RESET_HANDLER).words);
        writeProgram(mem, IP_ERROR, processLines(DEFAULT_ERROR_HANDLER).words);
        writeProgram(mem, IP_CALL, callSec.words);
        writeProgram(mem, IP_INT, intSec.words);
        writeProgram(mem, IP_EXC, excSec.words);
    endtask


    task automatic prepareTest(ref Word mem[4096], input string name, input Section callSec, input Section intSec, input Section excSec);
        Section testProg = fillImports(processLines(readFile({name, ".txt"})), 0, common, COMMON_ADR);
        setPrograms(mem, testProg, callSec, intSec, excSec);
    endtask


    initial tests = readFile("tests_all.txt");
    initial common = processLines(readFile({"common_asm", ".txt"}));

    initial runEmul();


    task automatic runEmul();
        Emulator emul = new();
        emulSig = emul;
        #1;

        foreach (tests[i]) begin
            squeue lineParts = breakLine(tests[i]);
            if (!isValidTest(lineParts)) continue;
            runTestEmul(lineParts[0], emul, processLines(DEFAULT_CALL_HANDLER), processLines(FAILING_INT_HANDLER), processLines(EXC_HANDLER));
            #1;
        end

        runErrorTestEmul(emul);
        #1;
        runTestEmul("events", emul, processLines(CALL_HANDLER), processLines(FAILING_INT_HANDLER), processLines(EXC_HANDLER));
        #1;
        runIntTestEmul(emul);
        #1;      
    endtask


    // Emul-only run
    task automatic runTestEmul(input string name, ref Emulator emul, input Section callSec, input Section intSec, input Section excSec);
        emulTestName = name;
        prepareTest(progMem, name, callSec, intSec, excSec);
        
        resetAll(emul);
        
        performEmul(emul, dataMem);
    endtask
    
    task automatic runErrorTestEmul(ref Emulator emul);
        emulTestName = "err signal";

        writeProgram(progMem, 0, processLines({"undef", "ja 0"}).words);
        
        resetAll(emul);

        for (int iter = 0; 1; iter++) begin
            emul.executeStep(progMem);
            
            if (emul.status.error == 1) break;
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", "error sig");

            if (emul.writeToDo.active) writeArrayW(dataMem, emul.writeToDo.adr, emul.writeToDo.value);            
            emul.drain();

            emulSig = emul;
            #1;
        end
        emulSig = emul;
    endtask

    task automatic runIntTestEmul(ref Emulator emul);
        emulTestName = "int";
        prepareTest(progMem, "events2", processLines(CALL_HANDLER), processLines(INT_HANDLER), processLines(EXC_HANDLER));

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

            emulSig = emul;
            #1;
        end
        emulSig = emul;
    endtask


    task automatic performEmul(ref Emulator emul, ref DynamicDataMem dmem);
        for (int iter = 0; 1; iter++) begin
            emul.executeStep(progMem);
            
            if (emul.status.error == 1) $fatal(2, ">>>> Emulation in error state\n");
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", emulTestName);
            if (emul.status.send == 1) break;

            if (emul.writeToDo.active) writeArrayW(dmem, emul.writeToDo.adr, emul.writeToDo.value);
            emul.drain();

            emulSig = emul;
            #1;
        end
        emulSig = emul;
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
        Word programMem[4096];

        logic reset = 0, int0 = 0, done, wrong;

        Word fetchAdr;       
        logic writeEn;
        Word writeAdr, writeValue;
        
        task automatic runSim();
            #CYCLE;
            foreach (tests[i]) begin
                squeue lineParts = breakLine(tests[i]);
                if (!isValidTest(lineParts)) continue;
                runTestSim(lineParts[0], processLines(DEFAULT_CALL_HANDLER), processLines(FAILING_INT_HANDLER), processLines(EXC_HANDLER));
            end
            runTestSim("events", processLines(CALL_HANDLER), processLines(FAILING_INT_HANDLER), processLines(EXC_HANDLER));
            runIntTestSim();
            
            $display("All tests done;");
                // Now assure that a pullback and reissue has happened because of mem replay 
                core.insMap.assertReissue();
            $stop(2);
        endtask
        
        
        task automatic runTestSim(input string name, input Section callSec, input Section intSec, input Section excSec);
            #CYCLE announce(name);
            prepareTest(programMem, name, callSec, intSec, excSec);
            
            startSim();
            
            awaitResult();
        endtask

        task automatic runIntTestSim();
            #CYCLE announce("int");
            prepareTest(programMem, "events2", processLines(CALL_HANDLER), processLines(INT_HANDLER), processLines(EXC_HANDLER));
            
            startSim();

            // The part that differs from regular sim test
            wait (fetchAdr == IP_CALL);
            #CYCLE; // TODO: should be wait for clock instead of delay?
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
            
            #CYCLE;
            reset <= 1;
            #CYCLE;
            reset <= 0;
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

            .writeReq(writeEn), .writeAdr(writeAdr), .writeOut(writeValue),
            
            .interrupt(int0),
            .reset(reset),
            .sig(done),
            .wrong(wrong)
        );

    endgenerate
    
endmodule
