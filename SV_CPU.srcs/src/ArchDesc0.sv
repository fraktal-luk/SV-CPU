`timescale 1ns / 1fs

import Base::*;
import InsDefs::*;
import Asm::*;
import EmulationDefs::*;
import Emulation::*;
import AbstractSim::*;
import Insmap::*;

import Testing::*;


module ArchDesc0();
    EmulTest emulTest();

    localparam int ITERATION_LIMIT = 2000;
    localparam Mword COMMON_ADR = 4 * 1024;

    const string DEFAULT_RESET_HANDLER[$] = {/*"ja -512", /**/"ja -8704",/**/  "ja 0", "sys_error"};
    const string DEFAULT_ERROR_HANDLER[$] = {"sys_error", "ja 0", "sys_error"};

    const string DEFAULT_CALL_HANDLER[$]  = {"sys_send", "ja 0", "sys_error"};
    const string TESTED_CALL_HANDLER[$] = {"add_i r20, r0, 55", "sys_rete", "ja 0"};

    const string DEFAULT_INT_HANDLER[$]  = {"add_i r21, r0, 77", "sys_reti", "ja 0"};

    const string FAILING_HANDLER[$]  = {"sys_error", "ja 0", "sys_error"};

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

    Emulator emul_N = new();

    Mword commonAdr = COMMON_ADR;


    class Runner1 extends TestRunner;
        task automatic runTest(input string name);
            runTestEmul(name, emul_N);
            #1;
        endtask
    endclass



    function automatic void prepareTest(ref Word mem[], input string name, input Mword commonAdr);
        Section testProg = fillImports(processLines(readFile({codeDir, name, ".txt"})), 0, common, commonAdr);
            mem = '{default: 'x};
        writeProgram(mem, 0, testProg.words);
    endfunction

    function automatic void prepareHandlers(ref Word mem[], input Section callSec, input Section intSec, input Section excSec);
        Section testProg;
        setBasicPrograms(mem, testProg, DEFAULT_RESET_SECTION, DEFAULT_ERROR_SECTION, callSec, intSec, excSec);
    endfunction

    
    function automatic void map3pages(ref Emulator em);
        em.programMappings.push_back('{1, 0, '{1, 1, 1, 1, 1}, 0});
        em.programMappings.push_back('{1, PAGE_SIZE, '{1, 1, 1, 1, 1}, PAGE_SIZE});
        em.programMappings.push_back('{1, 2*PAGE_SIZE, '{1, 1, 1, 1, 1}, 2*PAGE_SIZE});
    endfunction

    function automatic void mapDataPages(ref Emulator em);
        em.dataMappings.push_back('{1, 0, '{1, 1, 1, 1, 1}, 0});        
        em.dataMappings.push_back('{1, 'h80000000, '{1, 1, 1, 0, 0}, 'h80000000});        
        em.dataMappings.push_back('{1, 'h20000000, '{1, 1, 1, 1, 1}, 'h20000000});        
        em.dataMappings.push_back('{1, 'h2000, '{1, 1, 1, 1, 1}, 'h2000});             
    endfunction


    // Emul-only run
    task automatic runTestEmul(input string name, ref Emulator emul);
        Word emul_progMem[] = new[4096 / 4];

        emulTestName = name;
        prepareTest(emul_progMem, name, COMMON_ADR);
        
        
        emul.progMem.assignPage(0, emul_progMem);
    
        saveProgramToFile({"../../../../sim_files/ZZZ_", name, ".txt"}, emul_progMem);

        resetAll(emul);
        map3pages(emul);
        mapDataPages(emul);
        
        performEmul(emul);
    endtask


    task automatic runErrorTestEmul(ref Emulator emul);
        time DELAY = 1;
        Word emul_progMem[] = new[4096 / 4];

        emulTestName = "err signal";
        writeProgram(emul_progMem, 0, FAILING_SECTION.words);
        emul.progMem.assignPage(0, emul_progMem);

        resetAll(emul);
        
        map3pages(emul);
        mapDataPages(emul);

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
        Word emul_progMem[] = new[4096 / 4];

        emulTestName = "int";
        prepareTest(emul_progMem, "events2", COMMON_ADR);
        emul.progMem.assignPage(0, emul_progMem);

        resetAll(emul);

        map3pages(emul);
        mapDataPages(emul);

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
            if (emul.status.error == 1) $fatal(2, ">>>> Emulation in error state\n%p", emul);
            if (iter >= ITERATION_LIMIT) $fatal(2, "Exceeded max iterations in test %s", emulTestName);
            if (emul.status.send == 1) break;
            emul.drain();
            #DELAY;
        end
    endtask

    task automatic resetAll(ref Emulator emul);
        time DELAY = 1;
        emul.resetWithDataMem();
            emul.programMappings.delete();
            emul.dataMappings.delete();
        #DELAY;
    endtask


    task automatic runEmul();
        Runner1 runner1 = new();
            Word emul_progMem2[] = new[4096 / 4];
            
            emul_N.progMem.assignPage(PAGE_SIZE, common.words);
            prepareHandlers(emul_progMem2, DEFAULT_CALL_SECTION, FAILING_SECTION, DEFAULT_EXC_SECTION);
            emul_N.progMem.assignPage(2*PAGE_SIZE, emul_progMem2);

        runner1.announceSuites = 0;
        #1 runner1.runSuites(allSuites);
        
            prepareHandlers(emul_progMem2, TESTED_CALL_SECTION, FAILING_SECTION, DEFAULT_EXC_SECTION);
            emul_N.progMem.assignPage(2*PAGE_SIZE, emul_progMem2);       
        #1 runErrorTestEmul(emul_N);
        
            prepareHandlers(emul_progMem2, TESTED_CALL_SECTION, FAILING_SECTION, DEFAULT_EXC_SECTION);
            emul_N.progMem.assignPage(2*PAGE_SIZE, emul_progMem2);
        #1 runTestEmul("events", emul_N);
        
            prepareHandlers(emul_progMem2, TESTED_CALL_SECTION, DEFAULT_INT_SECTION, DEFAULT_EXC_SECTION);
            emul_N.progMem.assignPage(2*PAGE_SIZE, emul_progMem2);
        #1 runIntTestEmul(emul_N);
        #1;      
    endtask

    initial common = processLines(readFile({codeDir, "common_asm", ".txt"}));

    initial runEmul();

    //////////////////////////////////////////////////////
    ////////////////////////////////////////////////

    // Core sim
    generate

        class UncachedSimRunner extends TestRunner;
            task automatic runTest(input string name);
                runTestSimUncached(name); // TODO: runTestSimUncached
            endtask
        endclass

        class SimRunner extends TestRunner;
            task automatic runTest(input string name);
                runTestSim(name);
            endtask
        endclass

        logic reset = 0, int0 = 0, done, wrong;
        PageBasedProgramMemory theProgMem = new();
        Mword fetchAdr;       


            task automatic runTestSimUncached(input string name);
                    Word emul_progMem[] = new[4096 / 4]; // TODO: refactor to set page 0 with test program in 1 line, without additional vars
    
                #CYCLE announce(name);
                prepareTest(emul_progMem, name, COMMON_ADR);
                theProgMem.assignPage(0, emul_progMem);
    
                core.resetForTest();
                core.programMem = theProgMem;
                
                // TODO: don;t map, turn of mapping and caches
                begin
                    //core.instructionCache.prepareForUncachedTest();
                    core.theFrontend.instructionCache.prepareForUncachedTest();
                end
                
                startSim();
                
                awaitResult();
            endtask



        task automatic runTestSim(input string name);
                Word emul_progMem[] = new[4096 / 4]; // TODO: refactor to set page 0 with test program in 1 line, without additional vars

            #CYCLE announce(name);
            prepareTest(emul_progMem, name, commonAdr); // CAREFUL: commonAdr is variable here 
            theProgMem.assignPage(0, emul_progMem);
            theProgMem.assignPage(8*PAGE_SIZE, emul_progMem); // TODO: remove when mapping multiple v pages to one physical is possible without tricks (checking in Frontend fetch translation!)

            core.resetForTest();
            core.programMem = theProgMem;
            
                mapDataPages(core.renamedEmul);
                mapDataPages(core.retiredEmul);

            //core.instructionCache.prefetchForTest();
            core.theFrontend.instructionCache.prefetchForTest();
            core.dataCache.prefetchForTest();
            startSim();
            
            awaitResult();
        endtask

        task automatic runIntTestSim();
                Word emul_progMem[] = new[4096 / 4];

            #CYCLE announce("int");
            prepareTest(emul_progMem, "events2", COMMON_ADR);
            theProgMem.assignPage(0, emul_progMem);
 
            core.resetForTest();
            core.programMem = theProgMem;
            
            //core.instructionCache.prefetchForTest();
            core.theFrontend.instructionCache.prefetchForTest();
            core.dataCache.prefetchForTest();
            startSim();

            // The part that differs from regular sim test
            wait (fetchAdr == IP_CALL);
            #CYCLE; // FUTURE: should be wait for clock instead of delay?
            pulseInt0();

            awaitResult();
        endtask


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

        
        AbstractCore core(
            .clk(clk),
            
            .interrupt(int0),
            .reset(reset),
            .sig(done),
            .wrong(wrong)
        );


        task automatic runSim();
            UncachedSimRunner uncachedRunner = new();
            SimRunner cachedRunner = new();
              Word emul_progMem2[] = new[4096 / 4];
                    theProgMem.assignPage(PAGE_SIZE, common.words);
                        theProgMem.assignPage(3*PAGE_SIZE, common.words); // TODO: replace with specific test code?
                        theProgMem.assignPage(4*PAGE_SIZE, common.words); // TODO: this temporary hack is to get correct fetch bits from virtual page at 4*PAGE_SIZE mapped to physical 1*PAGE_SIZE
                
                prepareHandlers(emul_progMem2, DEFAULT_CALL_SECTION, FAILING_SECTION, DEFAULT_EXC_SECTION);
                theProgMem.assignPage(2*PAGE_SIZE, emul_progMem2);

                core.GlobalParams.uncachedFetch = 1;

            #CYCLE;// $display("Suites: uncached");
            $display("* Uncached suites");
            uncachedRunner.runSuites(uncachedSuites);
            
                
                // CAREFUL: mode switch must happen when frontend is flushed to avoid incorrect state. Hence reset signal is used                   
                startSim();
                core.GlobalParams.uncachedFetch = 0;
                
                
                commonAdr = COMMON_ADR + 3*PAGE_SIZE;

            #CYCLE;// $display("Suites: all");
            $display("* Cached fetch suites");
            cachedRunner.runSuites(cachedFetchSuites); 
   
   
                commonAdr = COMMON_ADR;
   
            #CYCLE;// $display("Suites: all"); 
            $display("* Normal suites"); 
            cachedRunner.runSuites(allSuites);  
            
                // Now assure that a pullback and reissue has happened because of mem replay
                core.insMap.assertReissue();
            
            //#CYCLE
            $display("* Event tests");
            
                prepareHandlers(emul_progMem2, TESTED_CALL_SECTION, FAILING_SECTION, DEFAULT_EXC_SECTION);
                theProgMem.assignPage(2*PAGE_SIZE, emul_progMem2);
            runTestSim("events");
            
                prepareHandlers(emul_progMem2, TESTED_CALL_SECTION, DEFAULT_INT_SECTION, DEFAULT_EXC_SECTION);
                theProgMem.assignPage(2*PAGE_SIZE, emul_progMem2);
            runIntTestSim();
            
            $display("All tests done;");
            $stop(2);
        endtask


        assign fetchAdr = core.insAdr; 

        initial runSim();

    endgenerate


endmodule
