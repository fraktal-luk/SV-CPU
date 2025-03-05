
package Emulation;
    import Base::*;
    import InsDefs::*;
    import Asm::*;


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
        int size;
    } MemoryWrite;

    const MemoryWrite DEFAULT_MEM_WRITE = '{active: 0, adr: 'x, value: 'x, size: -1};

//    typedef struct {
//        logic wrInt;
//        logic wrFloat;
//        int dest;
//        Mword value;
//    } RegisterWrite;

//    const RegisterWrite DEFAULT_REG_WRITE = '{wrInt: 0, wrFloat: 0, dest: -1, value: 'x};

//    typedef struct {
//        int error;
//        //RegisterWrite regWrite;          
//        MemoryWrite memWrite;
//        Mword target;
//    } ExecResult;

//    const ExecResult DEFAULT_EXEC_RESULT = '{error: 0,/* regWrite: DEFAULT_REG_WRITE,*/ memWrite: DEFAULT_MEM_WRITE, target: 'x};


    // 4kB pages
    class PageBasedProgramMem;
        localparam PAGE_BYTES = 4096;
        localparam PAGE_WORDS = PAGE_BYTES/4;
        typedef Word Page[];
        
        Page pages[int];

      
        // TODO: removePage()
      
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
            int size = arr.size() < PAGE_WORDS ? arr.size() : PAGE_WORDS;
            int offset = 0;
            while (offset < size) pages[index][offset] = arr[offset++];
            while (offset < PAGE_WORDS) pages[index][offset++] = 'x;
        endfunction
        
        function automatic Word fetch(input Mword startAdr);
            int index = startAdr/PAGE_BYTES;
            int offset = (startAdr%PAGE_BYTES)/4;
            
            return pages[index][offset];
        endfunction
        
        
        function automatic Page getPage(input Mword startAdr);
            int index = startAdr/PAGE_BYTES;
            return pages[index];
        endfunction
    endclass



    class SparseDataMem;
        
        class RW#(type Elem = Mbyte, int ESIZE = 1);
            function automatic void write(input Mword startAdr, input Word value);
            
            endfunction
 
//            function automatic Mword read(input Mword startAdr);
//                return 0;
//            endfunction     
        endclass
        
        
        Mbyte content[Mword];
        
        function automatic void clear();
            content.delete();
        endfunction
        
        function automatic void writeWord(input Mword startAdr, input Word value);
            Mbyte bytes[4] = {>>{value}};
            foreach (bytes[i]) content[startAdr+i] = bytes[i];
        endfunction

        function automatic void writeByte(input Mword startAdr, input Mbyte value);
            Mbyte bytes[1] = {>>{value}};
            foreach (bytes[i]) content[startAdr+i] = bytes[i];
        endfunction

 
        function automatic Word readWord(input Mword startAdr);
            Mbyte bytes[4];
            foreach (bytes[i]) bytes[i] = content.exists(startAdr+i) ? content[startAdr+i] : 0;
            return {>>{bytes}};
        endfunction

        function automatic Mbyte readByte(input Mword startAdr);
            Mbyte bytes[1];
            foreach (bytes[i]) bytes[i] = content.exists(startAdr+i) ? content[startAdr+i] : 0;
             //   $error("emul rb: %h -> %h", startAdr, bytes[0]);
            return {>>{bytes}};
        endfunction
       
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
        return ins.def.o inside {O_intLoadW, O_intLoadD, O_intStoreW, O_intStoreD, O_floatLoadW, O_floatStoreW,  O_intLoadB,  O_intStoreB,  O_intLoadAqW, O_intStoreRelW};
    endfunction
    
    function automatic logic isSysIns(input AbstractInstruction ins); // excluding sys load
        return ins.def.o inside {O_undef, O_call, O_sync, O_retE, O_retI, O_replay, O_halt, O_send,     O_sysStore};
    endfunction

    function automatic logic isLoadIns(input AbstractInstruction ins);
        return isLoadMemIns(ins) || isLoadSysIns(ins);
    endfunction

    function automatic logic isLoadSysIns(input AbstractInstruction ins);
        return (ins.def.o inside {O_sysLoad});
    endfunction

    function automatic logic isLoadMemIns(input AbstractInstruction ins);
        return (ins.def.o inside {O_intLoadW, O_intLoadD, O_floatLoadW,    O_intLoadB,   O_intLoadAqW});
    endfunction

    function automatic logic isFloatLoadMemIns(input AbstractInstruction ins);
        return (ins.def.o inside {O_floatLoadW});
    endfunction

    function automatic logic isStoreMemIns(input AbstractInstruction ins);
        return ins.def.o inside {O_intStoreW, O_intStoreD, O_floatStoreW,    O_intStoreB,   O_intStoreRelW};
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
            
                O_intCmpGtU,
                O_intCmpGtS,
            
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
                
                O_intLoadB,
                
                O_intLoadAqW,
                O_intStoreRelW,
            
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
            
                O_intCmpGtU:  result = $unsigned(vals[0]) > $unsigned(vals[1]);
                O_intCmpGtS:  result = $signed(vals[0]) > $signed(vals[1]);
            
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


    class Emulator;
        Mword ip;
        string str; // Remove?
        CoreStatus status;
        CpuState coreState;
        
        PageBasedProgramMem progMem_N = new();
        SparseDataMem dataMem_N = new();
        
        MemoryWrite writeToDo;


        function automatic Emulator copy();
            Emulator res = new();
            
            res.ip = ip;
            res.str = str;
            res.status = status;
            res.coreState = coreState;
            
            res.progMem_N = new progMem_N;
            res.dataMem_N = new dataMem_N;
            
            res.writeToDo = writeToDo;
            
            return res;
        endfunction

        function automatic void setLike(input Emulator other);
            ip = other.ip;
            str = other.str;
            status = other.status;
            coreState = other.coreState;
            dataMem_N = new other.dataMem_N;
            writeToDo = other.writeToDo;
        endfunction

        // CAREFUL: clears data memory, doesn't affect progMem
        function automatic void reset();
            this.ip = 'x;
            this.str = "";

            this.status = '{default: 0};
            this.writeToDo = DEFAULT_MEM_WRITE;

            this.coreState = initialState(IP_RESET);

            this.dataMem_N.clear();
        endfunction


        function automatic Mword computeResult(input Mword adr, input AbstractInstruction ins);
            //Mword res = 'x;
            FormatSpec fmtSpec = parsingMap[ins.def.f];
            Mword3 args = getArgs(coreState.intRegs, coreState.floatRegs, ins.sources, fmtSpec.typeSpec);
    
            if (!(isBranchIns(ins) || isMemIns(ins) || isSysIns(ins) || isLoadSysIns(ins)))
                return calculateResult(ins, args, adr);
            
            if (isBranchIns(ins))
                return adr + 4;
            
            if (isMemIns(ins) || isLoadSysIns(ins)) begin
                Mword adr = calculateEffectiveAddress(ins, args);
                return getLoadValue(ins, adr);
            end
            
            return 'x;
        endfunction

        function automatic Mword getLoadValue(input AbstractInstruction ins, input Mword adr);
            Mword result;
    
            case (ins.def.o)
                O_intLoadW: begin
                    result = dataMem_N.readWord(adr);
                end
                O_intLoadB: result = Mword'(dataMem_N.readByte(adr));
                O_intLoadAqW: result = dataMem_N.readWord(adr); // TODO
                
                O_intLoadD: ;
                O_floatLoadW: begin
                    result = dataMem_N.readWord(adr);
                end
                O_sysLoad: result = coreState.sysRegs[adr];
                default: return result;
            endcase
            
            return result;
        endfunction


        function automatic void executeStep();
            Mword adr = this.coreState.target;
            Word bits = progMem_N.fetch(adr);
            AbstractInstruction absIns = decodeAbstract(bits);
            //ExecResult execRes = 
            processInstruction(adr, absIns);            
        endfunction 
        

        // Clear mem write and signals to send
        function automatic void drain();
            this.writeToDo = '{default: 0};
            this.status.send = 0;
        endfunction

        function automatic void processInstruction(input Mword adr, input AbstractInstruction ins);
            //ExecResult res = DEFAULT_EXEC_RESULT;
            FormatSpec fmtSpec = parsingMap[ins.def.f];
            Mword3 args = getArgs(this.coreState.intRegs, this.coreState.floatRegs, ins.sources, fmtSpec.typeSpec);

            this.ip = adr;
            this.str = disasm(ins.encoding);

            this.coreState.target = adr + 4;
            
            if (!(isBranchIns(ins) || isMemIns(ins) || isSysIns(ins) || isLoadSysIns(ins)))
                performCalculation(adr, ins, args);
            
            if (isBranchIns(ins))
                performBranch(ins, adr, args);
            
            if (isMemIns(ins) || isLoadSysIns(ins)) begin
                performMem(ins, args);
                this.writeToDo = getMemWrite(ins, args);
            end
            
            if (this.writeToDo.active) begin
                case (writeToDo.size)
                    1: dataMem_N.writeByte(writeToDo.adr, Mbyte'(writeToDo.value));
                    4: dataMem_N.writeWord(writeToDo.adr, writeToDo.value);
                    default: $error("Wrong store size %d/ %p", adr, ins);
                endcase
            end

            if (isSysIns(ins))
                performSys(adr, ins, args);

            //return res;
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
        
        local function automatic void performMem(input AbstractInstruction ins, input Mword3 vals);
            Mword adr = calculateEffectiveAddress(ins, vals);
            
            if (exceptionCaused(ins, adr)) begin
                modifySysRegsOnException(this.coreState, this.ip, ins);
                return;
            end
            
            begin
                Mword result = getLoadValue(ins, adr);
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
            int size = -1;
            
            case (ins.def.o)
                //O_intStoreD: size = 8;
                O_intStoreW: size = 4;
                O_intStoreRelW: size = 4;
                O_intStoreB: size = 1;
                O_floatStoreW: size = 4;
                default: ;
            endcase
            
            if (isStoreMemIns(ins)) res = '{en, effAdr, vals[2], size};
            return res;
        endfunction

        function automatic void interrupt();
            performAsyncEvent(this.coreState, IP_INT, this.coreState.target);
        endfunction
        
    endclass


    function automatic void runInEmulator(ref Emulator emul, input Mword adr, input Word bits);
        AbstractInstruction ins = decodeAbstract(bits);
        //ExecResult res = 
        emul.processInstruction(adr, ins);
    endfunction

endpackage
