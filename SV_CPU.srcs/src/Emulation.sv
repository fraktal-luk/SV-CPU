
package Emulation;
    import Base::*;
    import InsDefs::*;
    import Asm::*;


    function automatic void writeArrayW(ref Mbyte mem[], input Mword adr, input Word val);
        mem[adr+0] = val[31:24];
        mem[adr+1] = val[23:16];
        mem[adr+2] = val[15:8];
        mem[adr+3] = val[7:0];
    endfunction

    function automatic void writeProgram(ref Word mem[],//[4096],
                                         input Mword adr, input Word prog[]);
        assert((adr % 4) == 0) else $fatal("Unaligned instruction address not allowed");
        foreach (prog[i]) mem[adr/4 + i] = prog[i];
    endfunction

    function automatic Word fetchInstruction(input Word progMem[], input Mword adr);
        assert (adr % 4 == 0) else $error("Fetching unaligned adr");
        assert (adr/4 < progMem.size()) else $error("Fetch adr OOB");
        return progMem[adr/4];
    endfunction


    typedef struct {
        Mword intRegs[32], floatRegs[32], sysRegs[32];
        Mword target;
    } CpuState;

    const Mword SYS_REGS_INITIAL[32] = '{
        0: -1,
        default: 0
    };

    function automatic CpuState initialState(input Mword trg);
        return '{intRegs: '{default: 0}, floatRegs: '{default: 0}, sysRegs: SYS_REGS_INITIAL, target: trg};
    endfunction

    typedef struct {
       Mword target;
       logic redirect;
    } ExecEvent;

    typedef struct {
        bit active;
        Mword adr;
        Mword value;
    } MemoryWrite;

    const MemoryWrite DEFAULT_MEM_WRITE = '{active: 0, adr: 'x, value: 'x};

    typedef struct {
        logic wrInt;
        logic wrFloat;
        int dest;
        Mword value;
    } RegisterWrite;

    const RegisterWrite DEFAULT_REG_WRITE = '{wrInt: 0, wrFloat: 0, dest: -1, value: 'x};

    typedef struct {
        int error;
        RegisterWrite regWrite;          
        MemoryWrite memWrite;
        Mword target;
    } ExecResult;

    const ExecResult DEFAULT_EXEC_RESULT = '{error: 0, regWrite: DEFAULT_REG_WRITE, memWrite: DEFAULT_MEM_WRITE, target: 'x};


    // 4kB pages
    class PageBasedProgramMem;
        localparam PAGE_BYTES = 4096;
        localparam PAGE_WORDS = PAGE_BYTES/4;
        typedef Word Page[];
        
        Page pages[int];

      
        function automatic void resetPage(input Mword startAdr);
            int index = startAdr/PAGE_BYTES;
            pages[index] = '{default: 'x};
        endfunction

        function automatic void createPage(input Mword startAdr);
            int index = startAdr/PAGE_BYTES;
            pages[index] = new[PAGE_WORDS]('{default: 'x});
        endfunction

        function automatic void assignPage(input Mword startAdr, input Word arr[]);
            int index = startAdr/PAGE_BYTES;
            pages[index] = arr;
        endfunction

        function automatic void writePage(input Mword startAdr, input Word arr[]);
            int index = startAdr/PAGE_BYTES;
            Page pg = pages[index];
            int size = arr.size() < PAGE_WORDS ? arr.size() : PAGE_WORDS;
            int offset = 0;
            while (offset < size)
                pg[offset] = arr[offset++];
            while (offset < PAGE_WORDS)
                pg[offset++] = 'x;
        endfunction
        
        function automatic Word fetch(input Mword startAdr);
            int index = startAdr/PAGE_BYTES;
            int offset = (startAdr%PAGE_BYTES)/4;
            
            return pages[index][offset];
        endfunction
        
    endclass


    class SimpleMem;
        Mbyte bytes[4096];
        
        function automatic void reset();
            this.bytes = '{default: 0};
        endfunction
        
        function automatic void copyFrom(input SimpleMem other);
            this.bytes = other.bytes;
        endfunction
        
        
        function automatic Mword loadB(input Mword adr);
            Mword res = 0;
            res[7:0] = this.bytes[adr];
            return res;
        endfunction
        
        function automatic Mword loadW(input Mword adr);
            Mword res = 0;
            Mbyte read[4];
            foreach (read[i])
                res = (res << 8) | this.bytes[adr + i];
            return res;
        endfunction
        
//        function automatic Word loadD(input Word adr);
//            Word res = 0;
//            res[7:0] = this.bytes[adr];
//        endfunction
        
        
        function automatic void storeB(input Mword adr, input Mword value);
            this.bytes[adr] = value[7:0];
        endfunction
        
        function automatic void storeW(input Mword adr, input Mword value);
            Mbyte read[4];
            Mword write = value;
            foreach (read[i]) begin
                this.bytes[adr + i] = write[31:24];
                write <<= 8;                
            end
        endfunction
        
//        function automatic void storeD(input Word adr);
        
//        endfunction   
        
    endclass

    
    // Not including memory
    function automatic logic isFloatCalcIns(input AbstractInstruction ins);
        return ins.def.o inside { O_floatMove, O_floatOr, O_floatAddInt };
    endfunction    


    function automatic logic isBranchIns(input AbstractInstruction ins);
        return ins.def.o inside {O_jump};
    endfunction

        function automatic logic isBranchImmIns(input AbstractInstruction ins);
            return ins.mnemonic inside {"ja", "jl", "jz_i", "jnz_i"};
        endfunction

        function automatic logic isBranchAlwaysIns(input AbstractInstruction ins);
            return ins.mnemonic inside {"ja", "jl"};
        endfunction

        function automatic logic isBranchRegIns(input AbstractInstruction ins);
            return ins.mnemonic inside {"jz_r", "jnz_r"};
        endfunction       
        

    function automatic logic isMemIns(input AbstractInstruction ins);
        return ins.def.o inside {O_intLoadW, O_intLoadD, O_intStoreW, O_intStoreD, O_floatLoadW, O_floatStoreW};
    endfunction
    
    function automatic logic isSysIns(input AbstractInstruction ins); // excluding sys load
        return ins.def.o inside {O_undef, O_call, O_sync, O_retE, O_retI, O_replay, O_halt, O_send,     O_sysStore};
    endfunction

    function automatic logic isLoadIns(input AbstractInstruction ins);
        return isLoadMemIns(ins) || isLoadSysIns(ins);//(ins.def.o inside {O_intLoadW, O_intLoadD, O_floatLoadW, O_sysLoad});
    endfunction

    function automatic logic isLoadSysIns(input AbstractInstruction ins);
        return (ins.def.o inside {O_sysLoad});
    endfunction

    function automatic logic isLoadMemIns(input AbstractInstruction ins);
        return (ins.def.o inside {O_intLoadW, O_intLoadD, O_floatLoadW});
    endfunction

    function automatic logic isFloatLoadMemIns(input AbstractInstruction ins);
        return (ins.def.o inside {O_floatLoadW});
    endfunction

    function automatic logic isStoreMemIns(input AbstractInstruction ins);
        return ins.def.o inside {O_intStoreW, O_intStoreD, O_floatStoreW};
    endfunction

    function automatic logic isFloatStoreMemIns(input AbstractInstruction ins);
        return ins.def.o inside {O_floatStoreW};
    endfunction
    

    function automatic logic isStoreSysIns(input AbstractInstruction ins);
        return ins.def.o inside {O_sysStore};
    endfunction
    
    function automatic logic isStoreIns(input AbstractInstruction ins);
        return isStoreMemIns(ins) || isStoreSysIns(ins);
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
            O_floatOr, O_floatAddInt,
            O_floatLoadW
        };
    endfunction


    function automatic ExecEvent resolveBranch(input AbstractInstruction abs, input Mword adr, input Mword3 vals);
        Mword3 args = vals;
        bit redirect = 0;
        Mword brTarget = (abs.mnemonic inside {"jz_r", "jnz_r"}) ? args[1] : adr + args[1];

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


    function automatic void writeIntReg(ref CpuState state, input int regNum, input Mword value);
        if (regNum == 0) return;
        assert (!$isunknown(value)) else $error("Writing unknown value! reg %d", regNum);
        state.intRegs[regNum] = value;
    endfunction

    function automatic void writeFloatReg(ref CpuState state, input int regNum, input Mword value);
        assert (!$isunknown(value)) else $error("Writing unknown value!");
        state.floatRegs[regNum] = value;
    endfunction
    
    // Return 1 if exc
    function automatic logic writeSysReg(ref CpuState state, input AbstractInstruction ins, input int regNum, input Mword value);
        assert (!$isunknown(value)) else $error("Writing unknown value!");
        
        if (regNum > 31) return 1;
        
        state.sysRegs[regNum] = value;
        return 0;
    endfunction


    function automatic Mword getArgValue(input Mword intRegs[32], input Mword floatRegs[32], input int src, input byte spec);
        case (spec)
           "i": return (intRegs[src]);
           "f": return (floatRegs[src]);
           "c": return Mword'(src);
           "0": return 0;
           default: $fatal("Wrong arg spec");    
        endcase;    
    
    endfunction

    function automatic Mword3 getArgs(input Mword intRegs[32], input Mword floatRegs[32], input int sources[3], input string typeSpec);
        Mword3 res;        
        foreach (sources[i]) res[i] = getArgValue(intRegs, floatRegs, sources[i], typeSpec[i+2]);
        
        return res;
    endfunction


   function automatic Mword calculateResult(input AbstractInstruction ins, input Mword3 vals, input Mword ip);
        Mword result;
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
            O_intDivS:  result = divSignedW(vals[0], vals[1]);
            O_intRemU:  result = $unsigned(vals[0]) % $unsigned(vals[1]);
            O_intRemS:  result = remSignedW(vals[0], vals[1]);
            
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

            O_floatOr:   result = vals[0] | vals[1];
            O_floatAddInt: result = vals[0] + vals[1];

            default: ;
        endcase
        
        // Some operations may have undefined cases but must not cause problems for the CPU
        if ((ins.def.o inside {O_intDivU, O_intDivS, O_intRemU, O_intRemS}) && $isunknown(result)) result = -1;
        
        return result;
    endfunction

    function automatic Mword calculateEffectiveAddress(input AbstractInstruction ins, input Mword3 vals);
        return (ins.def.o inside {O_sysLoad, O_sysStore}) ? vals[1] : vals[0] + vals[1];
    endfunction

    function automatic Mword getLoadValue(input AbstractInstruction ins, input Mword adr, input SimpleMem mem, inout CpuState state);
        Mword result;

        case (ins.def.o)
            O_intLoadW: result = mem.loadW(adr);
            O_intLoadD: ;
            O_floatLoadW: result = mem.loadW(adr);
            O_sysLoad: result = state.sysRegs[adr];
            default: return result;
        endcase
        
        return result;
    endfunction

    function automatic void performLink(ref CpuState state, input AbstractInstruction ins, input Mword adr);
        writeIntReg(state, ins.dest, adr + 4);
    endfunction


    typedef struct {
        int dummy;
        bit halted;
        bit error;
        bit send;
    } CoreStatus;

    function automatic void performAsyncEvent(ref CpuState state, input Mword trg, input Mword prevTarget);
        state.sysRegs[5] = state.sysRegs[1];
        state.sysRegs[1] |= 2; // FUTURE: handle state register correctly
        state.sysRegs[3] = prevTarget;

        state.target = trg;
    endfunction

    function automatic void modifySysRegs(ref CpuState state, input Mword adr, input AbstractInstruction abs);
        case (abs.def.o)
            O_sysStore: begin
                state.target = adr + 4;
            end
            O_undef: begin
                state.target = IP_ERROR;

                state.sysRegs[4] = state.sysRegs[1];
                state.sysRegs[1] |= 1; // FUTURE: handle state register correctly
                state.sysRegs[2] = adr + 4;
            end
            O_call: begin                    
                state.target = IP_CALL;

                state.sysRegs[4] = state.sysRegs[1];
                state.sysRegs[1] |= 1; // FUTURE: handle state register correctly
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
            default: state.target = adr + 4;
        endcase
    endfunction

    
    function automatic void modifySysRegsOnException(ref CpuState state, input Mword adr, input AbstractInstruction abs);
        state.target = IP_EXC;

        state.sysRegs[4] = state.sysRegs[1];
        state.sysRegs[1] |= 1; // FUTURE: handle state register correctly
        state.sysRegs[2] = adr;
    endfunction


    function automatic Mword computeResult(input CpuState state, input Mword adr, input AbstractInstruction ins, input SimpleMem dataMem);
        Mword res = 'x;
        FormatSpec fmtSpec = parsingMap[ins.fmt];
        Mword3 args = getArgs(state.intRegs, state.floatRegs, ins.sources, fmtSpec.typeSpec);

        if (!(isBranchIns(ins) || isMemIns(ins) || isSysIns(ins) || isLoadSysIns(ins)))
            res = calculateResult(ins, args, adr);
        
        if (isBranchIns(ins))
            res = adr + 4;
        
        if (isMemIns(ins) || isLoadSysIns(ins)) begin
            Mword adr = calculateEffectiveAddress(ins, args);
            res = getLoadValue(ins, adr, dataMem, state);
        end
        
        return res;
    endfunction


    class Emulator;
        Mword ip;
        string str; // Remove?
        CoreStatus status;
        CpuState coreState;
        
        Word progMem[] = new[4096];
        PageBasedProgramMem progMem_N = new();
        
        SimpleMem tmpDataMem = new();
        MemoryWrite writeToDo;

        function automatic void setLike(input Emulator other);
            ip = other.ip;
            str = other.str;
            status = other.status;
            coreState = other.coreState;
            tmpDataMem.copyFrom(other.tmpDataMem);
            writeToDo = other.writeToDo;
        endfunction

        // CAREFUL: clears data memory, doesn't affect progMem
        function automatic void reset();
            this.ip = 'x;
            this.str = "";

            this.status = '{default: 0};
            this.writeToDo = DEFAULT_MEM_WRITE;

            this.coreState = initialState(IP_RESET);
            this.tmpDataMem.reset();
        endfunction
        
        
        function automatic void executeStep();//input Word progMem[]);
            ExecResult execRes;
            Mword adr = this.coreState.target;
            Word bits = fetchInstruction(progMem, adr);
                Word bits_N = progMem_N.fetch(adr);
            AbstractInstruction absIns = decodeAbstract(bits_N);

                assert (bits_N === bits) else $error("Bits dofer %d, %x, %x", adr, bits, bits_N);

            execRes = processInstruction(adr, absIns, this.tmpDataMem);            
        endfunction 
        
        
//        function automatic CoreStatus checkStatus();
//            CoreStatus res;
            
//            return res; // DUMMY
//        endfunction 
        
        // Clear mem write and signals to send
        function automatic void drain();
            this.writeToDo = '{default: 0};
            this.status.send = 0;
        endfunction

        function automatic ExecResult processInstruction(input Mword adr, input AbstractInstruction ins, ref SimpleMem dataMem);
            ExecResult res = DEFAULT_EXEC_RESULT;
            FormatSpec fmtSpec = parsingMap[ins.fmt];
            Mword3 args = getArgs(this.coreState.intRegs, this.coreState.floatRegs, ins.sources, fmtSpec.typeSpec);

            this.ip = adr;
            this.str = disasm(ins.encoding);

            this.coreState.target = adr + 4;
            
            if (!(isBranchIns(ins) || isMemIns(ins) || isSysIns(ins) || isLoadSysIns(ins)))
                performCalculation(adr, ins, args);
            
            if (isBranchIns(ins))
                performBranch(ins, adr, args);
            
            if (isMemIns(ins) || isLoadSysIns(ins)) begin
                performMem(ins, args, dataMem);
                this.writeToDo = getMemWrite(ins, args);
            end
            
            if (this.writeToDo.active)
                dataMem.storeW(this.writeToDo.adr, this.writeToDo.value);

            if (isSysIns(ins))
                performSys(adr, ins, args);

            return res;
        endfunction


        local function automatic void performCalculation(input Mword adr, input AbstractInstruction ins, input Mword3 vals);
            Mword result = calculateResult(ins, vals, adr);
            if (hasFloatDest(ins)) writeFloatReg(this.coreState, ins.dest, result);
            if (hasIntDest(ins)) writeIntReg(this.coreState, ins.dest, result);
        endfunction

        local function automatic logic exceptionCaused(input AbstractInstruction ins, input Mword adr);
            if (ins.def.o == O_sysLoad && adr > 31) return 1;
            if (ins.def.o == O_sysStore && adr > 31) return 1;
            
            return 0;
        endfunction
        
        local function automatic void performMem(input AbstractInstruction ins, input Mword3 vals, input SimpleMem mem);
            Mword adr = calculateEffectiveAddress(ins, vals);
            
            if (exceptionCaused(ins, adr)) begin
                   // $error("Exception: sys reg %d", adr);
                modifySysRegsOnException(this.coreState, this.ip, ins);
                return;
            end
            
            begin
                Mword result = getLoadValue(ins, adr, mem, this.coreState);
    
                if (!isLoadIns(ins)) return;
    
                if (hasFloatDest(ins)) writeFloatReg(this.coreState, ins.dest, result);
                if (hasIntDest(ins)) writeIntReg(this.coreState, ins.dest, result);
            end
        endfunction

        local function automatic void performBranch(input AbstractInstruction ins, input Mword ip, input Mword3 vals);
            ExecEvent evt = resolveBranch(ins, ip, vals);
            Mword trg = evt.redirect ? evt.target : ip + 4;
            
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

        local function automatic void performSys(input Mword adr, input AbstractInstruction ins, input Mword3 vals);
            if (isStoreSysIns(ins)) begin
                logic exc = writeSysReg(this.coreState, ins, vals[1], vals[2]);                
                if (exc) modifySysRegsOnException(this.coreState, this.ip, ins);
                else modifySysRegs(this.coreState, adr, ins);
            end
            else begin
                modifyStatus(ins);
                modifySysRegs(this.coreState, adr, ins);
            end
        endfunction
        
        local function automatic MemoryWrite getMemWrite(input AbstractInstruction ins, input Mword3 vals);
            MemoryWrite res = DEFAULT_MEM_WRITE;
            Mword effAdr = calculateEffectiveAddress(ins, vals);            
            logic en = !exceptionCaused(ins, effAdr);
            
            if (isStoreMemIns(ins)) res = '{en, effAdr, vals[2]};
            return res;
        endfunction

        function automatic void interrupt();
            performAsyncEvent(this.coreState, IP_INT, this.coreState.target);
        endfunction
        
    endclass

    function automatic void runInEmulator(ref Emulator emul, input Mword adr, input Word bits);
        AbstractInstruction ins = decodeAbstract(bits);
        ExecResult res = emul.processInstruction(adr, ins, emul.tmpDataMem);
    endfunction

endpackage
