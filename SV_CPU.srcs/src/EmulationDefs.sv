
package EmulationDefs;
    import Base::*;
    import InsDefs::*;
    import Asm::*;


    localparam int V_INDEX_BITS = 12;


    //                            byte:  7766554433221100    
    localparam Mword VADR_LIMIT_LOW =  'h0001000000000000;  // 48b range 
    localparam Mword VADR_LIMIT_HIGH = 'hffff000000000000;

    localparam Dword PADR_LIMIT = 'h10000000000; // 40b range 


    // Architectural defs:
    typedef enum {
        PE_NONE = 0,
        
        PE_FETCH_INVALID_ADDRESS = 16 + 0,
        PE_FETCH_UNALIGNED_ADDRESS = 16 + 1,
        PE_FETCH_TLB_MISS = 16 + 2, // HW
        PE_FETCH_UNMAPPED_ADDRESS = 16 + 3,
        PE_FETCH_DISALLOWED_ACCESS = 16 + 4,
        PE_FETCH_UNCACHED = 16 + 5, // HW
        PE_FETCH_CACHE_MISS = 16 + 6, // HW
        PE_FETCH_NONEXISTENT_ADDRESS = 16 + 7,

        PE_MEM_INVALID_ADDRESS = 3*16 + 0,
        PE_MEM_UNALIGNED_ADDRESS = 3*16 + 1, // when crossing blocks/pages
        PE_MEM_TLB_MISS = 3*16 + 2, // HW
        PE_MEM_UNMAPPED_ADDRESS = 3*16 + 3,
        PE_MEM_DISALLOWED_ACCESS = 3*16 + 4,
        PE_MEM_UNCACHED = 3*16 + 5, // HW
        PE_MEM_CACHE_MISS = 3*16 + 6, // HW
        PE_MEM_NONEXISTENT_ADDRESS = 3*16 + 7,
        
        PE_SYS_INVALID_ADDRESS = 5*16 + 0,
        PE_SYS_DISALLOWED_ACCESS = 5*16 + 1,
        PE_SYS_UNDEFINED_INSTRUCTION = 5*16 + 2,
        PE_SYS_ERROR = 5*16 + 3,
        PE_SYS_CALL = 5*16 + 4,
        PE_SYS_DISABLED_INSTRUCTION = 5*16 + 5, // FP op when SIMD off, etc
            PE_SYS_DBCALL = 5*16 + 6,

        PE_EXT_INTERRUPT = 6*16 + 0,
        PE_EXT_RESET = 6*16 + 1,
        PE_EXT_DEBUG = 6*16 + 2

    } ProgramEvent;


    function automatic Mword programEvent2trg(input ProgramEvent evType);
        case (evType) inside
            [PE_FETCH_INVALID_ADDRESS : PE_FETCH_NONEXISTENT_ADDRESS]:
                return IP_FETCH_EXC;
            [PE_MEM_INVALID_ADDRESS : PE_MEM_NONEXISTENT_ADDRESS]:
                return IP_MEM_EXC;
                
            PE_SYS_INVALID_ADDRESS:
                return IP_EXC;
            
            PE_SYS_ERROR, PE_SYS_UNDEFINED_INSTRUCTION:
                return IP_ERROR;
            
            PE_SYS_CALL:
                return IP_CALL;

            PE_SYS_DBCALL:
                return IP_DB_CALL;


            PE_EXT_DEBUG:
                return IP_DB_BREAK;

            PE_EXT_INTERRUPT:
                return IP_INT;

            PE_EXT_RESET:
                return IP_RESET;
                
            default: return 'x;
        endcase
    endfunction


    /******
        SECTION = architectural definitions
    */

    function automatic logic isValidSysReg(Mword adr);
        return adr >= 0 && adr <= 31;    
    endfunction       


    // For fetch
    function automatic logic virtualAddressValid(input Mword vadr);
        return !$isunknown(vadr) && ($signed(vadr) < $signed(VADR_LIMIT_LOW)) && ($signed(vadr) >= $signed(VADR_LIMIT_HIGH));
    endfunction

    function automatic logic physicalAddressValid(input Dword padr);
        return !$isunknown(padr) && ($unsigned(padr) < $unsigned(PADR_LIMIT));
    endfunction


    function automatic Dword getPageBaseD(input Dword adr);
        Dword res = adr;
        res[V_INDEX_BITS-1:0] = 0;
        return res;
    endfunction

    function automatic Mword getPageBaseM(input Mword adr);
        Mword res = adr;
        res[V_INDEX_BITS-1:0] = 0;
        return res;
    endfunction

    /****
    *** END of section
    */



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


    
    // TODO: review functions below, their functionality may be implemented in uop defs 

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
        return ins.def.o inside {O_undef,   O_error,  O_call,  O_dbcall, O_sync, O_retE, O_retI, O_replay, O_halt, O_send,     O_sysStore};
    endfunction

    function automatic logic isStaticEventIns(input AbstractInstruction ins); // excluding sys load
        return ins.def.o inside {O_undef,   O_error,  O_call,  O_dbcall, O_sync, O_retE, O_retI, O_replay, O_halt, O_send};
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
            O_floatMulInt, O_floatDivInt,
            O_floatGenInv, O_floatGenOv,
            
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
            O_intAddH: begin
                //$error("addh with %x", vals[1]);
                result = vals[0] + (vals[1] << 16);
            end
            
                O_intCmpGtU:  result = $unsigned(vals[0]) > $unsigned(vals[1]);
                O_intCmpGtS:  result = $signed(vals[0]) > $signed(vals[1]);
            
            O_intMul:   result = w2m( multiplyW(vals[0], vals[1]) ); 
                                // vals[0] * vals[1];
            O_intMulHU: result = w2m( multiplyHighUnsignedW(vals[0], vals[1]) );
                                //(Dword'($unsigned(vals[0])) * Dword'($unsigned(vals[1]))) >> 32;
            O_intMulHS: result = w2m( multiplyHighSignedW(vals[0], vals[1]) );
                                //(Dword'($signed(vals[0])) * Dword'($signed(vals[1]))) >> 32;
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

            O_floatOr:   result = vals[0] | vals[1];
            O_floatAddInt: result = vals[0] + vals[1];
                O_floatMulInt: result = vals[0] * vals[1];
                O_floatDivInt: result = vals[0] / vals[1];
                O_floatGenInv: result = 1;
                O_floatGenOv: result = 1;

            default: $fatal(2, "Unknown operation %p", ins.def.o);
        endcase
        
        // Some operations may have undefined cases but must not cause problems for the CPU
        if ((ins.def.o inside {O_intDivU, O_intDivS, O_intRemU, O_intRemS}) && $isunknown(result)) result = -1;
        
        return result;
    endfunction


    function automatic Mword calculateEffectiveAddress(input AbstractInstruction ins, input Mword3 vals);
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
        logic dbEventPending;
        logic arithException;
        
        ProgramEvent eventType;
        
        logic enableMmu;
        Mword memControl;

    } CoreStatus;

    localparam CoreStatus DEFAULT_CORE_STATUS = '{eventType: PE_NONE, default: 0};


endpackage
