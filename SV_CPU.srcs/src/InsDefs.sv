
package Base;

    typedef logic[7:0]  Mbyte;
    typedef logic[31:0] Word;
    typedef logic[63:0] Dword;

    typedef Word Word3[3];
    typedef Word Word4[4];

    typedef logic logic3[3];


    function automatic Word divSignedW(input Word a, input Word b);
        Word rInt;// = (b == 0) ? 'hffffffff : $signed(a)/$signed(b);
        Word rem;// = a - rInt * b;
        
        if (b == 0) rInt = 'x;
        else rInt = $signed(a)/$signed(b);
        
        rem = a - rInt * b;
        
          //  $display("   ----   %p / %p -> %p",a ,b, rInt);
        
        if ($signed(rem) < 0 && $signed(b) > 0) rInt--;
        if ($signed(rem) > 0 && $signed(b) < 0) rInt--;
        
        return rInt;
    endfunction
    
    function automatic Word remSignedW(input Word a, input Word b);
        Word rInt; // = b == 0 ? 'hffffffff : $signed(a)/$signed(b);
        Word rem;// = a - rInt * b;
        
        if (b == 0) rInt = 'x;
        else rInt = $signed(a)/$signed(b);
        
        rem = a - rInt * b;
        
        if ($signed(rem) < 0 && $signed(b) > 0) rem += b;
        if ($signed(rem) > 0 && $signed(b) < 0) rem += b;
        
        return rem;
    endfunction



    function automatic Word divUnsignedW(input Word a, input Word b);
        Word rInt;// = (b == 0) ? 'hffffffff : $signed(a)/$signed(b);
        Word rem;// = a - rInt * b;
        
        if (b == 0) rInt = 'x;
        else rInt = $unsigned(a)/$unsigned(b);
        
        rem = a - rInt * b;
        
          //  $display("   ----   %p / %p -> %p",a ,b, rInt);
        
//        if ($unsigned(rem) < 0 && $unsigned(b) > 0) rInt--;
//        if ($unsigned(rem) > 0 && $unsigned(b) < 0) rInt--;
        
        return rInt;
    endfunction
    
    function automatic Word remUnsignedW(input Word a, input Word b);
        Word rInt; // = b == 0 ? 'hffffffff : $signed(a)/$signed(b);
        Word rem;// = a - rInt * b;
        
        if (b == 0) rInt = 'x;
        else rInt = $unsigned(a)/$unsigned(b);
        
        rem = a - rInt * b;
        
//        if ($signed(rem) < 0 && $signed(b) > 0) rem += b;
//        if ($signed(rem) > 0 && $signed(b) < 0) rem += b;
        
        return rem;
    endfunction

endpackage


package InsDefs;

    import Base::*;

    typedef Word Mword;
    //typedef Dword Mword;

    typedef Mword Mword3[3];
    typedef Mword Mword4[4];

    localparam int PAGE_SIZE = 4096;

        localparam Mword HANDLER_BASE = 2*PAGE_SIZE; // TMP

    // Handler addresses
    localparam Mword IP_ERROR     = HANDLER_BASE + 'h000100;
    localparam Mword IP_CALL      = HANDLER_BASE + 'h00000180;
    localparam Mword IP_RESET     = HANDLER_BASE + 'h00000200;
    localparam Mword IP_INT       = HANDLER_BASE + 'h00000280;
    localparam Mword IP_EXC       = HANDLER_BASE + 'h00000300;
    localparam Mword IP_FETCH_EXC = HANDLER_BASE + 'h00000380;
    localparam Mword IP_MEM_EXC   = HANDLER_BASE + 'h00000400;



    class MnemonicClass;
        typedef 
        enum {
            // set, mov, clr, nop, -- pseudoinstructions

            and_r,
            or_r,
            xor_r,

            add_i,
            add_h,
            add_r,
            sub_r,

                cgt_u, cgt_s,

            shl_i, shl_r, //-- direction defined by shift value, not opcode 
            sha_i, sha_r, //--   
            rot_i, rot_r,

            mult, 
            mulh_s, mulh_u,
            div_s, div_u,
            rem_s, rem_u,

            mov_f,
            or_f, addi_f,  // -- Float operations

            ldi_i, ldi_r, //-- int
            sti_i, sti_r,

                e_lb,
                e_sb,

            ldf_i, ldf_r, //-- float
            stf_i, stf_r, 

            lds, //-- load sys

            sts, //-- store sys

            jz_i, jz_r, jnz_i, jnz_r,
            ja, jl, //-- jump always, jump link


            sys_rete,
            sys_reti,
            sys_halt,
            sys_sync,
            sys_replay,
            sys_error,
            sys_call,
            sys_send,

            undef
        } Mnemonic;
    endclass;

    typedef MnemonicClass::Mnemonic Mnemonic;

    typedef enum {
        F_none,
        F_noRegs,
        F_jumpLong, F_jumpLink, F_jumpCond,
        F_intImm16, F_intImm10,
        F_intStore16, F_intStore10, F_floatLoad10, F_floatLoad16, F_floatStore10, F_floatStore16,
        F_sysLoad, F_sysStore,
        F_int1R, F_int2R, F_int3R, 
        F_float1R, F_float2R, F_float3R,
        F_floatToInt, F_intToFloat
    } InstructionFormat;


    typedef enum {
        P_intAlu = 0,
        P_floatOp = 1,
        P_intMem = 2,
        P_floatMem = 3,
        P_sysMem = 4,
        P_intAluImm = 5,
        
        P_sysControl = 7,

        P_ja = 8,
        P_jl = 9,
        P_jz = 10,
        P_jnz = 11,
 
        P_addI = 16,
        P_addH = 17, 
        
        P_intLoadW16 = 20,
        P_intStoreW16 = 21,
        P_floatLoadW16 = 22,
        P_floatStoreW16 = 23,
            
            P_intLoadB16 = 24,
            P_intStoreB16 = 25,

            P_intLoadAqW16 = 26,
            P_intStoreRelW16 = 27,

        P_none = -1
    } Primary;

    typedef enum {
        // P_intAlu          
        S_intLogic = 64*P_intAlu + 0,
        S_intArith = 64*P_intAlu + 1,
        S_jumpReg  = 64*P_intAlu + 2,
        S_intMul   = 64*P_intAlu + 3,
         
        // P_intAluImm
        S_intShiftLogical = 64*P_intAluImm + 0,
        S_intShiftArith   = 64*P_intAluImm + 1,
        S_intRotate       = 64*P_intAluImm + 2,
         
        // P_floatOp
        S_floatMove   = 64*P_floatOp + 0,
        S_floatArith  = 64*P_floatOp + 1,
         
        // P_intMem
        //S_intLoadW,
        //S_intStoreW,
         
        // P_floatMem
        //S_floatLoadW,
        //S_floatStoreW,
         
        // P_sysMem
        S_sysLoad   = 64*P_sysMem + 0,
        S_sysStore  = 64*P_sysMem + 32,
         
        // P_sysControl                 
        S_sysUndef   = 64*P_sysControl + 0,
        S_sysError   = 64*P_sysControl + 1,
        S_sysCall    = 64*P_sysControl + 2,
        S_sysSync    = 64*P_sysControl + 3,
        S_sysReplay  = 64*P_sysControl + 4,
        S_sysHalt    = 64*P_sysControl + 5,
        S_sysSend    = 64*P_sysControl + 6,
        S_sysRetE    = 64*P_sysControl + 7,
        S_sysRetI    = 64*P_sysControl + 8,
           
        S_none = -1               
    } Secondary;


    typedef enum {
        T_intAnd   = 32*S_intLogic + 0,
        T_intOr    = 32*S_intLogic + 1,
        T_intXor   = 32*S_intLogic + 2,

        T_intAdd   = 32*S_intArith + 0,
        T_intSub   = 32*S_intArith + 1,

            T_intCmpGtU = 32*S_intArith + 2,
            T_intCmpGtS = 32*S_intArith + 3,

        T_intMul   = 32*S_intMul + 0,
        T_intMulHU = 32*S_intMul + 1,
        T_intMulHS = 32*S_intMul + 2,
        T_intDivU  = 32*S_intMul + 8,
        T_intDivS  = 32*S_intMul + 9,
        T_intRemU  = 32*S_intMul + 10,
        T_intRemS  = 32*S_intMul + 11,

        T_floatMove = 32*S_floatMove + 0,

        T_floatOr     = 32*S_floatArith + 0,
        T_floatAddInt = 32*S_floatArith + 1,


        T_jumpRegZ  = 32*S_jumpReg + 0,
        T_jumpRegNZ = 32*S_jumpReg + 1,

        T_none = -1

    } Ternary;


    function automatic Primary toPrimary(input int n);
        Primary p;
        p = p.first();
        
        forever begin
            if (p == n) return p; 
            
            if (p == p.last()) break;
            p = p.next();
        end
        
        return P_none;
    endfunction;

    function automatic Secondary toSecondary(input int n, input Primary p);
        Secondary s;
        s = s.first();
        
        forever begin
            if (s == 64*p + n) return s; 
            
            if (s == s.last()) break;
            s = s.next();
        end
        
        return S_none;
     endfunction;
    
    function automatic Ternary toTernary(input int n, input Primary p, input Secondary s);
        Ternary t;
        t = t.first();
        
        forever begin
            if (t == 32*s + n) return t;
            if (t == t.last()) break;
            t = t.next();
        end
        
        return T_none;
    endfunction;


    typedef enum {
        O_undef,
        O_call,
        O_sync,
        O_retE,
        O_retI,
        O_replay,
        O_error,
        O_halt,
        O_send,
        
        O_jump,
        
        O_intAnd, O_intOr, O_intXor,
        O_intAdd, O_intSub,
        O_intAddH,
            O_intCmpGtU, O_intCmpGtS,
        
        O_intMul, O_intMulHU, O_intMulHS,
        O_intDivU, O_intDivS,
        O_intRemU, O_intRemS,
        
        O_intShiftLogical, O_intShiftArith, O_intRotate,
        
        O_floatMove,

        O_floatOr,
        O_floatAddInt,
        
        O_intLoadW, O_intLoadD,
        O_intStoreW, O_intStoreD,
        O_floatLoadW, O_floatStoreW,
        
            O_intLoadB, O_intStoreB,
            O_intLoadAqW, O_intStoreRelW,
        
        O_sysLoad, O_sysStore
    } Operation;


    typedef struct {
        InstructionFormat f;
        Primary p;
        Secondary s;
        Ternary t;
        Operation o;
    } InstructionDef;


    const InstructionDef defMap[string] = '{
        "undef":      '{F_none,  P_none, S_none, T_none, O_undef},
    
        "and_r":      '{F_int2R, P_intAlu, S_intLogic, T_intAnd, O_intAnd}, //int2R,
        "or_r":       '{F_int2R, P_intAlu, S_intLogic, T_intOr, O_intOr}, //int2R,
        "xor_r":      '{F_int2R, P_intAlu, S_intLogic, T_intXor, O_intXor}, //int2R,
        
        "add_i":      '{F_intImm16, P_addI, S_none, T_none, O_intAdd},//intImm16,
        "add_h":      '{F_intImm16, P_addH, S_none, T_none, O_intAddH},//intImm16,
        "add_r":      '{F_int2R, P_intAlu, S_intArith, T_intAdd, O_intAdd},//int2R,
        "sub_r":      '{F_int2R, P_intAlu, S_intArith, T_intSub, O_intSub},//int2R,
            "cgt_u":  '{F_int2R, P_intAlu, S_intArith, T_intCmpGtU, O_intCmpGtU},//int2R,
            "cgt_s":  '{F_int2R, P_intAlu, S_intArith, T_intCmpGtS, O_intCmpGtS},//int2R,
                
        "shl_i":      '{F_intImm10, P_intAluImm, S_intShiftLogical, T_none, O_intShiftLogical},//intImm10, 
        "sha_i":      '{F_intImm10, P_intAluImm, S_intShiftArith, T_none, O_intShiftArith},//intImm10, 
        "rot_i":      '{F_intImm10, P_intAluImm, S_intRotate, T_none, O_intRotate},//intImm10, 
        
        "mult":       '{F_int2R, P_intAlu, S_intMul, T_intMul, O_intMul},//int2R, 
        "mulh_s":     '{F_int2R, P_intAlu, S_intMul, T_intMulHU, O_intMulHS},//int2R, 
        "mulh_u":     '{F_int2R, P_intAlu, S_intMul, T_intMulHS, O_intMulHU},//int2R, 
        "div_s":      '{F_int2R, P_intAlu, S_intMul, T_intDivS, O_intDivS},//int2R, 
        "div_u":      '{F_int2R, P_intAlu, S_intMul, T_intDivU, O_intDivU},//int2R, 
        "rem_s":      '{F_int2R, P_intAlu, S_intMul, T_intRemS, O_intRemS},//int2R, 
        "rem_u":      '{F_int2R, P_intAlu, S_intMul, T_intRemU, O_intRemU},//int2R, 
        
        "mov_f":      '{F_float1R, P_floatOp, S_floatMove, T_floatMove, O_floatMove},//float1R,
        "or_f":       '{F_float2R, P_floatOp, S_floatArith, T_floatOr, O_floatOr},  // -- Float operations
        "addi_f":     '{F_float2R, P_floatOp, S_floatArith, T_floatAddInt, O_floatAddInt},  // -- Float operations
        
        "ldi_i":      '{F_intImm16,   P_intLoadW16,  S_none, T_none, O_intLoadW},//intImm16,
        "sti_i":      '{F_intStore16, P_intStoreW16, S_none, T_none, O_intStoreW},//intStore16,
        
        "ldf_i":      '{F_floatLoad16,  P_floatLoadW16,  S_none, T_none, O_floatLoadW},//floatLoad16,
        "stf_i":      '{F_floatStore16, P_floatStoreW16,  S_none, T_none, O_floatStoreW},//floatStore16,

            "e_lb":    '{F_intImm16,   P_intLoadB16, S_none, T_none, O_intLoadB},//IntImm16
            "e_sb":    '{F_intStore16, P_intStoreB16, S_none, T_none, O_intStoreB},//IntImm16

            "e_ldaq":  '{F_intImm16, P_intLoadAqW16, S_none, T_none, O_intLoadAqW},//IntImm16
            "e_strel": '{F_intImm16, P_intStoreRelW16, S_none, T_none, O_intStoreRelW},//IntImm16                           
        
        "lds":        '{F_sysLoad,  P_sysMem,  S_sysLoad, T_none, O_sysLoad},//sysLoad, //-- load sys
        "sts":        '{F_sysStore, P_sysMem,  S_sysStore, T_none, O_sysStore},//sysStore, //-- store sys
        
        "jz_i":       '{F_jumpCond, P_jz, S_none, T_none, O_jump},//jumpCond,
        "jz_r":       '{F_int2R, P_intAlu, S_jumpReg, T_jumpRegZ, O_jump},//int2R,
        "jnz_i":      '{F_jumpCond, P_jnz, S_none, T_none, O_jump},//jumpCond,
        "jnz_r":      '{F_int2R, P_intAlu, S_jumpReg, T_jumpRegNZ, O_jump},//int2R,
        "ja":         '{F_jumpLong, P_ja, S_none, T_none, O_jump},//,//jumpLong,
        "jl":         '{F_jumpLink, P_jl, S_none, T_none, O_jump},//jumpLink, //-- jump always, jump link
        
        "sys_rete":   '{F_noRegs, P_sysControl, S_sysRetE, T_none, O_retE},
        "sys_reti":   '{F_noRegs, P_sysControl, S_sysRetI, T_none, O_retI},
        "sys_halt":   '{F_noRegs, P_sysControl, S_sysHalt, T_none, O_halt},
        "sys_sync":   '{F_noRegs, P_sysControl, S_sysSync, T_none, O_sync},
        "sys_replay": '{F_noRegs, P_sysControl, S_sysReplay, T_none, O_replay},
        "sys_error":  '{F_noRegs, P_sysControl, S_sysError, T_none, O_error},
        "sys_call":   '{F_noRegs, P_sysControl, S_sysCall, T_none, O_call},
        "sys_send":   '{F_noRegs, P_sysControl, S_sysSend, T_none, O_send}
        
    };


    typedef struct {
        string asmForm;
        string decoding;
        string typeSpec;
    } FormatSpec;

    const FormatSpec parsingMap[InstructionFormat] = '{
        F_none:          '{"    ", "0,000", "0,000"},
    
        F_noRegs :       '{"    ", "0,000", "0,000"},
    
        F_jumpLong :     '{"1   ", "0,0L0", "i,ic0"},
        F_jumpLink :     '{"d1  ", "a,0J0", "i,ic0"},
        F_jumpCond :     '{"01  ", "0,aJ0", "i,ic0"},
        
        F_intImm16 :     '{"d01 ", "a,bH0", "i,ic0"},
        F_intImm10 :     '{"d01 ", "a,bX0", "i,ic0"},
        
        F_intStore16 :   '{"201 ", "0,bHa", "i,ici"},
        F_intStore10 :   '{"201 ", "0,bXa", "i,ici"},
        
        F_floatLoad16 :  '{"d01 ", "a,bH0", "f,ic0"},
        F_floatLoad10 :  '{"d01 ", "a,bX0", "f,ic0"},
        
        F_floatStore16 : '{"201 ", "0,bHa", "i,icf"},
        F_floatStore10 : '{"201 ", "0,bXa", "i,icf"},
    
        F_sysLoad :      '{"d01 ", "a,bX0", "i,ic0"},

        F_sysStore :     '{"201 ", "0,bXa", "0,ici"},
    
        F_int3R :        '{"d012", "a,bcd", "i,iii"},
        F_int2R :        '{"d01 ", "a,bc0", "i,ii0"},
        F_int1R :        '{"d0  ", "a,b00", "i,i00"},
    
        F_float3R :      '{"d012", "a,bcd", "f,fff"},
        F_float2R :      '{"d01 ", "a,bc0", "f,ff0"},
        F_float1R :      '{"d0  ", "a,b00", "f,f00"},
        
        F_floatToInt :   '{"d0  ", "a,b00", "i,f00"},
        F_intToFloat :   '{"d0  ", "a,b00", "f,i00"}
    };


    function automatic logic matchDefinition(input InstructionDef pattern, candidate);
        return (candidate.p == pattern.p) && (candidate.s inside {S_none, pattern.s}) && (candidate.t inside {T_none, pattern.t});
    endfunction

    function automatic InstructionDef getDef(input string s);
        Mnemonic m;
        for (Mnemonic mi = m.first(); 1; mi = mi.next()) begin
            if (s == mi.name()) return defMap[s];
            if (mi == mi.last()) return '{F_none, P_none, S_none, T_none, O_undef};
        end  
    endfunction

    function automatic string findMnemonic(input InstructionDef def);
        string found[$] = defMap.find_first_index with (matchDefinition(def, item));
        
        if (found.size() == 0) return "undef";        
        assert (found.size() == 1) else $fatal("No single definition for %p, %d", def, found.size());

        return found[0];               
    endfunction


/*
    System registers
    
    0: device ID (readonly)
    1: status (RW)
    2: exception adr
    3: interrupt adr
    4: exc saved status
    5: int saved status
    6: syndrome?
    7: exc mem access
    8: 
    9: FP status
    a: mem control
    b: page table base 0
    c: page table base 1
    d: 
    e:
    f: 
    
*/

/*
    needed:
      Registers:
        page table base
        ?(page table base user)
        ?(page table base kernel)
        timer .....
        syndrome (different regs for exc/int/db?)
        mem adr (address where mem instruction tried to do something wrong)
        
      Fields: (# denotes params not in status reg)
        privilege level
        (interrupt level?)
        int mask
        #mmu enable
        #cache enable (different ones?)
        step mode
        (other db flags: adr breakpoint, data breakpoint?)
        FP enable (other ISA subset enables?)

      Notes:
        In User mode MMU must not be disabled
        Access to any sys reg is forbidden in user mode?
            !!What about FP control?
        Returns (retE, retI, ...?) are special because they transfer the value of some specified register to status reg
          This reg holds: privilege level, step mode?, int mask?, FP enable?
          Those fields are a subset of state that needs to be changed on typical task switches (and can fit in a single register)
          MMU enable and cache enable are not in it - they are disabled on reset, and after setup they are expected to be on. We don't have user processes without MMU or caching 
          The fields in status reg are conceptually modified at the same time when either an event (exception, int, syscall, dbcall) happens or a return happens
        Registers are either readonly or RW 


        Status reg fields:
                privilege level - 2/3 bits?
                int level       - 2/3 bits?
            OR:
               priv level: 4b [3] - 1000 interrupt?, 0001 - SV, 0000 - user
            int mask level  - 4 bits?
            dbstep - 1 b
            FP en - 1 b
        
        Status reg layout:
        ... 31 | 30 | 29 | 28 | 27 | 26 | 25 | 24 | 23 | 22 | 21 | 20 | 19 | 18 | 17 | 16 | 15 | 14 | 13 | 12 | 11 | 10 | 09 | 08 | 07 | 06 | 05 | 04 | 03 | 02 | 01 | 00 |
        
        
        Mem control reg:
            MMU en
            icache en
            cache en
        
            DEV: bits 2:0 either 000 - physical uncached mode or 111 - virtual cached mode
        
        FP status reg:
        
        
*/



endpackage
