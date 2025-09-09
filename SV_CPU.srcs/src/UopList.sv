
package UopList;

    import Base::*;
    import InsDefs::*;


    typedef enum {        
         // Per mnemonic
         UOP_none,
         
         UOP_ctrl_undef,
               
         UOP_int_and,
         UOP_int_or,
         UOP_int_xor,
        
         UOP_int_addc,
         UOP_int_addh,
        
         UOP_int_add,
         UOP_int_sub,
        
            UOP_int_cgtu,
            UOP_int_cgts,
        
         UOP_int_shlc,
         UOP_int_shac,
         UOP_int_rotc,
        
         UOP_int_mul,
         UOP_int_mulhs,
         UOP_int_mulhu,
         UOP_int_divs, 
         UOP_int_divu,
         UOP_int_rems,
         UOP_int_remu,
        
         UOP_fp_move,
         UOP_fp_or,
         UOP_fp_addi,
            UOP_fp_muli,
            UOP_fp_divi,
            UOP_fp_inv,
            UOP_fp_ov,
        
         UOP_mem_ldi,
         UOP_mem_sti,
        
            UOP_mem_ldib,
            UOP_mem_stib,
        
         UOP_mem_ldf,
         UOP_mem_stf,
    
        
         UOP_mem_lds,
         UOP_mem_sts,
        
            UOP_int_link,
        
         UOP_bc_z,
         UOP_bc_nz,
         UOP_br_z,
         UOP_br_nz,
         UOP_bc_a,
         UOP_bc_l,
        
            // Store data
            UOP_data_int,
            UOP_data_fp,
        
         UOP_ctrl_rete,
         UOP_ctrl_reti,
         UOP_ctrl_halt,
         UOP_ctrl_sync,
         UOP_ctrl_refetch,
         UOP_ctrl_error,
         UOP_ctrl_call,
         UOP_ctrl_send,
            UOP_ctrl_dbcall
    
    } UopName;


    const UopName OP_DECODING_TABLE[string] = '{
        //default:      UOP_ctrl_undef,
        
        "unknown":    UOP_ctrl_undef,
        
        "undef":      UOP_ctrl_undef,
    
        "and_r":      UOP_int_and,
        "or_r":       UOP_int_or,
        "xor_r":      UOP_int_xor,

        "add_i":      UOP_int_addc,
        "add_h":      UOP_int_addh,

        "add_r":      UOP_int_add,
        "sub_r":      UOP_int_sub,

            "cgt_u":   UOP_int_cgtu,
            "cgt_s":   UOP_int_cgts,

        "shl_i":      UOP_int_shlc,
        "sha_i":      UOP_int_shac,
        "rot_i":      UOP_int_rotc,
        
        "mult":       UOP_int_mul,
        "mulh_s":     UOP_int_mulhs,
        "mulh_u":     UOP_int_mulhu,

        "div_s":      UOP_int_divs, 
        "div_u":      UOP_int_divu,
        "rem_s":      UOP_int_rems,
        "rem_u":      UOP_int_remu,
        
        "mov_f":      UOP_fp_move,
        "or_f":       UOP_fp_or,
        "addi_f":     UOP_fp_addi,
        "muli_f":     UOP_fp_muli,
        "divi_f":     UOP_fp_divi,
        "inv_f":      UOP_fp_inv,
        "ov_f":       UOP_fp_ov,
        
        "ldi_i":      UOP_mem_ldi,
        "sti_i":      UOP_mem_sti,
        
        "ldf_i":      UOP_mem_ldf,
        "stf_i":      UOP_mem_stf,
                
            "e_lb":    UOP_mem_ldib,
            "e_sb":    UOP_mem_stib,
        
        "lds":        UOP_mem_lds,
        "sts":        UOP_mem_sts,
        
        "jz_i":       UOP_bc_z,
        "jz_r":       UOP_br_z,
        "jnz_i":      UOP_bc_nz,
        "jnz_r":      UOP_br_nz,
        "ja":         UOP_bc_a,
        "jl":         UOP_bc_l,
        
        "sys_rete":   UOP_ctrl_rete,
        "sys_reti":   UOP_ctrl_reti,
        "sys_halt":   UOP_ctrl_halt,
        "sys_sync":   UOP_ctrl_sync,
        "sys_replay": UOP_ctrl_refetch,
        "sys_error":  UOP_ctrl_error,
        "sys_call":   UOP_ctrl_call,
        "sys_send":   UOP_ctrl_send,
            "sys_dbcall":   UOP_ctrl_dbcall
        
    }; 




// Classification

    // Not including memory
    function automatic logic isFloatCalcUop(input UopName name);
        return name inside {
             UOP_fp_move,
             UOP_fp_or,
             UOP_fp_addi,
                UOP_fp_muli,
                UOP_fp_divi,
                UOP_fp_inv,
                UOP_fp_ov
              };
    endfunction    

    function automatic logic isControlUop(input UopName name);
        return name inside {
            UOP_ctrl_undef,
            UOP_ctrl_rete,
            UOP_ctrl_reti,
            UOP_ctrl_halt,
            UOP_ctrl_sync,
            UOP_ctrl_refetch,
            UOP_ctrl_error,
            UOP_ctrl_call,
            UOP_ctrl_send,
                UOP_ctrl_dbcall
        };
    endfunction

    function automatic logic isStoreDataUop(input UopName name);
        return name inside {
            UOP_data_int,
            UOP_data_fp
        };
    endfunction


    function automatic logic isBranchUop(input UopName name);
        return name inside {UOP_bc_z, UOP_br_z, UOP_bc_nz, UOP_br_nz, UOP_bc_a, UOP_bc_l};
    endfunction

    function automatic logic isBranchRegUop(input UopName name);
        return name inside {UOP_br_z, UOP_br_nz};
    endfunction

    function automatic logic isIntMultiplierUop(input UopName name);
        return name inside {UOP_int_mul, UOP_int_mulhs, UOP_int_mulhu};
    endfunction

  
    function automatic logic isIntDividerUop(input UopName name);
        return name inside {UOP_int_divs, UOP_int_divu, UOP_int_rems, UOP_int_remu};
    endfunction

    function automatic logic isMemUop(input UopName name);
        return isLoadMemUop(name) || isStoreMemUop(name);
    endfunction

    function automatic logic isStoreUop(input UopName name);
        return isStoreMemUop(name) || isStoreSysUop(name);
    endfunction

    function automatic logic isLoadUop(input UopName name);
        return isLoadMemUop(name) || isLoadSysUop(name);
    endfunction

    function automatic logic isLoadSysUop(input UopName name);
        return name inside {UOP_mem_lds};
    endfunction

    function automatic logic isLoadMemUop(input UopName name);
        return name inside {UOP_mem_ldi, UOP_mem_ldf,    UOP_mem_ldib};
    endfunction

    function automatic logic isStoreMemUop(input UopName name);
        return name inside {UOP_mem_sti, UOP_mem_stf,    UOP_mem_stib};
    endfunction

    function automatic logic isStoreSysUop(input UopName name);
        return name inside {UOP_mem_sts};
    endfunction




    function automatic logic uopHasIntDest(input UopName name);
        return name inside {
         UOP_int_and,
         UOP_int_or,
         UOP_int_xor,
        
         UOP_int_addc,
         UOP_int_addh,
        
         UOP_int_add,
         UOP_int_sub,
        
            UOP_int_cgtu,
            UOP_int_cgts,
        
         UOP_int_shlc,
         UOP_int_shac,
         UOP_int_rotc,
        
         UOP_int_mul,
         UOP_int_mulhs,
         UOP_int_mulhu,
         UOP_int_divs, 
         UOP_int_divu,
         UOP_int_rems,
         UOP_int_remu,
        
         UOP_mem_ldi,
            UOP_mem_ldib,
            
         UOP_mem_lds,
        
        
         UOP_int_link
        };
    endfunction


    function automatic logic uopHasFloatDest(input UopName name);
        return name inside {
             UOP_fp_move,
             UOP_fp_or,
             UOP_fp_addi,
                UOP_fp_muli,
                UOP_fp_divi,
                UOP_fp_inv,
                UOP_fp_ov,
             UOP_mem_ldf
        };
    endfunction    

    localparam int N_UOP_MAX = 2; // Biggest number for uops for any instruction


endpackage
