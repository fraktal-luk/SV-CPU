`timescale 1ns / 1ps


package Emulation;
    import Base::*;
    import InsDefs::*;
    import Asm::*;


    function automatic writeArrayW(ref logic[7:0] mem[], input Word adr, input Word val);
        mem[adr+0] = val[31:24];
        mem[adr+1] = val[23:16];
        mem[adr+2] = val[15:8];
        mem[adr+3] = val[7:0];
    endfunction

    function automatic void writeProgram(ref Word mem[4096], input Word adr, input Word prog[]);
        assert((adr % 4) == 0) else $fatal("Unaligned instruction address not allowed");
        foreach (prog[i]) mem[adr/4 + i] = prog[i];
    endfunction


    typedef struct {
        Word intRegs[32], floatRegs[32], sysRegs[32];
        Word target;
    } CpuState;

    const Word SYS_REGS_INITIAL[32] = '{
        0: -1,
        default: 0
    };

    function automatic CpuState initialState(input Word trg);
        return '{intRegs: '{default: 0}, floatRegs: '{default: 0}, sysRegs: SYS_REGS_INITIAL, target: trg};
    endfunction

    typedef struct {
       Word target;
       logic redirect;
    } ExecEvent;

    typedef struct {
        bit active;
        Word adr;
        Word value;
    } MemoryWrite;

    const MemoryWrite DEFAULT_MEM_WRITE = '{active: 0, adr: 'x, value: 'x};

    typedef struct {
        logic wrInt;
        logic wrFloat;
        int dest;
        Word value;
    } RegisterWrite;

    const RegisterWrite DEFAULT_REG_WRITE = '{wrInt: 0, wrFloat: 0, dest: -1, value: 'x};

    typedef struct {
        int error;
        RegisterWrite regWrite;          
        MemoryWrite memWrite;
        Word target;
    } ExecResult;

    const ExecResult DEFAULT_EXEC_RESULT = '{error: 0, regWrite: DEFAULT_REG_WRITE, memWrite: DEFAULT_MEM_WRITE, target: 'x};



    class SimpleMem;
        logic [7:0] bytes[4096];
        
        function automatic void reset();
            this.bytes = '{default: 0};
        endfunction
        
        function automatic void copyFrom(input SimpleMem other);
            this.bytes = other.bytes;
        endfunction
        
        
        function automatic Word loadB(input Word adr);
            Word res = 0;
            res[7:0] = this.bytes[adr];
        endfunction
        
        function automatic Word loadW(input Word adr);
            Word res = 0;
            logic [7:0] read[4];
            foreach (read[i])
                res = (res << 8) | this.bytes[adr + i];
            return res;
        endfunction
        
//        function automatic Word loadD(input Word adr);
//            Word res = 0;
//            res[7:0] = this.bytes[adr];
//        endfunction
        
        
        function automatic void storeB(input Word adr, input Word value);
            this.bytes[adr] = value[7:0];
        endfunction
        
        function automatic void storeW(input Word adr, input Word value);
            logic [7:0] read[4];
            Word write = value;
            foreach (read[i]) begin
                this.bytes[adr + i] = write[31:24];
                write <<= 8;                
            end
        endfunction
        
//        function automatic void storeD(input Word adr);
        
//        endfunction   
        
    endclass


    function automatic logic isBranchIns(input AbstractInstruction ins);
        return ins.def.o inside {O_jump};
    endfunction
    
    function automatic logic isMemIns(input AbstractInstruction ins);
        return ins.def.o inside {O_intLoadW, O_intLoadD, O_intStoreW, O_intStoreD, O_floatLoadW, O_floatStoreW};
    endfunction
    
    function automatic logic isSysIns(input AbstractInstruction ins); // excluding sys load
        return ins.def.o inside {O_undef, O_call, O_sync, O_retE, O_retI, O_replay, O_halt, O_send,     O_sysStore};
    endfunction

    function automatic logic isLoadIns(input AbstractInstruction ins);
        return (ins.def.o inside {O_intLoadW, O_intLoadD, O_floatLoadW, O_sysLoad});
    endfunction

    function automatic logic isLoadSysIns(input AbstractInstruction ins);
        return (ins.def.o inside {O_sysLoad});
    endfunction

    function automatic logic isLoadMemInz(input AbstractInstruction ins);
        return (ins.def.o inside {O_intLoadW, O_intLoadD, O_floatLoadW});
    endfunction

    function automatic logic isStoreMemIns(input AbstractInstruction ins);
        return ins.def.o inside {O_intStoreW, O_intStoreD, O_floatStoreW};
    endfunction

    function automatic logic isStoreSysIns(input AbstractInstruction ins);
        return ins.def.o inside {O_sysStore};
    endfunction
    


    function automatic bit hasIntDest(input AbstractInstruction ins);
        return ins.def.o inside {
            O_jump,
            
            O_intAnd,
            O_intOr,
            O_intXor,
            
            O_intAdd,
            O_intSub,
            O_intAddH,
            
            O_intMul,
            O_intMulHU,
            O_intMulHS,
            O_intDivU,
            O_intDivS,
            O_intRemU,
            O_intRemS,
            
            O_intShiftLogical,
            O_intShiftArith,
            O_intRotate,
            
            O_intLoadW,
            O_intLoadD,
            
            O_sysLoad
        };
    endfunction

    function automatic bit hasFloatDest(input AbstractInstruction ins);
        return ins.def.o inside {
            O_floatMove,
            O_floatLoadW
        };
    endfunction


    function automatic ExecEvent resolveBranch(input CpuState state, input AbstractInstruction abs, input Word adr);//OpSlot op);
        Word3 args = getArgs(state.intRegs, state.floatRegs, abs.sources, parsingMap[abs.fmt].typeSpec);
        return resolveBranch_Internal(abs, adr, args);
    endfunction

    function automatic ExecEvent resolveBranch_Internal(input AbstractInstruction abs, input Word adr, input Word3 vals);//OpSlot op);
        Word3 args = vals;
        bit redirect = 0;
        Word brTarget = (abs.mnemonic inside {"jz_r", "jnz_r"}) ? args[1] : adr + args[1];

        case (abs.mnemonic)
            "ja", "jl": redirect = 1;
            "jz_i": redirect = (args[0] == 0);
            "jnz_i": redirect = (args[0] != 0);
            "jz_r": redirect = (args[0] == 0);
            "jnz_r": redirect = (args[0] != 0);
            default: ;
        endcase

        return '{brTarget, redirect};
    endfunction


    function automatic void writeIntReg(ref CpuState state, input Word regNum, input Word value);
        if (regNum == 0) return;
        assert (!$isunknown(value)) else $error("Writing unknown value! reg %d", regNum);
        state.intRegs[regNum] = value;
    endfunction

    function automatic void writeFloatReg(ref CpuState state, input Word regNum, input Word value);
        assert (!$isunknown(value)) else $error("Writing unknown value!");
        state.floatRegs[regNum] = value;
    endfunction

    function automatic void writeSysReg(ref CpuState state, input Word regNum, input Word value);
        assert (!$isunknown(value)) else $error("Writing unknown value!");
        state.sysRegs[regNum] = value;
    endfunction


    function automatic Word getArgValue(input Word intRegs[32], input Word floatRegs[32], input int src, input byte spec);
        case (spec)
           "i": return Word'(intRegs[src]);
           "f": return Word'(floatRegs[src]);
           "c": return Word'(src);
           "0": return 0;
           default: $fatal("Wrong arg spec");    
        endcase;    
    
    endfunction

    function automatic Word3 getArgs(input Word intRegs[32], input Word floatRegs[32], input int sources[3], input string typeSpec);
        Word3 res;        
        foreach (sources[i]) res[i] = getArgValue(intRegs, floatRegs, sources[i], typeSpec[i+2]);
        
        return res;
    endfunction


   function automatic Word calculateResult(input AbstractInstruction ins, input Word3 vals, input Word ip);
        Word result;
        case (ins.def.o)
            //O_jump: result = ip + 4; // link adr
            
            O_intAnd:  result = vals[0] & vals[1];
            O_intOr:   result = vals[0] | vals[1];
            O_intXor:  result = vals[0] ^ vals[1];
            
            O_intAdd:  result = vals[0] + vals[1];
            O_intSub:  result = vals[0] - vals[1];
            O_intAddH: result = vals[0] + (vals[1] << 16);
            
            O_intMul:   result = vals[0] * vals[1];
            O_intMulHU: result = (Dword'($unsigned(vals[0])) * Dword'($unsigned(vals[1]))) >> 32;
            O_intMulHS: result = (Dword'($signed(vals[0])) * Dword'($signed(vals[1]))) >> 32;
            O_intDivU:  result = $unsigned(vals[0]) / $unsigned(vals[1]);
            O_intDivS:  result = divSigned(vals[0], vals[1]);
            O_intRemU:  result = $unsigned(vals[0]) % $unsigned(vals[1]);
            O_intRemS:  result = remSigned(vals[0], vals[1]);
            
            O_intShiftLogical: begin                
                if ($signed(vals[1]) >= 0) result = $unsigned(vals[0]) << vals[1];
                else                       result = $unsigned(vals[0]) >> -vals[1];
            end
            O_intShiftArith: begin                
                if ($signed(vals[1]) >= 0) result = $signed(vals[0]) << vals[1];
                else                       result = $signed(vals[0]) >> -vals[1];
            end
            O_intRotate: begin
                if ($signed(vals[1]) >= 0) result = {vals[0], vals[0]} << vals[1];
                else                       result = {vals[0], vals[0]} >> -vals[1];
            end
            
            O_floatMove: result = vals[0];

            default: ;
        endcase
        
        // Some operations may have undefined cases but must not cause problems for the CPU
        if ((ins.def.o inside {O_intDivU, O_intDivS, O_intRemU, O_intRemS}) && $isunknown(result)) result = -1;
        
        return result;
    endfunction

    function automatic Word calculateEffectiveAddress(input AbstractInstruction ins, input Word3 vals);
        return (ins.def.o inside {O_sysLoad, O_sysStore}) ? vals[1] : vals[0] + vals[1];
    endfunction

    function automatic Word getLoadValue(input AbstractInstruction ins, input Word adr, input SimpleMem mem, inout CpuState state);
        Word result;

        case (ins.def.o)
            O_intLoadW: result = mem.loadW(adr);
            O_intLoadD: ;
            O_floatLoadW: result = mem.loadW(adr);
            O_sysLoad: result = state.sysRegs[adr];
            default: return result;
        endcase
        
        return result;
    endfunction

    function automatic void performLink(ref CpuState state, input AbstractInstruction ins, input Word adr);
        writeIntReg(state, ins.dest, adr + 4);
    endfunction

    function automatic void performAsyncEvent(ref CpuState state, input Word trg);
        state.sysRegs[5] = state.sysRegs[1];
        state.sysRegs[1] |= 2; // TODO: handle state register correctly
        state.sysRegs[3] = state.target;

        state.target = trg;
    endfunction


    typedef struct {
        int dummy;
        bit halted;
        bit error;
        bit send;
    } CoreStatus;


    function automatic void modifySysRegs(ref CpuState state, input Word adr, input AbstractInstruction abs);
        case (abs.def.o)
            O_sysStore: begin
                state.target = adr + 4;
            end
            O_undef: begin
                state.target = IP_ERROR;

                state.sysRegs[4] = state.sysRegs[1];
                state.sysRegs[1] |= 1; // TODO: handle state register correctly
                state.sysRegs[2] = adr + 4;
            end
            O_call: begin                    
                state.target = IP_CALL;

                state.sysRegs[4] = state.sysRegs[1];
                state.sysRegs[1] |= 1; // TODO: handle state register correctly
                state.sysRegs[2] = adr + 4;
            end
            O_sync: begin
                state.target = adr + 4;
            end
            O_retE: begin
                state.target = state.sysRegs[2];
                
                state.sysRegs[1] = state.sysRegs[4];
            end
            O_retI: begin
                state.target = state.sysRegs[3];

                state.sysRegs[1] = state.sysRegs[5];
            end
            O_replay: begin
                state.target = adr;
            end
            O_halt: begin
                state.target = adr;
            end
            O_send: begin
                state.target = adr + 4;
            end
            default: return;
        endcase
    endfunction

    function automatic Word computeResult(input CpuState state, input Word adr, input AbstractInstruction ins, input SimpleMem dataMem);
        Word res = 'x;
        FormatSpec fmtSpec = parsingMap[ins.fmt];
        Word3 args = getArgs(state.intRegs, state.floatRegs, ins.sources, fmtSpec.typeSpec);

        if (!(isBranchIns(ins) || isMemIns(ins) || isSysIns(ins) || isLoadSysIns(ins)))
            res = calculateResult(ins, args, adr);
        
        if (isBranchIns(ins))
            res = adr + 4;
        
        if (isMemIns(ins) || isLoadSysIns(ins)) begin
            Word adr = calculateEffectiveAddress(ins, args);
            res = getLoadValue(ins, adr, dataMem, state);
        end
    endfunction


    class Emulator;
        Word ip;
        string str;
        CoreStatus status;
        CpuState coreState;
        SimpleMem tmpDataMem = new();
        MemoryWrite writeToDo;


        function automatic void reset();
            this.ip = 'x;
            
            this.status = '{default: 0};
            this.writeToDo = DEFAULT_MEM_WRITE;

            this.coreState.target = IP_RESET;

            this.coreState.intRegs = '{default: 0};
            this.coreState.floatRegs = '{default: 0};
            this.coreState.sysRegs = SYS_REGS_INITIAL;
            
            this.tmpDataMem.reset();
        endfunction
        
        
        function automatic void executeStep(input Word progMem[]);
            AbstractInstruction absIns;
            ExecResult execRes;
            this.ip = this.coreState.target;
            absIns = decodeAbstract(progMem[this.ip/4]);
            this.str = disasm(absIns.encoding);
            execRes = processInstruction(this.ip, absIns, this.tmpDataMem);            
        endfunction 
        
        
        function automatic CoreStatus checkStatus();
        
        endfunction 
        
        // Clear mem write and signals to send
        function automatic void drain();
            this.writeToDo = '{default: 0};
            this.status.send = 0;
        endfunction

        local function automatic ExecResult processInstruction(input Word adr, input AbstractInstruction ins, ref SimpleMem dataMem);
            ExecResult res = DEFAULT_EXEC_RESULT;
            FormatSpec fmtSpec = parsingMap[ins.fmt];
            Word3 args = getArgs(this.coreState.intRegs, this.coreState.floatRegs, ins.sources, fmtSpec.typeSpec);

            this.coreState.target = adr + 4;
            
            if (!(isBranchIns(ins) || isMemIns(ins) || isSysIns(ins) || isLoadSysIns(ins)))
                performCalculation(adr, ins, args);
            
            if (isBranchIns(ins))
                performBranch(ins, adr, args);
            
            if (isMemIns(ins) || isLoadSysIns(ins)) begin
                performLoad(ins, args, dataMem);
                this.writeToDo = getMemWrite(ins, args);
            end
            
            if (this.writeToDo.active)
                dataMem.storeW(this.writeToDo.adr, this.writeToDo.value);

            if (isSysIns(ins))
                performSys(adr, ins, args);

            return res;
        endfunction


        local function automatic void performCalculation(input Word adr, input AbstractInstruction ins, input Word3 vals);
            Word result = calculateResult(ins, vals, adr);
            if (hasFloatDest(ins)) writeFloatReg(this.coreState, ins.dest, result);
            if (hasIntDest(ins)) writeIntReg(this.coreState, ins.dest, result);
        endfunction

        local function automatic void performLoad(input AbstractInstruction ins, input Word3 vals, input SimpleMem mem);
            Word adr = calculateEffectiveAddress(ins, vals);
            Word result = getLoadValue(ins, adr, mem, this.coreState);

            if (!isLoadIns(ins)) return;

            if (hasFloatDest(ins)) writeFloatReg(this.coreState, ins.dest, result);
            if (hasIntDest(ins)) writeIntReg(this.coreState, ins.dest, result);
        endfunction


        local function automatic void performBranch(input AbstractInstruction ins, input Word ip, input Word3 vals);
            ExecEvent evt = resolveBranch_Internal(ins, ip, vals);
            Word trg = evt.redirect ? evt.target : ip + 4;
            
            if (!isBranchIns(ins)) return;

            performLink(this.coreState, ins, ip);
            this.coreState.target = trg;
        endfunction 


        function automatic void modifyStatus(input AbstractInstruction abs);
            case (abs.def.o)
                O_sysStore: ;
                O_undef: this.status.error = 1;
                O_call: ;
                O_sync: ;
                O_retE: ;
                O_retI: ;
                O_replay: ;
                O_halt: this.status.halted = 1;
                O_send: this.status.send = 1;
                default: ;
            endcase
        endfunction

        local function automatic void performSys(input Word adr, input AbstractInstruction ins, input Word3 vals);
            if (isStoreSysIns(ins)) writeSysReg(this.coreState, vals[1], vals[2]);
            modifyStatus(ins);
            modifySysRegs(this.coreState, adr, ins);
        endfunction
        
        local function automatic MemoryWrite getMemWrite(input AbstractInstruction ins, input Word3 vals);
            MemoryWrite res = DEFAULT_MEM_WRITE;
            if (isStoreMemIns(ins)) res = '{1, calculateEffectiveAddress(ins, vals), vals[2]};
            return res;
        endfunction

        function automatic void interrupt();
            performAsyncEvent(this.coreState, IP_INT);
        endfunction
        
    endclass



    class EmulationWithMems;
        Emulator emul;
        Word progMem[4096];
        logic[7:0] dataMem[] = new[4096]('{default: 0});
 
        function new();
            this.emul = new();
            this.reset();
        endfunction

        function void reset();
            this.emul.reset();
            this.dataMem = '{default: 0};
            this.progMem = '{default: 'x}; 
        endfunction
        
        function void resetCpu();
            this.emul.reset();
        endfunction  
                
        function void writeProgram(input Word prog[], input int adr);
            foreach (prog[i]) this.progMem[adr/4 + i] = prog[i];
        endfunction
        
        
        function void writeData();
            
        endfunction


        function void setBasicHandlers();
            this.progMem[IP_RESET/4] = processLines({"ja -512"}).words[0];
            this.progMem[IP_RESET/4 + 1] = processLines({"ja 0"}).words[0];
           
            this.progMem[IP_ERROR/4] = processLines({"sys error"}).words[0];
            this.progMem[IP_ERROR/4 + 1] = processLines({"ja 0"}).words[0];
    
            this.progMem[IP_CALL/4] = processLines({"sys send"}).words[0];
            this.progMem[IP_CALL/4 + 1] = processLines({"ja 0"}).words[0];        
        endfunction
        
        function automatic void prepareTest(input string name, input int commonAdr);
            squeue fileLines = readFile(name);
            Section common = processLines(readFile("common_asm.txt"));
            Section testSection = processLines(fileLines);
            testSection = fillImports(testSection, 0, common, commonAdr);
            
            this.writeProgram(testSection.words, 0);
            this.writeProgram(common.words, commonAdr);
            
            this.setBasicHandlers();
            
            this.emul.reset();
        endfunction
 
         function automatic void prepareErrorTest(input int commonAdr);
            squeue fileLines = {"undef", "ja 0"};
            Section common = processLines(readFile("common_asm.txt"));
            Section testSection = processLines(fileLines);
            testSection = fillImports(testSection, 0, common, commonAdr);
            
            this.writeProgram(testSection.words, 0);
            this.writeProgram(common.words, commonAdr);
            
            this.setBasicHandlers();
            
            this.emul.reset();
        endfunction

         function automatic void prepareEventTest(input int commonAdr);
            squeue fileLines = readFile("events.txt");
            Section common = processLines(readFile("common_asm.txt"));
            Section testSection = processLines(fileLines);
            testSection = fillImports(testSection, 0, common, commonAdr);
            
            this.writeProgram(testSection.words, 0);
            this.writeProgram(common.words, commonAdr);
            
            this.setBasicHandlers();
            
            this.writeProgram(processLines({"add_i r20, r0, 55", "sys rete", "ja 0"}).words, IP_CALL);        

            this.emul.reset();
        endfunction

 
        function automatic void prepareIntTest(input int commonAdr);
            squeue fileLines = readFile("events2.txt");
            Section common = processLines(readFile("common_asm.txt"));
            Section testSection = processLines(fileLines);
            testSection = fillImports(testSection, 0, common, commonAdr);
            
            this.writeProgram(testSection.words, 0);
            this.writeProgram(common.words, commonAdr);
            
            this.setBasicHandlers();

            this.writeProgram(processLines({"add_i r20, r0, 55", "sys rete", "ja 0"}).words, IP_CALL);        
            this.writeProgram(processLines({"add_i r21, r0, 77", "sys reti", "ja 0"}).words, IP_INT);        
              
            this.emul.reset();
        endfunction
 
 
        function automatic void step();
            this.emul.executeStep(this.progMem);
        endfunction
        
        function automatic void writeAndDrain();
            if (this.emul.writeToDo.active) writeArrayW(this.dataMem, emul.writeToDo.adr, emul.writeToDo.value);            
            this.emul.drain();
        endfunction 
        
        function automatic void interrupt();
            this.emul.interrupt();
        endfunction
        
    endclass

endpackage
