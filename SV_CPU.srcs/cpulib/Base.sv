
package Base;

    typedef logic[7:0]  Mbyte;
    typedef logic[31:0] Word;
    typedef logic[63:0] Dword;
    typedef logic[127:0] Qword; 

    typedef Word Word3[3];
    typedef Word Word4[4];

    typedef logic logic3[3];


    typedef Word WordArray[];




        function automatic Qword multiplyU64L(input Dword a, input Dword b);
            return a*b;
        endfunction

        function automatic Qword multiplyS64L(input Dword a, input Dword b);
            return $signed(a)*$signed(b);
        endfunction


        function automatic Dword divideU64(input Dword a, input Dword b);
            if (b == 0) return 0; 
            return a/b;
        endfunction

        function automatic Dword divideS64(input Dword a, input Dword b);
            if (b == 0) return 0; 
            return $signed(a)/$signed(b);
        endfunction


    function automatic Word multiplyW(Word a, Word b);
        return a * b;
    endfunction

    function automatic Word multiplyHighUnsignedW(Word a, Word b);
        return (Dword'($unsigned(a)) * Dword'($unsigned(b))) >> 32;
    endfunction

    function automatic Word multiplyHighSignedW(Word a, Word b);
        return (Dword'($signed(a)) * Dword'($signed(b))) >> 32;
    endfunction


    function automatic Word divSignedW(input Word a, input Word b);
        Word rInt;
        Word rem;
        
        if (b == 0) rInt = 'x;
        else rInt = $signed(a)/$signed(b);
        
        rem = a - rInt * b;
        
        if ($signed(rem) < 0 && $signed(b) > 0) rInt--;
        if ($signed(rem) > 0 && $signed(b) < 0) rInt--;
        
        return rInt;
    endfunction
    

    function automatic Word remSignedW(input Word a, input Word b);
        Word rInt;
        Word rem;
        
        if (b == 0) rInt = 'x;
        else rInt = $signed(a)/$signed(b);
        
        rem = a - rInt * b;
        
        if ($signed(rem) < 0 && $signed(b) > 0) rem += b;
        if ($signed(rem) > 0 && $signed(b) < 0) rem += b;
        
        return rem;
    endfunction



    function automatic Word divUnsignedW(input Word a, input Word b);
        Word rInt;
        Word rem;
        
        if (b == 0) rInt = 'x;
        else rInt = $unsigned(a)/$unsigned(b);
        
        rem = a - rInt * b;
        return rInt;
    endfunction
    
    function automatic Word remUnsignedW(input Word a, input Word b);
        Word rInt;
        Word rem;
        
        if (b == 0) rInt = 'x;
        else rInt = $unsigned(a)/$unsigned(b);
        
        rem = a - rInt * b;
        return rem;
    endfunction

endpackage
