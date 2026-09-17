

package ExecLogic;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;

    import AbstractSim::*;
    import Insmap::*;

    import UopList::*;

    import ExecDefs::*;

    import Arith::*;


    function automatic Mword calcArith(UopName name, Mword args[3], Mword linkAdr);
        Mword res = 'x;
        
        case (name)
            UOP_int_and:  res = args[0] & args[1];
            UOP_int_or:   res = args[0] | args[1];
            UOP_int_xor:  res = args[0] ^ args[1];
            
            UOP_int_addc: res = args[0] + args[1];
            UOP_int_addh: res = args[0] + (args[1] << 16);
            
            UOP_int_add:  res = args[0] + args[1];
            UOP_int_sub:  res = args[0] - args[1];

            
            UOP_int_cgtu:  res = $unsigned(args[0]) > $unsigned(args[1]);
            UOP_int_cgts:  res = $signed(args[0]) > $signed(args[1]);

            UOP_int_shl:
                            if ($signed(args[1]) >= 0) res = $unsigned(args[0]) << args[1];
                            else                       res = $unsigned(args[0]) >> -args[1];
            UOP_int_shlc:
                            if ($signed(args[1]) >= 0) res = $unsigned(args[0]) << args[1];
                            else                       res = $unsigned(args[0]) >> -args[1];
            UOP_int_shac:
                            if ($signed(args[1]) >= 0) res = $signed(args[0]) << args[1];
                            else                       res = $signed(args[0]) >> -args[1];                     
            UOP_int_rotc:
                            if ($signed(args[1]) >= 0) res = {args[0], args[0]} << args[1];
                            else                       res = {args[0], args[0]} >> -args[1];
            
            // mul/div/rem
            UOP_int_mul:   res = w2m( multiplyW(args[0], args[1]) );
            UOP_int_mulhu: res = w2m( multiplyHighUnsignedW(args[0], args[1]) );
            UOP_int_mulhs: res = w2m( multiplyHighSignedW(args[0], args[1]) );
            UOP_int_divu:  res = w2m( divUnsignedW(args[0], args[1]) );
            UOP_int_divs:  res = w2m( divSignedW(args[0], args[1]) );
            UOP_int_remu:  res = w2m( remUnsignedW(args[0], args[1]) );
            UOP_int_rems:  res = w2m( remSignedW(args[0], args[1]) );
            
            UOP_int_link: res = linkAdr;
            
            // FP
            UOP_fp_move:   res = args[0];
            UOP_fp_xor:     res = args[0] ^ args[1];
            UOP_fp_and:     res = args[0] & args[1];
            UOP_fp_or:     res = args[0] | args[1];
            UOP_fp_addi:   res = args[0] + args[1];

                UOP_fp_muli:   res = Word'(args[0] * args[1]);
                UOP_fp_divi:   res = Word'(args[0] / args[1]);
                UOP_fp_inv:   res = 1;
                UOP_fp_ov:   res = 1;

            UOP_fp_add32: res = $shortrealtobits($bitstoshortreal(args[0]) + $bitstoshortreal(args[1]));
            UOP_fp_sub32: res = $shortrealtobits($bitstoshortreal(args[0]) - $bitstoshortreal(args[1]));
            UOP_fp_mul32: res = $shortrealtobits($bitstoshortreal(args[0]) * $bitstoshortreal(args[1]));
            UOP_fp_div32: res = $shortrealtobits($bitstoshortreal(args[0]) / $bitstoshortreal(args[1]));
            UOP_fp_cmpeq32: res = ($bitstoshortreal(args[0]) == $bitstoshortreal(args[1]));
            UOP_fp_cmpge32: res = ($bitstoshortreal(args[0]) >= $bitstoshortreal(args[1]));
            UOP_fp_cmpgt32: res = ($bitstoshortreal(args[0]) > $bitstoshortreal(args[1]));

            UOP_fp_move32: res = Word'(args[0]);
            UOP_fp_neg32: res = Word'(args[0] ^ 'h80000000);
            UOP_fp_abs32: res = Word'(args[0] & 'h7FFFFFFF);
            UOP_fp_cpys: res = Word'( (args[0] & 'h7FFFFFFF) | (args[1] & 'h80000000) );

            default: $fatal(2, "Wrong uop");
        endcase
        
        // Handling of cases of division by 0  
        if ((name inside {UOP_int_divs, UOP_int_divu, UOP_int_rems, UOP_int_remu}) && $isunknown(res)) res = -1;

        return res;
    endfunction



    function automatic FpResult32 calcArithFp(UopName name, Mword args[3], Rounding rm);
        FpResult32 res;
        
        case (name)
            UOP_fp_xor:     res = '{NO_EXCEPTION, args[0] ^ args[1]};
            UOP_fp_and:     res = '{NO_EXCEPTION, args[0] & args[1]};
            UOP_fp_or:     res = '{NO_EXCEPTION, args[0] | args[1]};
            UOP_fp_addi:   res = '{NO_EXCEPTION, args[0] + args[1]};

                UOP_fp_muli:   res = '{NO_EXCEPTION, Word'(args[0] * args[1])};
                UOP_fp_divi:   res = '{NO_EXCEPTION, Word'(args[0] / args[1])};

                UOP_fp_inv:   res = '{EXC_INVALID, 1};
                UOP_fp_ov:   res = '{EXC_OVERFLOW, 1};

            UOP_fp_add32: res = TMP_addF32(args[0], args[1], rm);

            UOP_fp_sub32: res = '{NO_EXCEPTION, $shortrealtobits($bitstoshortreal(args[0]) - $bitstoshortreal(args[1]))};
            UOP_fp_mul32: res = '{NO_EXCEPTION, $shortrealtobits($bitstoshortreal(args[0]) * $bitstoshortreal(args[1]))};
            UOP_fp_div32: res = '{NO_EXCEPTION, $shortrealtobits($bitstoshortreal(args[0]) / $bitstoshortreal(args[1]))};
            UOP_fp_cmpeq32: res = '{NO_EXCEPTION, ($bitstoshortreal(args[0]) == $bitstoshortreal(args[1]))};
            UOP_fp_cmpge32: res = '{NO_EXCEPTION, ($bitstoshortreal(args[0]) >= $bitstoshortreal(args[1]))};
            UOP_fp_cmpgt32: res = '{NO_EXCEPTION, ($bitstoshortreal(args[0]) > $bitstoshortreal(args[1]))};

            UOP_fp_move32: res = '{NO_EXCEPTION, Word'(args[0])};
            UOP_fp_neg32: res = '{NO_EXCEPTION, Word'(args[0] ^ 'h80000000)};
            UOP_fp_abs32: res = '{NO_EXCEPTION, Word'(args[0] & 'h7FFFFFFF)};
            UOP_fp_cpys: res = '{NO_EXCEPTION, Word'( (args[0] & 'h7FFFFFFF) | (args[1] & 'h80000000) )};

            default: $fatal(2, "Wrong uop");
        endcase

        return res;//'{NO_EXCEPTION, res};
    endfunction


endpackage
