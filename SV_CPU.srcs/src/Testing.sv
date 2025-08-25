
package Testing;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import EmulationDefs::*;
    import EmulationMemories::*;
    import Emulation::*;
    import AbstractSim::*;
    import Insmap::*;    

    typedef Word WordArray[];


    const string FAILING_HANDLER[$]  = {"sys_error", "ja 0", "sys_error"};


    const string DEFAULT_ERROR_HANDLER[$] = {"sys_error", "ja 0", "sys_error"};

    //const string DEFAULT_CALL_HANDLER[$]  = {"sys_send", "ja 0", "sys_error"};
    const string TESTED_CALL_HANDLER[$] = {"add_i r20, r0, 55", "sys_rete", "ja 0"};
    
    const string DEFAULT_RESET_HANDLER[$] = {/*"ja -512", /**/"ja -8704",/**/  "ja 0", "sys_error"};

    const string DEFAULT_INT_HANDLER[$]  = {"add_i r21, r0, 77", "sys_reti", "ja 0"};

    const string DEFAULT_EXC_HANDLER[$]  = {"add_i r1, r0, 37", "lds r20, r0, 2", "add_i r21, r20, 4", "sts r21, r0, 2", "sys_rete", "ja 0"};

    // FETCH_EXC
    
    // MEM_EXC

    const string DEFAULT_DB_HANDLER[$]  = {"sys_send", "ja 0", "sys_error"};

    const string DEFAULT_DBBREAK_HANDLER[$]  = {"jz_r r0, r0, r30", "ja 0", "sys_error"};




    const Section DEFAULT_RESET_SECTION = processLines(DEFAULT_RESET_HANDLER);

    const Section DEFAULT_ERROR_SECTION = processLines(DEFAULT_ERROR_HANDLER);

    //const Section DEFAULT_CALL_SECTION = processLines(DEFAULT_CALL_HANDLER);
    const Section TESTED_CALL_SECTION = processLines(TESTED_CALL_HANDLER);

    const Section DEFAULT_INT_SECTION = processLines(DEFAULT_INT_HANDLER);
    const Section FAILING_SECTION = processLines(FAILING_HANDLER);

    const Section DEFAULT_EXC_SECTION = processLines(DEFAULT_EXC_HANDLER);

    const Section DEFAULT_DB_SECTION = processLines(DEFAULT_DB_HANDLER);

    const Section DEFAULT_DBBREAK_SECTION = processLines(DEFAULT_DBBREAK_HANDLER);



    string codeDir = "../../../../SV_CPU.srcs/code/";


    function automatic void writeProgram(ref Word mem[], input Mword adr, input Word prog[]);
        assert((adr % 4) == 0) else $fatal("Unaligned instruction address not allowed");
        //mem = '{default: 'x};
        foreach (prog[i]) mem[adr/4 + i] = prog[i];
    endfunction

    function automatic void setBasicPrograms(
                              ref Word mem[],
                              input Section resetSec,
                              input Section errorSec,
                              input Section callSec,
                              input Section intSec,
                              input Section excSec,
                              input Section dbSec,
                              input Section dbBreakSec);
        mem = '{default: 'x};

        //writeProgram(mem, 0, testSec.words);

        writeProgram(mem, IP_RESET % PAGE_SIZE, resetSec.words);
        writeProgram(mem, IP_ERROR % PAGE_SIZE, errorSec.words);
        writeProgram(mem, IP_CALL % PAGE_SIZE, callSec.words);
        writeProgram(mem, IP_INT % PAGE_SIZE, intSec.words);
        writeProgram(mem, IP_EXC % PAGE_SIZE, excSec.words);
        writeProgram(mem, IP_DB_CALL % PAGE_SIZE, dbSec.words);
        writeProgram(mem, IP_DB_BREAK % PAGE_SIZE, dbBreakSec.words);
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


    function automatic WordArray prepareHandlersPage();//input Section callSec);//, input Section intSec);//, input Section excSec);
        WordArray mem = new [PAGE_SIZE/4];
        setBasicPrograms(mem, DEFAULT_RESET_SECTION, DEFAULT_ERROR_SECTION, TESTED_CALL_SECTION, DEFAULT_INT_SECTION, DEFAULT_EXC_SECTION, DEFAULT_DB_SECTION, DEFAULT_DBBREAK_SECTION);
        return mem;
    endfunction


    typedef struct {
        CoreStatus initialCoreStatus;
        
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
                squeue tests = readFile({codeDir, suites[i]});
                if (announceSuites)
                    $display("* Suite: %s", suites[i]);
                runTests(tests);
            end
        endtask

        task automatic runTests(input squeue tests);
            foreach (tests[i]) begin
                squeue lineParts = breakLine(tests[i]);
                if (!isValidTestName(lineParts)) continue;
                runTest(lineParts[0]);
            end
        endtask

        virtual task automatic runTest(input string name);
        endtask
        
    endclass

endpackage
