
package Emulation;
    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import EmulationDefs::*;


    typedef struct {
        Mword intRegs[32], floatRegs[32], sysRegs[32];
        Mword target;
    } CpuState;

    const Mword SYS_REGS_INITIAL[32] = '{0: -1, default: 0};

    function automatic CpuState initialState(input Mword trg);
        return '{intRegs: '{default: 0}, floatRegs: '{default: 0}, sysRegs: SYS_REGS_INITIAL, target: trg};
    endfunction


    // Abstract description of page mapping and attributes 
    typedef struct {
        Mword vadr;
        Dword padr;
        bit read;
        bit write;
        bit exec;
        bit cache;
    } MemoryMapping;

    localparam MemoryMapping DEFAULT_MEMORY_MAPPING = '{'z, 'z, 0, 0, 0, 0};


    typedef struct {
        bit active;
        Mword vadr;
        Dword padr;
        Mword value;
        int size; // in bytes
    } MemoryWrite;

    const MemoryWrite DEFAULT_MEM_WRITE = '{active: 0, vadr: 'x, padr: 'x, value: 'x, size: -1};

    

    function automatic void writeIntReg(ref CpuState state, input int regNum, input Mword value);
        if (regNum == 0) return;
        assert (!$isunknown(value)) else $error("Writing unknown value! reg %d", regNum);
        state.intRegs[regNum] = value;
    endfunction

    function automatic void writeFloatReg(ref CpuState state, input int regNum, input Mword value);
        assert (!$isunknown(value)) else $error("Writing unknown value!");
        state.floatRegs[regNum] = value;
    endfunction
    

    function automatic void writeSysReg(ref CpuState state, input int regNum, input Mword value);
        state.sysRegs[regNum] = value;
    endfunction

    function automatic void performLink(ref CpuState state, input AbstractInstruction ins, input Mword adr);
        writeIntReg(state, ins.dest, adr + 4);
    endfunction


    typedef struct {
        int dummy;
        bit halted;
        bit error;
        bit send;
        ProgramEvent eventType;
            
    } CoreStatus;

    function automatic void performAsyncEvent(ref CpuState state, input Mword trg, input Mword prevTarget);
        state.sysRegs[5] = state.sysRegs[1];
        state.sysRegs[1] |= 2; // FUTURE: handle state register correctly
        state.sysRegs[3] = prevTarget;

        state.target = trg;
    endfunction

    function automatic void modifySysRegs(ref CpuState state, input Mword adr, input AbstractInstruction abs);
        case (abs.def.o)
            O_error: begin
                state.target = IP_ERROR;

                state.sysRegs[4] = state.sysRegs[1];
                state.sysRegs[1] |= 1; // FUTURE: handle state register correctly
                state.sysRegs[2] = adr + 4;
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
        CoreStatus status;
            
        CpuState coreState;
        
            // For now there are separate maps for program and data
            MemoryMapping programMappings[$];
            MemoryMapping dataMappings[$];
        

        PageBasedProgramMemory progMem = new();
        SparseDataMemory dataMem = new();
        
        MemoryWrite writeToDo;


        function automatic Emulator copyCore();
            Emulator res = new();
            
            res.ip = ip;
            res.status = status;
            res.coreState = coreState;
            
                res.programMappings = programMappings;
                res.dataMappings = dataMappings;
            
            res.progMem = new ();
            res.dataMem = new ();
            
            res.writeToDo = writeToDo;
            
            return res;
        endfunction

        function automatic void setLike(input Emulator other);
            ip = other.ip;
            status = other.status;
            coreState = other.coreState;

            programMappings = other.programMappings;
            dataMappings = other.dataMappings;

            dataMem = new other.dataMem;
            // Not setting progMem
            writeToDo = other.writeToDo;
        endfunction

        function automatic void resetCore();
            this.ip = 'x;

            this.status = '{eventType: PE_NONE, default: 0};
            this.writeToDo = DEFAULT_MEM_WRITE;

            this.coreState = initialState(IP_RESET);
                
               // TODO: think about mappings. They are not cleared here because simulation needs them but it seems inconsistent
               // this.programMappings.delete();
               // this.dataMappings.delete();
        endfunction

        function automatic void resetCoreAndMappings();
            resetCore();
            programMappings.delete();
            dataMappings.delete();
        endfunction


        function automatic void resetWithDataMem();
            resetCore();
            dataMem.clear();
        endfunction

        // TODO
        function automatic Dword translateAddressProgram(input Mword vadr);
            return Dword'(vadr);
        endfunction

        function automatic Translation translateAddressProgram_Impl(input Mword vadr);
            localparam logic DO_NOT_TRANSLATE_P = 0;

            MemoryMapping found[$] = programMappings.find with (item.vadr == getPageBaseM(vadr));
            Translation res;

            if (DO_NOT_TRANSLATE_P) begin
                res = '{present: 1, desc: '{default: 1}, padr: found[0].padr + vadr - getPageBaseM(vadr)};
            end
            else if (found.size() == 0) begin
                res = DEFAULT_TRANSLATION;
            end
            else
                res = '{present: 1, desc: '{1, found[0].read, found[0].write, found[0].exec, found[0].cache}, padr: found[0].padr + vadr - getPageBaseM(vadr)};
            return res;
        endfunction

        function automatic Translation translateAddressData_Impl(input Mword vadr);
            localparam logic DO_NOT_TRANSLATE = 1;

            MemoryMapping found[$] = dataMappings.find with (item.vadr == getPageBaseM(vadr));
            Translation res;

            if (DO_NOT_TRANSLATE) begin
                res = '{present: 1, desc: '{default: 1}, padr: found[0].padr + vadr - getPageBaseM(vadr)};
            end
            else if (found.size() == 0) begin
                res = DEFAULT_TRANSLATION;
            end
            else
                res = '{present: 1, desc: '{1, found[0].read, found[0].write, found[0].exec, found[0].cache}, padr: found[0].padr + vadr - getPageBaseM(vadr)};
            return res;
        endfunction

            function automatic Dword translateAddressData(input Mword vadr);
                //localparam logic DO_NOT_TRANSLATE = 1;
            
                MemoryMapping found[$] = dataMappings.find with (item.vadr == getPageBaseM(vadr));
                Translation res = translateAddressData_Impl(vadr);
                return res.padr;
                
                
    //            if (DO_NOT_TRANSLATE) return Dword'(vadr);
                
    //            if (found.size() == 0) begin
    //                res = DEFAULT_TRANSLATION;
    //                return 'x;
    //            end
                
    //            begin
    //                res = '{present: 1, desc: '{default: 1}, padr: found[0].padr + vadr - getPageBaseM(vadr)};
    //                //Dword padr = found[0].padr + vadr - getPageBaseM(vadr);
                
    //                return Dword'(vadr);
    //            end
            endfunction

        function automatic Mword computeResult(input Mword adr, input AbstractInstruction ins);
            FormatSpec fmtSpec = parsingMap[ins.def.f];
            Mword3 args = getArgs(coreState.intRegs, coreState.floatRegs, ins.sources, fmtSpec.typeSpec);
    
            if (!(isBranchIns(ins) || isMemIns(ins) || isSysIns(ins) || isLoadSysIns(ins)))
                return calculateResult(ins, args, adr);
            
            if (isBranchIns(ins))
                return adr + 4;
            
            // TODO: set exception if any is generated? If so, include store and sys instructions
            if (isMemIns(ins) || isLoadSysIns(ins)) begin
                Mword vadr = calculateEffectiveAddress(ins, args);
                Dword padr;// = translateAddressData(vadr);
                Translation tr = translateAddressData_Impl(vadr);
                padr = tr.padr;
                return getLoadValue(ins, vadr, padr);
            end
            
            return 'x;
        endfunction
        
        // TODO: introduce mem exceptions etc
        function automatic Mword getLoadValue(input AbstractInstruction ins, input Mword adr, input Dword padr);
            Mword result;

            case (ins.def.o)
                O_intLoadW: begin
                    result = dataMem.readWord(padr);
                end
                O_intLoadB: result = Mword'(dataMem.readByte(padr));
                O_intLoadAqW: result = dataMem.readWord(padr); // FUTURE

                O_intLoadD: ;
                O_floatLoadW: begin
                    result = dataMem.readWord(padr);
                end
                O_sysLoad: result = coreState.sysRegs[adr];
                default: return result;
            endcase
            
            return result;
        endfunction


        function automatic void executeStep();
            Mword vadr = this.coreState.target;
            
            if (!virtualAddressValid(vadr)) begin
                status.error = 1;
                status.eventType = PE_FETCH_INVALID_ADDRESS;
                coreState.target = IP_FETCH_EXC;
                return;
            end
            else if (vadr % 4 !== 0) begin
                status.error = 1;
                status.eventType = PE_FETCH_UNALIGNED_ADDRESS;
                coreState.target = IP_FETCH_EXC;
                return;
            end
            else begin
               // MemoryMapping found[$] = programMappings.find_first with (item.vadr === getPageBaseM(vadr));             
                Translation tr = translateAddressProgram_Impl(vadr);

                //if (found.size() == 0) begin
                if (!tr.present) begin
                        assert (!tr.present) else $error("wwoooo");
                    status.error = 1;
                    status.eventType = PE_FETCH_UNMAPPED_ADDRESS;
                    coreState.target = IP_FETCH_EXC;
                    return;
                end
                //else if (!found[0].exec) begin
                else if (!tr.desc.canExec) begin
                        assert (!tr.desc.canExec) else $error("h jo jo oj o ");
                    status.error = 1;
                    status.eventType = PE_FETCH_DISALLOWED_ACCESS;
                    coreState.target = IP_FETCH_EXC;
                    return;
                end
                //else if (!physicalAddressValid(found[0].padr)) begin
                else if (!physicalAddressValid(tr.padr)) begin
                    status.error = 1;
                    status.eventType = PE_FETCH_NONEXISTENT_ADDRESS;
                    coreState.target = IP_FETCH_EXC;
                    return;
                end
                else begin
                    AbstractInstruction absIns;
                    Dword padr = tr.padr;//translateAddressProgram(vadr); TODO
                                // found[0].padr + vadr - getPageBaseM(vadr);

                    TMP_FetchResult fres = progMem.fetch_N(padr);
                    
                    //padr = tr.padr;

                    if (!fres.ok) begin
                        status.error = 1;
                        status.eventType = PE_FETCH_NONEXISTENT_ADDRESS;
                        coreState.target = IP_FETCH_EXC;
                        return;
                    end 
                   
                    absIns = decodeAbstract(fres.w);
                    processInstruction(vadr, absIns);
                end
            end            
        endfunction 
        

        // Clear mem write and signals to send
        function automatic void drain();
            this.writeToDo = '{default: 0};
            this.status.send = 0;
        endfunction

        function automatic void processInstruction(input Mword adr, input AbstractInstruction ins);
            FormatSpec fmtSpec = parsingMap[ins.def.f];
            Mword3 args = getArgs(this.coreState.intRegs, this.coreState.floatRegs, ins.sources, fmtSpec.typeSpec);
            logic exceptionFromMem = 0;

            this.ip = adr;

            this.coreState.target = adr + 4;
            
            if (!(isBranchIns(ins) || isMemIns(ins) || isSysIns(ins) || isLoadSysIns(ins)))
                performCalculation(adr, ins, args);
            
            if (isBranchIns(ins))
                performBranch(ins, adr, args);
            
            if (isMemIns(ins) || isLoadSysIns(ins)) begin
                exceptionFromMem = performMem(ins, args);
                this.writeToDo = exceptionFromMem ? '{default: 0} : getMemWrite(ins, args);
            end
            
            if (isSysIns(ins))
                performSys(adr, ins, args);
            
            if (this.writeToDo.active) begin
                case (writeToDo.size)
                    1: dataMem.writeByte(writeToDo.padr, Mbyte'(writeToDo.value));
                    4: dataMem.writeWord(writeToDo.padr, writeToDo.value);
                    default: $error("Wrong store size %d/ %p", adr, ins);
                endcase
            end

        endfunction


        local function automatic void performCalculation(input Mword adr, input AbstractInstruction ins, input Mword3 vals);
            Mword result = calculateResult(ins, vals, adr);
            if (hasFloatDest(ins)) writeFloatReg(this.coreState, ins.dest, result);
            if (hasIntDest(ins)) writeIntReg(this.coreState, ins.dest, result);
        endfunction

        local function automatic void performBranch(input AbstractInstruction ins, input Mword ip, input Mword3 vals);
            ExecEvent evt = resolveBranch(ins, ip, vals);
            Mword trg = evt.redirect ? evt.target : ip + 4;
            
            if (!isBranchIns(ins)) return;

            performLink(this.coreState, ins, ip);
            this.coreState.target = trg;
        endfunction 

        local function automatic void performSys(input Mword adr, input AbstractInstruction ins, input Mword3 vals);
            if (isStoreSysIns(ins)) begin
                logic exc = writeSysReg__(coreState, ins, vals[1], vals[2]);
            end
            else begin
                modifyStatus(ins);
                modifySysRegs(this.coreState, adr, ins);
            end
        endfunction
        

        local function automatic logic performMem(input AbstractInstruction ins, input Mword3 vals);
            Mword vadr = calculateEffectiveAddress(ins, vals);
            Dword padr = 'x;

            if (isLoadSysIns(ins)) begin
                if (catchSysAccessException(ins, vadr)) begin
                    modifySysRegsOnException(this.coreState, this.ip, ins);
                    return 1;
                end
            end
            else begin
                MemoryMapping found[$] = dataMappings.find with (item.vadr == getPageBaseM(vadr));
                // TODO: translateAdr, use Translation type
                logic present = found.size() > 0;
                padr = found[0].padr + vadr - getPageBaseM(vadr);

                if (catchMemAccessException(ins, vadr, padr, present)) begin
                    modifySysRegsOnException(this.coreState, this.ip, ins);
                        coreState.target = IP_MEM_EXC;
                    return 1;
                end
            end
            
            begin
                Mword result = getLoadValue(ins, vadr, padr);
                if (!isLoadIns(ins)) return 0;
                if (hasFloatDest(ins)) writeFloatReg(this.coreState, ins.dest, result);
                if (hasIntDest(ins)) writeIntReg(this.coreState, ins.dest, result);
            end
            
            return 0;
        endfunction


        // Return 1 if exc
        local function automatic logic writeSysReg__(ref CpuState state, input AbstractInstruction ins, input int regNum, input Mword value);
            assert (!$isunknown(value)) else $error("Writing unknown value!");
            
            if (catchSysAccessException(ins, regNum)) begin
                modifySysRegsOnException(coreState, ip, ins);
                return 1;
            end
            
            writeSysReg(state, regNum, value);
            return 0;
        endfunction

        
        local function automatic MemoryWrite getMemWrite(input AbstractInstruction ins, input Mword3 vals);
            MemoryWrite res = DEFAULT_MEM_WRITE;
            Mword effAdr = calculateEffectiveAddress(ins, vals);            
            Dword physAdr;// = translateAddressData(effAdr);            
            Translation tr = translateAddressData_Impl(effAdr);
            logic en = 1;
            int size = -1;
            physAdr = tr.padr;

            case (ins.def.o)
                //O_intStoreD: size = 8;
                O_intStoreW: size = 4;
                O_intStoreRelW: size = 4;
                O_intStoreB: size = 1;
                O_floatStoreW: size = 4;
                default: ;
            endcase
            
            if (isStoreMemIns(ins)) res = '{en, effAdr, physAdr, vals[2], size};
            return res;
        endfunction

        function automatic void modifyStatus(input AbstractInstruction abs);
            case (abs.def.o)
                O_sysStore: ;
                O_error: begin                    
                    status.error = 1;
                    status.eventType = PE_SYS_ERROR;
                    //coreState.target = IP_FETCH_EXC;
                end
                O_undef: begin
                    status.error = 1;
                    status.eventType = PE_SYS_UNDEFINED_INSTRUCTION;
                end
                O_call: begin
                    status.eventType = PE_SYS_CALL;
                end
                O_sync: ;
                O_retE: ;
                O_retI: ;
                O_replay: ;
                O_halt: this.status.halted = 1;
                O_send: this.status.send = 1;
                default: ;
            endcase
        endfunction


        local function automatic logic catchSysAccessException(input AbstractInstruction ins, input Mword adr);
            if (ins.def.o == O_sysLoad && adr > 31) begin
                status.eventType = PE_SYS_INVALID_ADDRESS;
                coreState.target = IP_EXC;
                return 1;
            end
            if (ins.def.o == O_sysStore && adr > 31) begin
                status.eventType = PE_SYS_INVALID_ADDRESS;
                coreState.target = IP_EXC;
                return 1;
            end
            
            return 0;
        endfunction

        local function automatic logic catchMemAccessException(input AbstractInstruction ins, input Mword vadr, input Dword padr, input logic present);
                // TODO

            // PE_MEM_INVALID_ADDRESS = 3*16 + 0,
            if (!virtualAddressValid_T(vadr)) begin
                status.eventType = PE_MEM_INVALID_ADDRESS;
                coreState.target = IP_MEM_EXC;
                return 1;
            end
            
            // PE_MEM_UNMAPPED_ADDRESS = 3*16 + 3,
            if (!present) begin
                status.eventType = PE_MEM_UNMAPPED_ADDRESS;
                coreState.target = IP_MEM_EXC;
                return 1;         
            end

            // PE_MEM_DISALLOWED_ACCESS = 3*16 + 4,
            // TODO
            
            // PE_MEM_NONEXISTENT_ADDRESS = 3*16 + 7,
            if (!physicalAddressValid(padr)) begin
                status.eventType = PE_MEM_NONEXISTENT_ADDRESS;
                coreState.target = IP_MEM_EXC;
                return 1; 
            end                    

            
            return 0;
        endfunction


        function automatic void interrupt();
                status.eventType = PE_EXT_INTERRUPT;
        
            performAsyncEvent(this.coreState, IP_INT, this.coreState.target);
        endfunction
        
    endclass


    function automatic void runInEmulator(ref Emulator emul, input Mword adr, input Word bits);
        AbstractInstruction ins = decodeAbstract(bits);
        emul.processInstruction(adr, ins);
    endfunction

endpackage
