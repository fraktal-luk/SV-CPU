
package Testing;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import ControlRegisters::*;
    import EmulationDefs::*;
    import EmulationMemories::*;
    import Emulation::*;
    import AbstractSim::*;
    import Insmap::*;    



    localparam Dword PROG_P_MAIN = 0; // physical adr of test code
    localparam Dword PROG_P_MISS = 'h2000; // page not in instruction L1

    localparam Dword PROG_P_HANDLERS = 'h4000;
    localparam Dword PROG_P_LIB = 'h5000;


    localparam Dword DATA_P_MAIN = 0; // physical adr of input
    localparam Dword DATA_P_MISS = 'h2000; // page not in data L1

    localparam Dword DATA_P_OUTPUT = 'h4000; // for writing output data 

    localparam Dword DATA_P_UNCACHED = 'h0000000040000000;


    localparam Dword VIRTUAL_OFFSET_TLB_MISS = 'h100000;  // 1 MB

    localparam Dword PROG_V_OFFSET = 0; // Added to all physical adrs of program
    localparam Dword DATA_V_OFFSET = 0; // Likewise, for data



    localparam Dword PROG_P_NONEXISTENT = 'h2000000000000000;
    localparam Dword DATA_P_NONEXISTENT = 'h2000000000000000;


    localparam Dword PROG_V_INVALID = 'h8000000000000000;
    localparam Dword PROG_V_UNMAPPED = 'h8000;
    localparam Dword PROG_V_DISALLOWED = 'h9000;
    localparam Dword PROG_V_MAPPED_NONEXISTENT = 'ha000;

    localparam Dword DATA_V_INVALID = 'h8000000000000000;
    localparam Dword DATA_V_UNMAPPED = 'h8000;
    localparam Dword DATA_V_DISALLOWED = 'h9000;
    localparam Dword DATA_V_MAPPED_NONEXISTENT = 'ha000;



    // Section mapping
    //
    // "prog_main" -> PROG_P_MAIN
    // "prog_miss" -> PROG_P_MISS

    // "data0" -> DATA_P_MAIN
    // "data1" -> DATA_P_MAIN + 'h1000
    // "data_miss0" -> DATA_P_MISS;
    // "data_miss1" -> DATA_P_MISS + 'h1000;

    // "output" -> DATA_P_OUTPUT

    // "data_uncached" -> DATA_P_UNCACHED


    function automatic Dword sectionStart(input string name);
        case (name)
            "prog_main": return PROG_P_MAIN;
            "prog_miss": return PROG_P_MISS;

            "handlers": return PROG_P_HANDLERS;
            "lib":      return PROG_P_LIB;

            "data0":      return DATA_P_MAIN;
            "data1":       ;// return 'x;;
            "data_miss0": ;//return 'x;
            "data_miss1": ; //return 'x;

            "output": ; //return 'x; // Not loaded, leave default 0's and wait for tested program to fill it

            "data_uncached": return DATA_P_UNCACHED;

            "": ;// return 'x; /* First, unnamed section: ingnore */

            default: $error("Wrong section label: %s", name);
        endcase

        return 'x;
    endfunction


    function automatic void allocateSections(input CodeSecArr sections, ref PageBasedProgramMemory pmem, ref SparseDataMemory dmem);
        foreach (sections[i]) begin

            if (sections[i].words.size() > 1024) $error("Section '%s' too big for page: %d", sections[i].desc, sections[i].words.size());

            case (sections[i].desc)
                "prog_main": pmem.assignPage(PROG_P_MAIN, sections[i].words);
                "prog_miss": pmem.assignPage(PROG_P_MISS, sections[i].words);

                "handlers":  pmem.assignPage(PROG_P_HANDLERS, sections[i].words);
                "lib":       pmem.assignPage(PROG_P_LIB, sections[i].words);


                "data0":     dmem.writeWordArray(DATA_P_MAIN, sections[i].words);
                "data1": ;
                "data_miss0": ;
                "data_miss1": ;

                "output": ; // Not loaded, leave default 0's and wait for tested program to fill it

                "data_uncached": dmem.writeWordArray(DATA_P_UNCACHED, sections[i].words);

                "": /* First, unnamed section: ingnore */;

                default: $error("Wrong section label: %s", sections[i].desc);
            endcase
        end

    endfunction 


    localparam string codeDir = "../../../../SV_CPU.srcs/code/";


    function automatic logic isValidTestName(input squeue line);
        if (line.size() > 1) $error("There should be 1 test per line");
        return line.size() == 1;
    endfunction


    task automatic saveProgramToFile(input string fname, input Word progMem[]);
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


    typedef struct {
        CoreStatus initialCoreStatus;
        CpuControlRegisters initialCregs;

        Translation preloadedInsTlbL1[$] = '{};
        Translation preloadedInsTlbL2[$] = '{};
        
        Dword copiedInsPages[];
        Dword preloadedInsWays[];
        
        Translation preloadedDataTlbL1[$] = '{};
        Translation preloadedDataTlbL2[$] = '{};
        
        Dword copiedDataPages[];
        Dword preloadedDataWays[];
    } GlobalParams;


    class TestRunner;
        logic announceSuites = 1;
    
        GlobalParams gp;
    
        PageBasedProgramMemory programMem;
    
        task automatic run();
        
        endtask

        task automatic runSuites(input squeue suites);
            foreach (suites[i]) begin
                squeue tests = readFile({codeDir, suites[i], ".txt"});
                if (announceSuites)
                    $display("* Suite: %s", suites[i]);
                runTests(suites[i], tests);
            end
        endtask

        task automatic runTests(input string suite, input squeue tests);
            foreach (tests[i]) begin
                squeue lineParts = breakLine(tests[i]);
                if (!isValidTestName(lineParts)) continue;
                runTest(suite, lineParts[0]);
            end
        endtask

        virtual task automatic runTest(input string suiteName, input string name);
        endtask
        
    endclass


    /*
        Test setup routines
    */

    function automatic GlobalParams Test_fillGpCached();
        GlobalParams gp;
        gp.initialCoreStatus = DEFAULT_CORE_STATUS;
        
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

        Translation physDataPageUnc = '{present: 1, vadr: 'h40000000, desc: uncachedDesc, padr: 'h40000000};

        Translation outputPage0 = '{present: 1, vadr: 'h4000, desc: cachedDesc, padr: 'h4000};

        Translation physDataPageAlt0 = '{present: 1, vadr: 0 + VIRTUAL_OFFSET_TLB_MISS, desc: cachedDesc, padr: 0};
        Translation physDataPageAlt1 = '{present: 1, vadr: PAGE_SIZE + VIRTUAL_OFFSET_TLB_MISS, desc: cachedDesc, padr: 4096};
        Translation physDataPageAlt2000 = '{present: 1, vadr: 'h2000 + VIRTUAL_OFFSET_TLB_MISS, desc: cachedDesc, padr: 'h2000};

        Translation outputPageAlt0 = '{present: 1, vadr: 'h4000 + VIRTUAL_OFFSET_TLB_MISS, desc: cachedDesc, padr: 'h4000};
    

        // Mapped to nonexistent memory
        Translation nonexistentPage = '{present: 1, vadr: 'ha000, desc: cachedDesc, padr: DATA_P_NONEXISTENT};
        
        // Mapped to correct memory but not allowed to read
        Translation disallowedPage = '{present: 1, vadr: 'h9000, desc: '{allowed: 0, canRead: 0, canWrite: 0, canExec: 0, cached: 1}, padr: 0};

        // vadr 'h8000 - not mapped 


        params.preloadedDataTlbL1 = '{physDataPage0, physDataPage1, physDataPage2000, outputPage0, physDataPageUnc,
                                            nonexistentPage, disallowedPage
                                        };

        params.preloadedDataTlbL2 = '{physDataPage0, physDataPage1, physDataPage2000, outputPage0, physDataPageUnc,
                                        physDataPageAlt0, physDataPageAlt1, physDataPageAlt2000, outputPageAlt0,
                                            nonexistentPage, disallowedPage
                                        };

        params.preloadedDataWays = '{0, 4*PAGE_SIZE};
    endfunction


    function automatic void Ins_prefetchForTest(ref GlobalParams params);
        DataLineDesc cachedDesc = '{allowed: 1, canRead: 1, canWrite: 1, canExec: 1, cached: 1};

        Translation physInsPage0 = '{present: 1, vadr: 0, desc: cachedDesc, padr: 0};
        Translation physInsPage1 = '{present: 1, vadr: PAGE_SIZE, desc: cachedDesc, padr: PAGE_SIZE};
        Translation physInsPage2 = '{present: 1, vadr: 2*PAGE_SIZE, desc: cachedDesc, padr: 2*PAGE_SIZE};
        Translation physInsPage3 = '{present: 1, vadr: 3*PAGE_SIZE, desc: cachedDesc, padr: 3*PAGE_SIZE};
        Translation physInsPage4 = '{present: 1, vadr: 4*PAGE_SIZE, desc: cachedDesc, padr: 4*PAGE_SIZE};

        Translation physInsPageAlt0 = '{present: 1, vadr: 0 + VIRTUAL_OFFSET_TLB_MISS, desc: cachedDesc, padr: 0};
        Translation physInsPageAlt2 = '{present: 1, vadr: 2*PAGE_SIZE + VIRTUAL_OFFSET_TLB_MISS, desc: cachedDesc, padr: 2*PAGE_SIZE};
        Translation physInsPageAlt3 = '{present: 1, vadr: 3*PAGE_SIZE + VIRTUAL_OFFSET_TLB_MISS, desc: cachedDesc, padr: 3*PAGE_SIZE};
        Translation physInsPageAlt4 = '{present: 1, vadr: 4*PAGE_SIZE + VIRTUAL_OFFSET_TLB_MISS, desc: cachedDesc, padr: 4*PAGE_SIZE};


        // Mapped to nonexistent memory
        Translation nonexistentPage = '{present: 1, vadr: 'ha000, desc: cachedDesc, padr: PROG_P_NONEXISTENT};
        
        // Mapped to correct memory but not allowed to read
        Translation disallowedPage = '{present: 1, vadr: 'h9000, desc: '{allowed: 0, canRead: 0, canWrite: 0, canExec: 0, cached: 1}, padr: 0};

        // vadr 'h8000 - not mapped 


        params.preloadedInsTlbL1 = '{physInsPage0, physInsPage1, physInsPage2, physInsPage3, physInsPage4,
                                        nonexistentPage, disallowedPage
                                    };

        params.preloadedInsTlbL2 = '{physInsPage0, physInsPage1, physInsPage2, physInsPage3, physInsPage4,
                                        physInsPageAlt0, physInsPageAlt2, physInsPageAlt3, physInsPageAlt4,
                                        nonexistentPage, disallowedPage
                                    };

        params.preloadedInsWays = '{0, PAGE_SIZE,     4*PAGE_SIZE};
    endfunction


    function automatic void setTestMemories(input string name, ref PageBasedProgramMemory pmem, ref SparseDataMemory dmem,
                                            input CodeSecArr handlerSections);
        CodeSecArr testSections = processFile(readFile({codeDir, name, ".txt"}));

        foreach (testSections[importer]) begin
            foreach (testSections[exporter]) begin
                Dword impStart = sectionStart(testSections[importer].desc);
                Dword expStart = sectionStart(testSections[exporter].desc);

                if (exporter == importer) continue;

                testSections[importer] = fillImports(testSections[importer], impStart, testSections[exporter], expStart);
            end
        end

        pmem.createPage(0);
        pmem.createPage(PAGE_SIZE);

        allocateSections(testSections, pmem, dmem);
        allocateSections(handlerSections, pmem, dmem);
    endfunction


    function automatic void checkOutput(input SparseDataMemory actualMem, input CodeSecArr sections);
        Dword OUTPUT_BASE = 4*PAGE_SIZE;
        CodeSec found[$] = sections.find with (item.desc == "output");

        for (int ind = 0; ind < PAGE_SIZE/4; ind++) begin
            Word expected = (found.size() == 0 || ind >= found[0].words.size()) ? 0 : found[0].words[ind];
            Word actual = actualMem.readWord(OUTPUT_BASE + 4*ind);

            assert (actual === expected) else begin
                $error("Mem compare (word %d): actual %x, expected %x", ind, actual, expected);
                $error("%p", actualMem.content);
            end
        end
    endfunction

    function automatic void checkOutputWA(input WordArray actualMem, input CodeSecArr sections);
        Dword OUTPUT_BASE = 4*PAGE_SIZE;
        CodeSec found[$] = sections.find with (item.desc == "output");

        for (int ind = 0; ind < PAGE_SIZE/4; ind++) begin
            Word expected = (found.size() == 0 || ind >= found[0].words.size()) ? 0 : found[0].words[ind];
            Word actual = actualMem[ind];

            assert (actual === expected) else begin
                $error("Mem compare (word %d): actual %x, expected %x", ind, actual, expected);
                $error("%p", actualMem);
            end
        end
    endfunction


    function automatic logic isErrorStatus(input Emulator emul);            
        return emul.status.eventType inside {PE_SYS_ERROR};
    endfunction

    function automatic logic isSendingStatus(input Emulator emul);            
        return emul.status.send == 1;
    endfunction

    task automatic resetAll(ref Emulator emul);
        emul.resetWithDataMem();
    endtask

endpackage
