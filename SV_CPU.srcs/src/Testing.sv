
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

    typedef Word WordArray[];

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

    function automatic void allocateSections(input CodeSecArr sections, ref PageBasedProgramMemory pmem, ref SparseDataMemory dmem);
        foreach (sections[i]) begin

            if (sections[i].words.size() > 1024) $error("Section '%s' too big for page: %d", sections[i].desc, sections[i].words.size());

               // $error("-- Section: %s", sections[i].desc);

            case (sections[i].desc)
                "prog_main": pmem.assignPage(PROG_P_MAIN, sections[i].words);
                "prog_miss": pmem.assignPage(PROG_P_MISS, sections[i].words);

                "handlers": begin
                     //   $error("Setting handlers");
                    pmem.assignPage(PROG_P_HANDLERS, sections[i].words);
                 end
                "lib":      pmem.assignPage(PROG_P_LIB, sections[i].words);


                "data0":      dmem.writeWordArray(DATA_P_MAIN, sections[i].words);
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



    const string FAILING_HANDLER[$]  = {"sys_error", "ja 0", "sys_error"};

    const string DEFAULT_ERROR_HANDLER[$] = {"sys_error", "ja 0", "sys_error"};

    const string TESTED_CALL_HANDLER[$] = {"add_i r20, r0, 55", "sys_rete", "ja 0"};
    
    const string DEFAULT_RESET_HANDLER[$] = {/**/"ja -0x4200", /*"ja -8704",/**/  "ja 0", "sys_error"};

    const string DEFAULT_INT_HANDLER[$]  = {"add_i r21, r0, 77", "sys_reti", "ja 0"};

    const string DEFAULT_EXC_HANDLER[$]  = {"add_i r1, r0, 37", "lds r20, r0, 2", "add_i r21, r20, 4", "sts r21, r0, 2", "sys_rete", "ja 0"};

    const string MEM_EXC_HANDLER[$]  = {"add_i r1, r0, 58", "lds r20, r0, 2", "add_i r21, r20, 4", "sts r21, r0, 2", "sys_rete", "ja 0"};

    const string FETCH_EXC_HANDLER[$]  = {"add_i r1, r0, 88", /*"lds r20, r0, 2",*/ "add_i r21, r0, 16", "sts r21, r0, 2", "sys_rete", "ja 0"};


    const string DEFAULT_DB_HANDLER[$]  = {"sys_send", "ja 0", "sys_error"};

    const string DEFAULT_DBBREAK_HANDLER[$]  = {"jz_r r0, r0, r30", "ja 0", "sys_error"};

    const string DEFAULT_ARITH_HANDLER[$]  = {"add_i r29, r0, 98", "lds r20, r0, 2", "add_i r21, r20, 4", "sts r21, r0, 2", "sys_rete", "ja 0"};

    
    const string NOP_PADDING[$] = {"and_r r0, r0, r0", "and_r r0, r0, r0", "and_r r0, r0, r0", "and_r r0, r0, r0"};



    const CodeSec DEFAULT_RESET_SECTION = processLines(DEFAULT_RESET_HANDLER);

    const CodeSec DEFAULT_ERROR_SECTION = processLines(DEFAULT_ERROR_HANDLER);

    const CodeSec TESTED_CALL_SECTION = processLines(TESTED_CALL_HANDLER);

    const CodeSec DEFAULT_INT_SECTION = processLines(DEFAULT_INT_HANDLER);

    const CodeSec DEFAULT_EXC_SECTION = processLines(DEFAULT_EXC_HANDLER);

    const CodeSec MEM_EXC_SECTION = processLines(MEM_EXC_HANDLER);

    const CodeSec FETCH_EXC_SECTION = processLines(FETCH_EXC_HANDLER);

    const CodeSec DEFAULT_DB_SECTION = processLines(DEFAULT_DB_HANDLER);

    const CodeSec DEFAULT_DBBREAK_SECTION = processLines(DEFAULT_DBBREAK_HANDLER);

    const CodeSec DEFAULT_ARITH_SECTION = processLines(DEFAULT_ARITH_HANDLER);


    localparam string codeDir = "../../../../SV_CPU.srcs/code/";


    function automatic void writeProgram(ref Word mem[], input Mword adr, input Word prog[]);
        assert((adr % 4) == 0) else $fatal("Unaligned instruction address not allowed");
        foreach (prog[i]) mem[adr/4 + i] = prog[i];
    endfunction

    function automatic void setBasicPrograms(
                              ref Word mem[],
                              input CodeSec resetSec,
                              input CodeSec errorSec,
                              input CodeSec callSec,
                              input CodeSec intSec,
                              input CodeSec excSec,
                              input CodeSec fetchExcSec,
                              input CodeSec memExcSec,
                              input CodeSec dbSec,
                              input CodeSec dbBreakSec,
                              input CodeSec arithSec
                              );
        CodeSec nopSec = processLines(NOP_PADDING);

        mem = '{default: 'x};

        writeProgram(mem, IP_RESET % PAGE_SIZE, resetSec.words);
        writeProgram(mem, IP_ERROR % PAGE_SIZE, errorSec.words);
        writeProgram(mem, IP_CALL % PAGE_SIZE, callSec.words);
        writeProgram(mem, IP_INT % PAGE_SIZE, intSec.words);
        writeProgram(mem, IP_EXC % PAGE_SIZE, excSec.words);
        writeProgram(mem, IP_FETCH_EXC % PAGE_SIZE, fetchExcSec.words);
        writeProgram(mem, IP_MEM_EXC % PAGE_SIZE, memExcSec.words);
        writeProgram(mem, IP_DB_CALL % PAGE_SIZE, dbSec.words);
        writeProgram(mem, IP_DB_BREAK % PAGE_SIZE, dbBreakSec.words);
        writeProgram(mem, IP_ARITH_EXC % PAGE_SIZE, arithSec.words);
        
        // This is for testing against fetch speculation across pages in uncached mode
        // After the nop section is the beginning of page with copy of test code
        writeProgram(mem, PAGE_SIZE - 16, nopSec.words);
    endfunction


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


    function automatic WordArray prepareHandlersPage();
        WordArray mem = new [PAGE_SIZE/4];
        setBasicPrograms(mem, DEFAULT_RESET_SECTION, DEFAULT_ERROR_SECTION, TESTED_CALL_SECTION, DEFAULT_INT_SECTION, DEFAULT_EXC_SECTION,
                                FETCH_EXC_SECTION, MEM_EXC_SECTION, DEFAULT_DB_SECTION, DEFAULT_DBBREAK_SECTION, DEFAULT_ARITH_SECTION);
        return mem;
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
        Translation nonexistentPage = '{present: 1, vadr: 'h5000, desc: cachedDesc, padr: 'h2000000000000000};
        
        // Mapped to correct memory but not allowed to read
        Translation disallowedPage = '{present: 1, vadr: 'h6000, desc: '{allowed: 1, canRead: 0, canWrite: 0, canExec: 0, cached: 1}, padr: 'h200000};

        params.preloadedDataTlbL1 = '{physDataPage0, physDataPage1, physDataPage2000, outputPage0, physDataPageUnc, nonexistentPage, disallowedPage};

        params.preloadedDataTlbL2 = '{physDataPage0, physDataPage1, physDataPage2000, outputPage0, physDataPageUnc, nonexistentPage, disallowedPage,
                                        physDataPageAlt0, physDataPageAlt1, physDataPageAlt2000, outputPageAlt0
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
            Translation physInsPageAlt3 = '{present: 1, vadr: 3*PAGE_SIZE + VIRTUAL_OFFSET_TLB_MISS, desc: cachedDesc, padr: 3*PAGE_SIZE};
            Translation physInsPageAlt4 = '{present: 1, vadr: 4*PAGE_SIZE + VIRTUAL_OFFSET_TLB_MISS, desc: cachedDesc, padr: 4*PAGE_SIZE};

        params.preloadedInsWays = '{0, PAGE_SIZE,     4*PAGE_SIZE};

        params.preloadedInsTlbL1 = '{physInsPage0, physInsPage1, physInsPage2, physInsPage3, physInsPage4};
        params.preloadedInsTlbL2 = '{physInsPage0, physInsPage1, physInsPage2, physInsPage3, physInsPage4,
                                        physInsPageAlt0, physInsPageAlt3, physInsPageAlt4
                                    };        
    endfunction
    

endpackage
