
package Testing;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    import AbstractSim::*;
    import Insmap::*;    


    string codeDir = "../../../../SV_CPU.srcs/code/";


    function automatic void writeProgram(ref Word mem[], input Mword adr, input Word prog[]);
        assert((adr % 4) == 0) else $fatal("Unaligned instruction address not allowed");
        foreach (prog[i]) mem[adr/4 + i] = prog[i];
    endfunction

    task automatic setPrograms(ref Word mem[],
                              input Section testSec,
                              input Section resetSec, input Section errorSec, input Section callSec, input Section intSec, input Section excSec, input Section commonSec, input Mword commonAdr);
        mem = '{default: 'x};
                 
        writeProgram(mem, 0, testSec.words);
        
        writeProgram(mem, IP_RESET, resetSec.words);
        writeProgram(mem, IP_ERROR, errorSec.words);
        writeProgram(mem, IP_CALL, callSec.words);
        writeProgram(mem, IP_INT, intSec.words);
        writeProgram(mem, IP_EXC, excSec.words);
        
        writeProgram(mem, commonAdr, commonSec.words);
    endtask


    function automatic logic isValidTestName(input squeue line);
        if (line.size() > 1) $error("There should be 1 test per line");
        return line.size() == 1;
    endfunction


    class TestRunner;
        logic announceSuites = 1;
    
        task automatic run();
        
        endtask

        task automatic runSuites(input squeue suites);
            foreach (suites[i]) begin
                squeue tests = readFile({codeDir, suites[i]});
                if (announceSuites)
                    $display("Suite: %s", suites[i]);
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

endpackage
