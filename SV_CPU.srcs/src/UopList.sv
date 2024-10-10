
package UopList;

    typedef enum {
        any_DUMMY,
        
    // Per mnemonic
    
    //    and_r,
        int_and,
    //    or_r,
        int_or,
    //    xor_r,
        int_xor,
        
    //    add_i,
        int_add,
    //    add_h,
        //int_add,
    //    add_r,
        //int_add,
    //    sub_r,
        int_sub,
        
    //    shl_i, shl_r, //-- direction defined by shift value, not opcode 
        int_shl,
    //    sha_i, sha_r, //--
        int_sha,  
    //    rot_i, rot_r,
        int_rot,
    //    mult,
        mul_mull,
    //    mulh_s, mulh_u,
        mul_mulhs,
        mul_mulhu,
    //    div_s, div_u,
        div_divs,
        div_divu,
    //    rem_s, rem_u,
        div_rems,
        div_remu,
        
    //    mov_f,
        fp_mov,
    //    or_f, addi_f,  // -- Float operations
        fp_or,
        
        
        
        mem_ld_exc,
        mem_st_exc,
        
        mem_ld_refetch,
        mem_st_refetch,
       
        
    //    ldi_i, ldi_r, //-- int
        mem_ldiw,
    //    sti_i, sti_r,
        mem_stiw,
                
    //    ldf_i, ldf_r, //-- float
        mem_ldfw,
    //    stf_i, stf_r, 
        mem_stfw,
        
        
        sys_ld_exc,
        sys_st_exc,

        sys_ld_refetch,
        sys_st_refetch,        
        
    //    lds, //-- load sys
        sys_ld,
        
    //    sts, //-- store sys
        sys_st,
        
    //    jz_i, jz_r, jnz_i, jnz_r,
        br_zi,
        
        br_zr,
        
        br_nzi,
        
        br_nzr,
        
    //    ja,
        //br_zi,
    //jl, //-- jump always, jump link
        br_lki,
        
        br_lkr,


        ctrl_nop,

      
    //    //sys, //-- system operation
      
    //    sys_rete,
    //    sys_reti,
    //    sys_halt,
    //    sys_sync,
    //    sys_replay,
    //    sys_error,
    //    sys_call,
    //    sys_send,
    
        ctrl_rete,
        ctrl_reti,
        ctrl_halt,
        ctrl_sync,
        ctrl_replay,
        ctrl_error,
        ctrl_call,
        ctrl_send,
        
        
        ctrl_int,
        ctrl_reset,
        
    //    undef
        
        
        ctrl_DUMMY
        
    } UopName;

endpackage
