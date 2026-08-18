
package Arith;
	import Base::*;

	typedef logic[127:0] Qword; 


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


	typedef struct {
		logic invalid;
		logic div0;
		logic overflow;
		logic underflow;
		logic inexact;
	} ExceptionPack;

	localparam ExceptionPack NO_EXCEPTION = '{default: 0};


	localparam logic[30:23] EXP_MAX_32 = 'b11111111;


	typedef struct packed {
		logic sign;
		logic[30:23] exp;
		logic[22:0] mantissa;
	} FpFormat32;

	localparam FpFormat32 FP32_CANONICAL_QNAN = '{0, EXP_MAX_32, 'h400000};
	localparam FpFormat32 FP32_SNAN = '{0, EXP_MAX_32, 'h200000};


	localparam FpFormat32 FP32_PLUS_ZERO = '{0, 0, 0};
	localparam FpFormat32 FP32_MINUS_ZERO = '{1, 0, 0};
	localparam FpFormat32 FP32_PLUS_INF = '{0, EXP_MAX_32, 0};
	localparam FpFormat32 FP32_MINUS_INF = '{1, EXP_MAX_32, 0};
	localparam FpFormat32 FP32_PLUS_MAX_FINITE = '{0, EXP_MAX_32-1, 'h7FFFFF};
	localparam FpFormat32 FP32_MINUS_MAX_FINITE = '{1, EXP_MAX_32-1, 'h7FFFFF};
	localparam FpFormat32 FP32_PLUS_MIN_SUBN = '{0, 0, 1};
	localparam FpFormat32 FP32_MINUS_MIN_SUBN = '{1, 0, 1};
	localparam FpFormat32 FP32_PLUS_MAX_SUBN = '{0, 0, 'h7FFFFF};
	localparam FpFormat32 FP32_MINUS_MAX_SUBN = '{1, 0, 'h7FFFFF};

	localparam FpFormat32 FP32_PLUS_MIN_NORM = '{0, 1, 0};
	localparam FpFormat32 FP32_MINUS_MIN_NORM = '{1, 1, 0};


	typedef struct {
		ExceptionPack exc;
		FpFormat32 value;
	} FpResult32;


	typedef enum {
		M_INF,
		M_NORM,
		M_SUBN,
		M_ZERO,
		P_ZERO,
		P_SUBN,
		P_NORM,
		P_INF,
		QNAN,
		SNAN
	} FpClass;


	/*         exp   m[22] m[21:0] 
   		zero    0      0      0
   		subn    0      x      x
   		norm    x      x      x
   		inf     M      0      0
   		snan    M      0      x
   		qnan    M      1      x
    */

    function automatic isZero(input FpFormat32 a);
    	return a.exp == 0 && a.mantissa == 0;
    endfunction

    function automatic isSubnormal(input FpFormat32 a);
    	return a.exp == 0 && a.mantissa != 0;
    endfunction

    function automatic isNormal(input FpFormat32 a);
    	return a.exp == EXP_MAX_32;
    endfunction

    function automatic isInfinity(input FpFormat32 a);
    	return a.exp == EXP_MAX_32 && a.mantissa == 0;
    endfunction

    function automatic isSNaN(input FpFormat32 a);
    	return a.exp == EXP_MAX_32 && a.mantissa[22] == 0 && a.mantissa[21:0] != 0;
    endfunction

    function automatic isQNaN(input FpFormat32 a);
    	return a.exp == EXP_MAX_32 && a.mantissa[22] == 1;
    endfunction


    function automatic classifyF32(input FpFormat32 a);
    	if (isQNaN(a)) return QNAN;
    	else if (isSNaN(a)) return SNAN;
    	else if (isZero(a)) 		return a.sign ? M_ZERO : P_ZERO;
    	else if (isSubnormal(a)) 	return a.sign ? M_SUBN : P_SUBN;
    	else if (isNormal(a)) 	return a.sign ? M_NORM : P_NORM;
    	else			  		return a.sign ? M_INF : P_INF; 
    endfunction



    // Numbers
    // zero  '{0, 0, 0}
    // subn  '{0, 0, 1}
    //       '{0, 0, M}
    // norm  '{0, 1, 0}
    //       '{0, M-1, M}
    // inf   '{0, M, 0}
    // snan  '{0, M, 'b00000000000000000000001}
    //		 '{0, M, 'b01111111111111111111111}
    // qnan  '{0, M, 'b10000000000000000000000}
    //       '{0, M, 'b11111111111111111111111} 



    // These functions don't signal exceptions

    function automatic FpFormat32 negateF32(input FpFormat32 a);
    	return '{!a.sign, a.exp, a.mantissa};
    endfunction

    function automatic FpFormat32 absF32(input FpFormat32 a);
    	return '{0, a.exp, a.mantissa};
    endfunction

 	function automatic FpFormat32 copySignF32(input FpFormat32 a, input FpFormat32 b);
    	return '{b.sign, a.exp, a.mantissa};
    endfunction









    // next

    function automatic FpResult32 nextUpF32(input FpFormat32 a);
    	Word bits = Word'(a);

    	// SNaN -> exc Invalid, return QNaN?
    	if (isSNaN(a))
    		return '{'{invalid: 1, default: 0}, FP32_CANONICAL_QNAN};
    	// QNaN, +inf -> copy
    	if (isQNaN(a) || (isInfinity(a) && !a.sign))
    		return '{NO_EXCEPTION, a};
    	
    	// -0 -> +0
    	if (isZero(a) && a.sign)
    		return '{NO_EXCEPTION, FP32_PLUS_ZERO};

    	// elsif negative: dec
    	// else (positive): inc
    	if (a.sign)
    		return '{NO_EXCEPTION, FpFormat32'(bits-1)};
    	else
    		return '{NO_EXCEPTION, FpFormat32'(bits+1)};
    endfunction



endpackage
