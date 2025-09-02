
package Emulation;
    import Base::*;
    import InsDefs::*;
    import ControlRegisters::*;
    import Asm::*;
    import EmulationDefs::*;
    import EmulationMemories::*;
    

    typedef struct {
        Mword intRegs[32], floatRegs[32], sysRegs[32];
        Mword target;
    } CpuState;

    const Mword SYS_REGS_INITIAL[32] = '{0: -1, 1: 1, default: 0};


    function automatic CpuState initialState(input Mword trg);
        return '{intRegs: '{default: 0}, floatRegs: '{default: 0}, sysRegs: SYS_REGS_INITIAL, target: trg};
    endfunction


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
        // SR_SET
        state.sysRegs[regNum] = value;        
    endfunction

    function automatic void performLink(ref CpuState state, input AbstractInstruction ins, input Mword adr);
        writeIntReg(state, ins.dest, adr + 4);
    endfunction


        function automatic void setRegsFromStatus(ref Mword sysRegs[32], CoreStatus status);
            // Status
            //coreState.sysRegs[1] = ;
            
            // Exc saved IP
            //coreState.sysRegs[2] = ;
            
            // Exc saved status
            //coreState.sysRegs[3] = ;
            
            // Int saved IP
            //coreState.sysRegs[4] = ;
            
            // Int saved status
            //coreState.sysRegs[5] = ;


            // syndrome
            sysRegs[6] = status.eventType;

            // mem control
            sysRegs['ha] = status.memControl;
                assert (status.memControl[0] === status.enableMmu) else $fatal(2, "Difference in mmu ctrl %p", status);
            
        endfunction


        function automatic void setStatusFromRegs(ref CoreStatus status, Mword sysRegs[32]);
            
            // syndrome
            status.eventType = ProgramEvent'(sysRegs[6]);

            // mem control
            status.memControl = sysRegs['ha];
                status.enableMmu = status.memControl[0];
        endfunction



    class Emulator;
        Mword ip;
        CoreStatus status;
        
        CpuControlRegisters cregs;
        
        CpuState coreState;
        
        // For now there are separate maps for program and data
        Translation programMappings[$];
        Translation dataMappings[$];        

        PageBasedProgramMemory progMem = new();
        SparseDataMemory dataMem = new();
        

        function automatic Emulator copyCore();
            Emulator res = new();
            
            res.ip = ip;
            res.status = status;
            res.cregs = cregs;
            res.coreState = coreState;

            res.programMappings = programMappings;
            res.dataMappings = dataMappings;
                        
            res.progMem = new ();
            res.dataMem = new ();
            
            return res;
        endfunction

        function automatic void setLike(input Emulator other);
            ip = other.ip;
            status = other.status;
            cregs = other.cregs;
            coreState = other.coreState;

            programMappings = other.programMappings;
            dataMappings = other.dataMappings;

            dataMem = new other.dataMem;
            // Not setting progMem
        endfunction

        function automatic void resetCore();
            this.ip = 'x;

            this.status = DEFAULT_CORE_STATUS;//'{eventType: PE_NONE, default: 0};

            this.coreState = initialState(IP_RESET);
                    
            syncRegsFromStatus();

            syncCregsFromSysRegs();

            this.programMappings.delete();
            this.dataMappings.delete();
        endfunction

        function automatic void resetCoreAndMappings();
            resetCore();
        endfunction


        function automatic void resetWithDataMem();
            resetCore();
            dataMem.clear();
        endfunction


        function automatic void syncRegsFromStatus();
            setRegsFromStatus(coreState.sysRegs, status);
        endfunction

        function automatic void syncStatusFromRegs();
            setStatusFromRegs(status, coreState.sysRegs);
        endfunction


        function automatic void syncCregsFromSysRegs();
            syncCregsFromArray(cregs, coreState.sysRegs);
        endfunction

        function automatic void syncSysRegsFromCregs();
            syncArrayFromCregs(coreState.sysRegs, cregs);
        endfunction

        function automatic Translation translateProgramAddress(input Mword vadr);
            Translation foundTr[$] = programMappings.find with (item.vadr == getPageBaseM(vadr));

            if (!cregs.memControl.enableMMU) begin
                return '{present: 1, vadr: vadr, desc: '{allowed: 1, canRead: 1, canWrite: 1, canExec: 1, cached: 0}, padr: vadr};
            end
            else if (foundTr.size() == 0) begin
                return DEFAULT_TRANSLATION;
            end
            else
                return '{present: 1, vadr: vadr, desc: foundTr[0].desc, padr: foundTr[0].padr + vadr - getPageBaseM(vadr)};
        endfunction

        function automatic Translation translateDataAddress(input Mword vadr);
            Translation foundTr[$] = dataMappings.find with (item.vadr == getPageBaseM(vadr));

            if (!cregs.memControl.enableMMU) begin
                return '{present: 1, vadr: vadr, desc: '{allowed: 1, canRead: 1, canWrite: 1, canExec: 1, cached: 0}, padr: vadr};
            end
            else if (foundTr.size() == 0) begin
                return DEFAULT_TRANSLATION;
            end
            else
                return '{present: 1, vadr: vadr, desc: foundTr[0].desc, padr: foundTr[0].padr + vadr - getPageBaseM(vadr)};
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
                Translation tr = translateDataAddress(vadr);
                return getLoadValue(ins, vadr, tr.padr);
            end
            
            return 'x;
        endfunction
        
        function automatic Mword getLoadValue(input AbstractInstruction ins, input Mword adr, input Dword padr);
            Mword result;

            if ($isunknown(padr) && ins.def.o != O_sysLoad) return 'x;

            case (ins.def.o)
                O_intLoadW: begin
                    result = $signed(dataMem.readWord(padr));
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

    
        function automatic void performAsyncEvent(/*input Mword trg,*/ input ProgramEvent evType, input Mword prevTarget);            
            Mword trg = programEvent2trg(evType);

            // SR_SET
            cregs.intSavedIP = prevTarget;
            cregs.intSavedStatus = cregs.currentStatus;

            cregs.currentStatus.intLevel |= 1;
            cregs.currentStatus.dbStep = 0;

            cregs.intSyndrome = evType;
                cregs.excSyndrome = evType; // TODO: temporary

            syncSysRegsFromCregs();
                     
            coreState.target = trg;
        endfunction


        function automatic void setExecState(input ProgramEvent evType, input Mword adr);
            Mword trg = programEvent2trg(evType);
            
            // SR_SET
            cregs.excSavedIP = adr;
            cregs.excSavedStatus = cregs.currentStatus;

            cregs.currentStatus.excLevel |= 1;
            cregs.currentStatus.dbStep = 0;
            
            cregs.excSyndrome = evType;

            syncSysRegsFromCregs();
          
            coreState.target = trg;        
        endfunction

    
        function automatic void modifySysRegs(ref CpuState state, input Mword adr, input AbstractInstruction abs);            
            
            // SR_SET
            case (abs.def.o)
                O_error: begin
                    setExecState(PE_SYS_ERROR, adr);            
                end
                O_undef: begin
                    setExecState(PE_SYS_UNDEFINED_INSTRUCTION, adr);
                end
                O_call: begin
                    setExecState(PE_SYS_CALL, adr + 4);
                end
                O_dbcall: begin
                    setExecState(PE_SYS_DBCALL, adr + 4);
                end
                O_retE: begin
                    state.target = cregs.excSavedIP;
                    cregs.currentStatus = cregs.excSavedStatus;
                    syncSysRegsFromCregs();
                end
                O_retI: begin
                    state.target = cregs.intSavedIP;
                    cregs.currentStatus = cregs.intSavedStatus;
                    syncSysRegsFromCregs();
                end
                O_replay: begin
                    state.target = adr;
                end
                O_sync: begin
                    state.target = adr + 4;
                end
                O_send: begin
                    state.target = adr + 4;
                    setSending();
                end
                default: state.target = adr + 4;
            endcase
        endfunction



        function automatic void setSending();
            status.send = 1;
        endfunction


       function automatic logic catchFetchException(input Mword vadr, input Translation tr);
            ProgramEvent evt = PE_NONE;
       
            if (!virtualAddressValid(vadr))
                evt = PE_FETCH_INVALID_ADDRESS;
            else if (vadr % 4 !== 0)
                evt = PE_FETCH_UNALIGNED_ADDRESS;
            else if (!tr.present)
                evt = PE_FETCH_UNMAPPED_ADDRESS;
            else if (!tr.desc.canExec)
                evt = PE_FETCH_DISALLOWED_ACCESS;
            else if (!physicalAddressValid(tr.padr))
                evt = PE_FETCH_NONEXISTENT_ADDRESS;
            else if (!progMem.addressValid(tr.padr))
                evt = PE_FETCH_NONEXISTENT_ADDRESS;

            if (evt === PE_NONE) return 0;
            
            setExecState(evt, ip);
            syncStatusFromRegs();
            
            return 1;
        endfunction



        function automatic TMP_runInstruction(input Mword adr, input Word bits);
            AbstractInstruction ins = decodeAbstract(bits);
            processInstruction(adr, ins);
        endfunction


        function automatic void executeStep();
            Mword vadr = this.coreState.target;
            Translation tr = translateProgramAddress(vadr);

            this.ip = vadr;

            if (catchFetchException(vadr, tr)) return;
            else begin
                Word bits = progMem.fetch(tr.padr);
                TMP_runInstruction(vadr, bits);
            end
        endfunction 
        

        // Clear mem write and signals to send
        function automatic void drain();
            this.status.send = 0;
        endfunction


        function automatic void processInstruction(input Mword adr, input AbstractInstruction ins);
            logic dbStepOn = 0;
            FormatSpec fmtSpec = parsingMap[ins.def.f];
            Mword3 args = getArgs(this.coreState.intRegs, this.coreState.floatRegs, ins.sources, fmtSpec.typeSpec);
            MemoryWrite writeToDo = '{default: 0};

            this.ip = adr;
            this.coreState.target = adr + 4;
            
            if (!(isBranchIns(ins) || isMemIns(ins) || isSysIns(ins) || isLoadSysIns(ins)))
                performCalculation(adr, ins, args);
            
            if (isBranchIns(ins))
                performBranch(ins, adr, args);
            
            if (isMemIns(ins) || isLoadSysIns(ins)) begin
                logic exceptionFromMem = performMem(ins, args);
                if (!exceptionFromMem) writeToDo = getMemWrite(ins, args);
            end
            
            status.dbEventPending = cregs.currentStatus.dbStep; // Checking here because sys reg write may change it and that should take effect after "retirement" which is not yet 
            
            if (isSysIns(ins))
                performSys(adr, ins, args);
            
            if (writeToDo.active) begin
                case (writeToDo.size)
                    1: dataMem.writeByte(writeToDo.padr, Mbyte'(writeToDo.value));
                    4: dataMem.writeWord(writeToDo.padr, writeToDo.value);
                    default: $error("Wrong store size %d/ %p", adr, ins);
                endcase
            end
            
            //catchDbTrap();
            
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
                assert (!$isunknown(vals[1]) && !$isunknown(vals[2])) else $error("Writing unknown!");
                if (catchSysAccessException(ins, vals[1])) return;
                
                writeSysReg(coreState, vals[1], vals[2]);
                
                syncCregsFromSysRegs();

                syncStatusFromRegs();
            end
            else begin
                modifySysRegs(coreState, adr, ins);
                syncStatusFromRegs();
            end
            
        endfunction
        
        // Return 1 if exception
        local function automatic logic performMem(input AbstractInstruction ins, input Mword3 vals);
            Mword vadr = calculateEffectiveAddress(ins, vals);
            Dword padr = 'x;

            if (isLoadSysIns(ins)) begin
                if (catchSysAccessException(ins, vadr)) return 1;
            end
            else begin
                Translation tr = translateDataAddress(vadr);
                padr = tr.padr;
                
                if (catchMemAccessException(ins, vadr, tr)) return 1;
            end
            
            begin
                Mword result = getLoadValue(ins, vadr, padr);
                if (!isLoadIns(ins)) return 0;
                if (hasFloatDest(ins)) writeFloatReg(this.coreState, ins.dest, result);
                if (hasIntDest(ins)) writeIntReg(this.coreState, ins.dest, result);
            end
            
            return 0;
        endfunction

        
        local function automatic MemoryWrite getMemWrite(input AbstractInstruction ins, input Mword3 vals);
            MemoryWrite res = DEFAULT_MEM_WRITE;
            Mword effAdr = calculateEffectiveAddress(ins, vals);            
            Translation tr = translateDataAddress(effAdr);
            logic en = 1;
            int size = -1;

            case (ins.def.o)
                //O_intStoreD: size = 8;
                O_intStoreW: size = 4;
                O_intStoreRelW: size = 4;
                O_intStoreB: size = 1;
                O_floatStoreW: size = 4;
                default: ;
            endcase
            
            if (isStoreMemIns(ins)) res = '{en, effAdr, tr.padr, vals[2], size};
            return res;
        endfunction


        local function automatic logic catchSysAccessException(input AbstractInstruction ins, input Mword adr);
            ProgramEvent evt = PE_NONE;
            
            if (ins.def.o == O_sysLoad && !isValidSysReg(adr))
                evt = PE_SYS_INVALID_ADDRESS;
            else if (ins.def.o == O_sysStore && !isValidSysReg(adr))
                evt = PE_SYS_INVALID_ADDRESS;
            
            if (evt === PE_NONE) return 0;

            setExecState(evt, ip);
            syncStatusFromRegs();
            
            return 1;
        endfunction

        local function automatic logic catchMemAccessException(input AbstractInstruction ins, input Mword vadr, Translation tr);
            ProgramEvent evt = PE_NONE;

            // PE_MEM_INVALID_ADDRESS = 3*16 + 0,
            if (!virtualAddressValid(vadr))
                evt = PE_MEM_INVALID_ADDRESS;
            
            // PE_MEM_UNMAPPED_ADDRESS = 3*16 + 3,
            else if (!tr.present)
                evt = PE_MEM_UNMAPPED_ADDRESS;     

            // PE_MEM_DISALLOWED_ACCESS = 3*16 + 4,
            else if (!tr.desc.canRead) // TEMPORARY; need to discern reads and writes
                evt = PE_MEM_DISALLOWED_ACCESS;
                
            // PE_MEM_NONEXISTENT_ADDRESS = 3*16 + 7,
            else if (!physicalAddressValid(tr.padr))
                evt = PE_MEM_NONEXISTENT_ADDRESS;

            if (evt === PE_NONE) return 0;
            
            setExecState(evt, ip);
            syncStatusFromRegs();

            return 1;
        endfunction


        function automatic logic catchDbTrap();
            if (!status.dbEventPending) return 0;

            status.dbEventPending = 0;

            performAsyncEvent(/*IP_DB_BREAK,*/ PE_EXT_DEBUG, this.coreState.target);
            syncStatusFromRegs();
            return 1;
        endfunction


        function automatic void interrupt();
            performAsyncEvent(/*IP_INT,*/ PE_EXT_INTERRUPT, this.coreState.target);
            
            syncStatusFromRegs();
        endfunction

        function automatic void resetSignal();
            performAsyncEvent(/*IP_RESET,*/ PE_EXT_RESET, this.coreState.target);
            
            syncStatusFromRegs();
        endfunction        


        function automatic string getBasicDbView();
            Mword adr, beginAdr;
            int firstReg = 0;

            // Show IP
            $display("ip = %016x (%d), target = %016x (%d)", ip, ip, coreState.target, coreState.target);

            $display("\nInteger registers");

            while (firstReg < 32) begin
                $display("[%02d] %016x [%02d] %016x [%02d] %016x [%02d] %016x",
                          firstReg+0, coreState.intRegs[firstReg+0], firstReg+1, coreState.intRegs[firstReg+1], firstReg+2, coreState.intRegs[firstReg+2], firstReg+3,coreState.intRegs[firstReg+3], );
                firstReg += 4;
            end

            $display("\nSys registers");

            firstReg = 0;
            while (firstReg < 6) begin
                $display("[%02d] %016x",
                          firstReg+0,
                          coreState.sysRegs[firstReg+0]);
                firstReg += 1;
            end           

            $display("\n");
            adr = coreState.sysRegs[2];

            // Show last 10 instructions including err address
            beginAdr = (adr < 10*4) ? 0 : adr - 10*4;

            for (int insAdr = beginAdr; insAdr <= adr; insAdr += 4) begin
                Translation tr = translateProgramAddress(Mword'(insAdr));
                Word iword = progMem.fetch(tr.padr);
                $display("%016x: %08x  %s", insAdr, iword, disasm(iword));
            end
            $display("                  ^^\n");
            
            return "";
        endfunction
        
        
        function automatic void DB_enableMmu();
            status.enableMmu = 1;
            status.memControl = 7;
        endfunction
        
        
        function automatic void initStatus(input CoreStatus cs);
            status = cs;
            syncRegsFromStatus();
            syncCregsFromSysRegs();
        endfunction
        
    endclass



    function automatic void runInEmulator(ref Emulator emul, input Mword adr, input Word bits);
        emul.TMP_runInstruction(adr, bits);
    endfunction

endpackage
