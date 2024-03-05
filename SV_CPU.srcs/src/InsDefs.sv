
package Base;

    typedef logic[31:0] Word;
    typedef logic[63:0] Dword;


    function automatic Word divSigned(input Word a, input Word b);
        Word aInt = a;
        Word bInt = b;
        Word rInt = $signed(a)/$signed(b);
        Word rem = aInt - rInt * bInt;
        
        if ($signed(rem) < 0 && $signed(bInt) > 0) rInt--;
        if ($signed(rem) > 0 && $signed(bInt) < 0) rInt--;
        
        return rInt;
    endfunction
    
    function automatic Word remSigned(input Word a, input Word b);
        Word aInt = a;
        Word bInt = b;
        Word rInt = $signed(a)/$signed(b);
        Word rem = aInt - rInt * bInt;
        
        if ($signed(rem) < 0 && $signed(bInt) > 0) rem += bInt;
        if ($signed(rem) > 0 && $signed(bInt) < 0) rem += bInt;
        
        return rem;
    endfunction

endpackage


package InsDefs;

    import Base::*;

    const Word IP_RESET = 'h00000200;
    const Word IP_ERROR = 'h00000100;
    const Word IP_CALL = 'h00000180;
    const Word IP_INT = 'h00000280;

    typedef string string3[3];
    typedef string string4[4];
    typedef Word Word3[3];
    typedef Word Word4[4];

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
            
            shl_i, shl_r, //-- direction defined by shift value, not opcode 
            sha_i, sha_r, //--   
            rot_i, rot_r,
            
            mult, 
            mulh_s, mulh_u,
            div_s, div_u,
            rem_s, rem_u,
            
            mov_f, or_f,   // -- Float operations
            
            ldi_i, ldi_r, //-- int
            sti_i, sti_r,
            
            ldf_i, ldf_r, //-- float
            stf_i, stf_r, 
            
            lds, //-- load sys
            
            sts, //-- store sys
            
            jz_i, jz_r, jnz_i, jnz_r,
            ja, jl, //-- jump always, jump link
            
            //sys, //-- system operation
            
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


    typedef enum {
        none,
        noRegs,
            jumpLong, jumpLink, jumpCond,
            intImm16, intImm10,
        intStore16, intStore10, floatLoad10, floatLoad16, floatStore10, floatStore16,
        sysLoad, sysStore,
            int1R, int2R, int3R, 
            float1R, float2R, float3R,
            floatToInt, intToFloat
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
        
        

        P_none = -1
    } Primary;



    typedef enum {
        
        // P_intAlu          
        S_intLogic = 0 + 64*P_intAlu,
        S_intArith = 1 + 64*P_intAlu,
        S_jumpReg = 2 + 64*P_intAlu,
        S_intMul = 3 + 64*P_intAlu,
         
        // P_intAluImm
        S_intShiftLogical = 0 + 64*P_intAluImm,
        S_intShiftArith   = 1 + 64*P_intAluImm,
        S_intRotate       = 2 + 64*P_intAluImm, 
         
        // P_floatOp
        S_floatMove  = 0 + 64*P_floatOp,
         
        // P_intMem
        //S_intLoadW,
        //S_intStoreW,
         
        // P_floatMem
        //S_floatLoadW,
        //S_floatStoreW,
         
        // P_sysMem
        S_sysLoad   = 0 + 64*P_sysMem,
        S_sysStore  = 32+ 64*P_sysMem,
         
        // P_sysControl                 
        S_sysUndef   = 0 + 64*P_sysControl,
        S_sysError = 1 + 64*P_sysControl,
        S_sysCall = 2 + 64*P_sysControl,
        S_sysSync = 3 + 64*P_sysControl,
        S_sysReplay = 4 + 64*P_sysControl,
        
        S_sysHalt  = 5 + 64*P_sysControl,
        S_sysSend = 6 + 64*P_sysControl,
        S_sysRetE = 7 + 64*P_sysControl,
        S_sysRetI = 8 + 64*P_sysControl,
           
        S_none = -1               
     } Secondary;



    typedef enum {
        T_intAnd = 0 + 32*S_intLogic,
        T_intOr  = 1 + 32*S_intLogic,
        T_intXor = 2 + 32*S_intLogic,
    
        T_intAdd = 0 + 32*S_intArith,
        T_intSub = 1 + 32*S_intArith,  
    
        T_intMul = 0 + 32*S_intMul,
        T_intMulHU = 1 + 32*S_intMul,
        T_intMulHS = 2 + 32*S_intMul,
        T_intDivU = 8 + 32*S_intMul,
        T_intDivS = 9 + 32*S_intMul,
        T_intRemU = 10 + 32*S_intMul,
        T_intRemS = 11 + 32*S_intMul,
    
        T_floatMove = 0  + 32*S_floatMove,
      
        T_jumpRegZ = 0  + 32*S_jumpReg,
        T_jumpRegNZ = 1  + 32*S_jumpReg,
        
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
        O_halt,
        O_send,
        
        O_jump,
        
        O_intAnd, O_intOr, O_intXor,
        O_intAdd, O_intSub,
        O_intAddH,
        O_intMul, O_intMulHU, O_intMulHS,
        O_intDivU, O_intDivS,
        O_intRemU, O_intRemS,
        
        O_intShiftLogical, O_intShiftArith, O_intRotate,
        
        O_floatMove,
        
        O_intLoadW, O_intLoadD,
        O_intStoreW, O_intStoreD,
        O_floatLoadW, O_floatStoreW,
        O_sysLoad, O_sysStore
    } Operation;


    typedef struct {
        Primary p;
        Secondary s;
        Ternary t;
        Operation o;
    } InstructionDef;


    typedef InstructionDef DefMap[string];
    
    const DefMap defMap = '{
        "undef": '{P_none, S_none, T_none, O_undef},
    
        "and_r":  '{P_intAlu, S_intLogic, T_intAnd, O_intAnd}, //int2R,
        "or_r":   '{P_intAlu, S_intLogic, T_intOr, O_intOr}, //int2R,
        "xor_r":  '{P_intAlu, S_intLogic, T_intXor, O_intXor}, //int2R,
        
        "add_i": '{P_addI, S_none, T_none, O_intAdd},//intImm16,
        "add_h": '{P_addH, S_none, T_none, O_intAddH},//intImm16,
        "add_r": '{P_intAlu, S_intArith, T_intAdd, O_intAdd},//int2R,
        "sub_r": '{P_intAlu, S_intArith, T_intSub, O_intSub},//int2R,
        
        "shl_i": '{P_intAluImm, S_intShiftLogical, T_none, O_intShiftLogical},//intImm10, 
        "sha_i": '{P_intAluImm, S_intShiftArith, T_none, O_intShiftArith},//intImm10, 
        "rot_i": '{P_intAluImm, S_intRotate, T_none, O_intRotate},//intImm10, 
        
        "mult":   '{P_intAlu, S_intMul, T_intMul, O_intMul},//int2R, 
        "mulh_s": '{P_intAlu, S_intMul, T_intMulHU, O_intMulHS},//int2R, 
        "mulh_u": '{P_intAlu, S_intMul, T_intMulHS, O_intMulHU},//int2R, 
        "div_s":  '{P_intAlu, S_intMul, T_intDivS, O_intDivS},//int2R, 
        "div_u":  '{P_intAlu, S_intMul, T_intDivU, O_intDivU},//int2R, 
        "rem_s":  '{P_intAlu, S_intMul, T_intRemS, O_intRemS},//int2R, 
        "rem_u":  '{P_intAlu, S_intMul, T_intRemU, O_intRemU},//int2R, 
        
        "mov_f":  '{P_floatOp, S_floatMove, T_floatMove, O_floatMove},//float1R,
//            "or_f": float2R,   // -- Float operations
        
        "ldi_i": '{P_intLoadW16,  S_none, T_none, O_intLoadW},//intImm16,
        "sti_i": '{P_intStoreW16, S_none, T_none, O_intStoreW},//intStore16,
        
        "ldf_i": '{P_floatLoadW16,  S_none, T_none, O_floatLoadW},//floatLoad16,
        "stf_i": '{P_floatStoreW16,  S_none, T_none, O_floatStoreW},//floatStore16,
//            //stf_r, 
        
        "lds": '{P_sysMem,  S_sysLoad, T_none, O_sysLoad},//sysLoad, //-- load sys
        "sts": '{P_sysMem,  S_sysStore, T_none, O_sysStore},//sysStore, //-- store sys
        
        "jz_i": '{P_jz, S_none, T_none, O_jump},//jumpCond,
        "jz_r": '{P_intAlu, S_jumpReg, T_jumpRegZ, O_jump},//int2R,
        "jnz_i": '{P_jnz, S_none, T_none, O_jump},//jumpCond,
        "jnz_r": '{P_intAlu, S_jumpReg, T_jumpRegNZ, O_jump},//int2R,
        "ja": '{P_ja, S_none, T_none, O_jump},//,//jumpLong,
        "jl": '{P_jl, S_none, T_none, O_jump},//jumpLink, //-- jump always, jump link
        
        "sys_rete": '{P_sysControl, S_sysRetE, T_none, O_retE},
        "sys_reti": '{P_sysControl, S_sysRetI, T_none, O_retI},
        "sys_halt": '{P_sysControl, S_sysHalt, T_none, O_halt},
        "sys_sync": '{P_sysControl, S_sysSync, T_none, O_sync},
        "sys_replay": '{P_sysControl, S_sysReplay, T_none, O_replay},
        "sys_error": '{P_sysControl, S_sysError, T_none, O_undef},
        "sys_call": '{P_sysControl, S_sysCall, T_none, O_call},
        "sys_send": '{P_sysControl, S_sysSend, T_none, O_send}
        
    };


    typedef InstructionFormat FormatMap[string];
    
    const FormatMap formatMap = '{
        "undef": none,
    
        "and_r": int2R,
        
        "or_r": int2R,
        "xor_r": int2R,
        
        "add_i": intImm16,
        "add_h": intImm16,
        "add_r": int2R,
        "sub_r": int2R,
        
        "shl_i": intImm10, 
        
        "sha_i": intImm10,
        
        "rot_i": intImm10, 
        "rot_r": int2R,
        
        "mult": int2R, 
        "mulh_s": int2R,
        "mulh_u": int2R,
        "div_s": int2R,
        "div_u": int2R,
        "rem_s": int2R,
        "rem_u": int2R,
        
        "mov_f": float1R,
        "or_f": float2R,   // -- Float operations
        
        "ldi_i": intImm16,
        "sti_i": intStore16,
        
        "ldf_i": floatLoad16,
        "stf_i": floatStore16,

        "lds": sysLoad, //-- load sys
        "sts": sysStore, //-- store sys
        
        "jz_i": jumpCond,
        "jz_r": int2R,
        "jnz_i": jumpCond,
        "jnz_r": int2R,
        "ja": jumpLong,
        "jl": jumpLink, //-- jump always, jump link        
        
        "sys_rete": noRegs,
        "sys_reti": noRegs,
        "sys_halt": noRegs,
        "sys_sync": noRegs,
        "sys_replay": noRegs,
        "sys_error": noRegs,
        "sys_call": noRegs,
        "sys_send": noRegs 
    };

    
    typedef struct {
        string asmForm;
        string decoding;
        string typeSpec;
    } FormatSpec; 


    const FormatSpec parsingMap[InstructionFormat] = '{
        none:          '{"    ", "0,000", "0,000"},
    
        noRegs :       '{"    ", "0,000", "0,000"},
    
        jumpLong :     '{"1   ", "0,0L0", "i,ic0"},
        jumpLink :     '{"d1  ", "a,0J0", "i,ic0"},
        jumpCond :     '{"01  ", "0,aJ0", "i,ic0"},
        
        intImm16 :     '{"d01 ", "a,bH0", "i,ic0"},
        intImm10 :     '{"d01 ", "a,bX0", "i,ic0"},
        
        intStore16 :   '{"201 ", "0,bHa", "i,ici"},
        intStore10 :   '{"201 ", "0,bXa", "i,ici"},
        
        floatLoad16 :  '{"d01 ", "a,bH0", "f,ic0"},
        floatLoad10 :  '{"d01 ", "a,bX0", "f,ic0"},
        
        floatStore16 : '{"201 ", "0,bHa", "i,icf"},
        floatStore10 : '{"201 ", "0,bXa", "i,icf"},
    
        sysLoad :      '{"d01 ", "a,bX0", "i,ic0"},

        sysStore :     '{"201 ", "0,bXa", "0,ici"},
    
        int3R :        '{"d012", "a,bcd", "i,iii"},
        int2R :        '{"d01 ", "a,bc0", "i,ii0"},
        int1R :        '{"d0  ", "a,b00", "i,i00"},
    
        float3R :      '{"d012", "a,bcd", "f,fff"},
        float2R :      '{"d01 ", "a,bc0", "f,ff0"},
        float1R :      '{"d0  ", "a,b00", "f,f00"},
        
        floatToInt :   '{"d0  ", "a,b00", "i,f00"},
        intToFloat :   '{"d0  ", "a,b00", "f,i00"}
    };


    function automatic matchDefinition(input InstructionDef pattern, candidate);
        return (candidate.p == pattern.p) && (candidate.s inside {S_none, pattern.s}) && (candidate.t inside {T_none, pattern.t});
    endfunction


    function automatic InstructionDef getDef(input string s);
        typedef MnemonicClass::Mnemonic Mnem;
        Mnem m;
        for (Mnem mi = m.first(); 1; mi = mi.next()) begin
            if (s == mi.name()) return defMap[s];
            if (mi == mi.last()) return '{P_none, S_none, T_none, O_undef};
        end  
    endfunction

    function automatic InstructionFormat getFormat(input string s);
        typedef MnemonicClass::Mnemonic Mnem;
        Mnem m;
        for (Mnem mi = m.first(); 1; mi = mi.next()) begin
            if (s == mi.name()) return formatMap[s];
            if (mi == mi.last()) return none;
        end  
    endfunction

    function automatic string findMnemonic(input InstructionDef def);
        string found[$] = defMap.find_index with(matchDefinition(def, item));
        
        if (found.size() == 0) return "undef";        
        if (found.size() != 1) $fatal("No single definition for %p, %d", def, found.size());

        return found[0];               
    endfunction

endpackage
