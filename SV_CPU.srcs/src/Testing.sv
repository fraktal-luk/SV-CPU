
package Testing;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    import AbstractSim::*;
    import Insmap::*;    

    function automatic logic isValidTestName(input squeue line);
        if (line.size() > 1) $error("There should be 1 test per line");
        return line.size() == 1;
    endfunction

    class TestRunner;
        task automatic run();
        
        endtask

        task automatic runSuites(input squeue suites);
            foreach (suites[i]) begin
                squeue tests = readFile(suites[i]);
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
