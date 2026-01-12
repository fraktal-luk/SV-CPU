
// Definitions needed for emulation and analysis of processor state, independent of implementation

package EmulationDefs;
    import Base::*;
    import InsDefs::*;
    import Asm::*;


    typedef struct {
        logic allowed;
        logic canRead;
        logic canWrite;
        logic canExec;
        logic cached;
    } DataLineDesc;

    localparam DataLineDesc DEFAULT_DATA_LINE_DESC = '{0, 0, 0, 0, 0};


    typedef struct {
        logic present; // TLB hit
        Mword vadr;
        DataLineDesc desc;
        Dword padr;
    } Translation;

    localparam Translation DEFAULT_TRANSLATION = '{
        present: 0,
        vadr: 'x,
        desc: DEFAULT_DATA_LINE_DESC,
        padr: 'x
    };


    // Not including memory
//    function automatic logic isFloatCalcIns(input AbstractInstruction ins);
//        return ins.def.o inside { O_floatMove, O_floatOr, O_floatAddInt };
//    endfunction    

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
        return ins.def.o inside {
                O_intLoadW, O_intLoadD, O_intStoreW, O_intStoreD,
                O_floatLoadW, O_floatStoreW,  O_intLoadB,  O_intStoreB, 
                O_intLoadAqW, O_intStoreRelW,

                O_mbLoadB, O_mbLoadF, O_mbLoadBF, O_mbStoreB, O_mbStoreF, O_mbStoreBF
                };
    endfunction

    function automatic logic isMemBarrierIns(input AbstractInstruction ins);
        return ins.def.o inside {
                O_mbLoadB, O_mbLoadF, O_mbLoadBF, O_mbStoreB, O_mbStoreF, O_mbStoreBF,    O_intLoadAqW
                };
    endfunction

    function automatic logic isMemBarrierFwIns(input AbstractInstruction ins);
        return ins.def.o inside {
                    O_mbLoadF, O_mbLoadBF, O_mbStoreF, O_mbStoreBF,         O_intLoadAqW
                };
    endfunction

    function automatic logic isSysIns(input AbstractInstruction ins); // excluding sys load
        return ins.def.o inside {O_fetchError,  O_undef,   O_error,  O_call,  O_dbcall, O_sync, O_retE, O_retI, O_replay, O_halt, O_send,     O_sysStore};
    endfunction

    function automatic logic isStaticEventIns(input AbstractInstruction ins); // excluding sys load
        return ins.def.o inside {O_fetchError,  O_undef,   O_error,  O_call,  O_dbcall, O_sync, O_retE, O_retI, O_replay, O_halt, O_send};
    endfunction

    function automatic logic isLoadIns(input AbstractInstruction ins);
        return isLoadMemIns(ins) || isLoadSysIns(ins);
    endfunction

    function automatic logic isLoadSysIns(input AbstractInstruction ins);
        return (ins.def.o inside {O_sysLoad});
    endfunction

    function automatic logic isLoadAqIns(input AbstractInstruction ins);
        return (ins.def.o inside {O_intLoadAqW});
    endfunction

    function automatic logic isLoadMemIns(input AbstractInstruction ins);
        return (ins.def.o inside {O_intLoadW, O_intLoadD, O_floatLoadW,    O_intLoadB,   O_intLoadAqW});
    endfunction

    function automatic logic isStoreMemIns(input AbstractInstruction ins);
        return ins.def.o inside {O_intStoreW, O_intStoreD, O_floatStoreW,    O_intStoreB,   O_intStoreRelW};
    endfunction

//    function automatic logic isFloatLoadMemIns(input AbstractInstruction ins);
//        return (ins.def.o inside {O_floatLoadW});
//    endfunction

//    function automatic logic isFloatStoreMemIns(input AbstractInstruction ins);
//        return ins.def.o inside {O_floatStoreW};
//    endfunction

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
            O_floatMulInt, O_floatDivInt,
            O_floatGenInv, O_floatGenOv,
                O_floatAdd32, O_floatSub32, O_floatMul32, O_floatDiv32, O_floatCmpEq32,O_floatCmpGe32, O_floatCmpGt32,
                O_floatAdd64, O_floatSub64, O_floatMul64, O_floatDiv64, O_floatCmpEq64,O_floatCmpGe64, O_floatCmpGt64,
                
            O_floatLoadW
        };
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
            O_intAnd:  result = vals[0] & vals[1];
            O_intOr:   result = vals[0] | vals[1];
            O_intXor:  result = vals[0] ^ vals[1];
            
            O_intAdd:  result = vals[0] + vals[1];
            O_intSub:  result = vals[0] - vals[1];
            O_intAddH: result = vals[0] + (vals[1] << 16);

            O_intCmpGtU:  result = $unsigned(vals[0]) > $unsigned(vals[1]);
            O_intCmpGtS:  result = $signed(vals[0]) > $signed(vals[1]);
            
            O_intMul:   result = w2m( multiplyW(vals[0], vals[1]) ); 
            O_intMulHU: result = w2m( multiplyHighUnsignedW(vals[0], vals[1]) );
            O_intMulHS: result = w2m( multiplyHighSignedW(vals[0], vals[1]) );
            O_intDivU:  result = w2m( divUnsignedW(vals[0], vals[1]) );
            O_intDivS:  result = w2m( divSignedW(vals[0], vals[1]) );
            O_intRemU:  result = w2m( remUnsignedW(vals[0], vals[1]) );
            O_intRemS:  result = w2m( remSignedW(vals[0], vals[1]) );
            
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

            O_floatXor:   result = vals[0] ^ vals[1];
            O_floatAnd:   result = vals[0] & vals[1];
            O_floatOr:   result = vals[0] | vals[1];
            O_floatAddInt: result = vals[0] + vals[1];
            O_floatMulInt: result = vals[0] * vals[1];
            O_floatDivInt: result = vals[0] / vals[1];
            O_floatGenInv: result = 1;
            O_floatGenOv: result = 1;
            O_floatAdd32: result = $shortrealtobits($bitstoshortreal((vals[0])) + $bitstoshortreal(vals[1]));
            O_floatSub32: result = $shortrealtobits($bitstoshortreal(vals[0]) - $bitstoshortreal(vals[1]));
            O_floatMul32: result = $shortrealtobits($bitstoshortreal(vals[0]) * $bitstoshortreal(vals[1]));
            O_floatDiv32: result = $shortrealtobits($bitstoshortreal(vals[0]) / $bitstoshortreal(vals[1]));
            O_floatCmpEq32: result = ($bitstoshortreal(vals[0]) == $bitstoshortreal(vals[1]));
            O_floatCmpGe32: result = ($bitstoshortreal(vals[0]) >= $bitstoshortreal(vals[1]));
            O_floatCmpGt32: result = ($bitstoshortreal(vals[0]) > $bitstoshortreal(vals[1]));

            default: $fatal(2, "Unknown operation %p", ins.def.o);
        endcase
        
        // Some operations may have undefined cases but must not cause problems for the CPU
        if ((ins.def.o inside {O_intDivU, O_intDivS, O_intRemU, O_intRemS}) && $isunknown(result)) result = -1;
        
        return result;
    endfunction


    function automatic Mword calculateEffectiveAddress(input AbstractInstruction ins, input Mword3 vals);
        if (isMemBarrierIns(ins) && !isLoadMemIns(ins)) return 'x;
        return (ins.def.o inside {O_sysLoad, O_sysStore}) ? vals[1] : vals[0] + vals[1];
    endfunction



    typedef struct {
       Mword target;
       logic redirect;
    } ExecEvent;

    function automatic ExecEvent resolveBranch(input AbstractInstruction abs, input Mword adr, input Mword3 vals);
        Mword3 args = vals;
        logic redirect = 0;
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


    typedef struct {
        logic send;
        logic exceptionRaised;
        logic dbEventPending;
        logic arithException;
        
        ProgramEvent eventType;        
    } CoreStatus;

    localparam CoreStatus DEFAULT_CORE_STATUS = '{eventType: PE_NONE, default: 0};

        function automatic AbstractInstruction decodeWithAddress(input Word bits, input Mword adr);    
            if (!physicalAddressValid(adr) || (adr % 4 != 0)) return FETCH_ERROR_INS;
            else return decodeAbstract(bits);
        endfunction




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


    function automatic void setStatusFromRegs(ref CoreStatus status, Mword sysRegs[32]);
        // syndrome
        status.eventType = ProgramEvent'(sysRegs[6]);
    endfunction


endpackage
