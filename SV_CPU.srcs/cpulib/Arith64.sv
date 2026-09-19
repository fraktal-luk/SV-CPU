
package Arith64;
	import Base::*;
	import Arith::*;


	//////////////////////////////////////////////////
	// Code mirrored after FP32 

	typedef struct packed {
		logic sign;
		logic[62:52] exp;
		logic[51:0] mantissa;
	} FpFormat64;


	localparam logic[62:52] EXP_MAX_64 = 'b11111111111;


	localparam FpFormat64 FP64_CANONICAL_QNAN = '{0, EXP_MAX_64, 'h8000000000000};
	localparam FpFormat64 FP64_SNAN = '{0, EXP_MAX_64, 'h4000000000000};


	localparam FpFormat64 FP64_PLUS_ZERO = '{0, 0, 0};
	localparam FpFormat64 FP64_MINUS_ZERO = '{1, 0, 0};
	localparam FpFormat64 FP64_PLUS_INF = '{0, EXP_MAX_64, 0};
	localparam FpFormat64 FP64_MINUS_INF = '{1, EXP_MAX_64, 0};
	localparam FpFormat64 FP64_PLUS_MAX_FINITE = '{0, EXP_MAX_64-1, 'hFFFFFFFFFFFFF};
	localparam FpFormat64 FP64_MINUS_MAX_FINITE = '{1, EXP_MAX_64-1, 'hFFFFFFFFFFFFF};
	localparam FpFormat64 FP64_PLUS_MIN_SUBN = '{0, 0, 1};
	localparam FpFormat64 FP64_MINUS_MIN_SUBN = '{1, 0, 1};
	localparam FpFormat64 FP64_PLUS_MAX_SUBN = '{0, 0, 'hFFFFFFFFFFFFF};
	localparam FpFormat64 FP64_MINUS_MAX_SUBN = '{1, 0, 'hFFFFFFFFFFFFF};

	localparam FpFormat64 FP64_PLUS_MIN_NORM = '{0, 1, 0};
	localparam FpFormat64 FP64_MINUS_MIN_NORM = '{1, 1, 0};


	typedef struct {
		ExceptionPack exc;
		FpFormat64 value;
	} FpResult64;



    typedef struct {
    	logic sign;
    	logic subn;
    	Word exp;
    	Qword mantissa;
    } FpIntermediate64;




    function automatic isZero64(input FpFormat64 a);
    	return a.exp == 0 && a.mantissa == 0;
    endfunction

    function automatic isSubnormal64(input FpFormat64 a);
    	return a.exp == 0 && a.mantissa != 0;
    endfunction

    function automatic isNormal64(input FpFormat64 a);
    	return a.exp < EXP_MAX_64;
    endfunction

    function automatic isInfinity64(input FpFormat64 a);
    	return a.exp == EXP_MAX_64 && a.mantissa == 0;
    endfunction

    function automatic isSNaN64(input FpFormat64 a);
    	return a.exp == EXP_MAX_64 && a.mantissa[51] == 0 && a.mantissa[50:0] != 0;
    endfunction

    function automatic isQNaN64(input FpFormat64 a);
    	return a.exp == EXP_MAX_64 && a.mantissa[51] == 1;
    endfunction


  	function automatic isNaN64(input FpFormat64 a);
    	return a.exp == EXP_MAX_64 && a.mantissa !== 0;
    endfunction




    function automatic classifyF64(input FpFormat64 a);
    	if (isQNaN64(a)) return QNAN;
    	else if (isSNaN64(a)) return SNAN;
    	else if (isZero64(a)) 		return a.sign ? M_ZERO : P_ZERO;
    	else if (isSubnormal64(a)) 	return a.sign ? M_SUBN : P_SUBN;
    	else if (isNormal64(a)) 	return a.sign ? M_NORM : P_NORM;
    	else			  			return a.sign ? M_INF : P_INF; 
    endfunction



    // These functions don't signal exceptions

    function automatic FpFormat64 negateF64(input FpFormat64 a);
    	return '{!a.sign, a.exp, a.mantissa};
    endfunction

    function automatic FpFormat64 absF64(input FpFormat64 a);
    	return '{0, a.exp, a.mantissa};
    endfunction

 	function automatic FpFormat64 copySignF64(input FpFormat64 a, input FpFormat64 b);
    	return '{b.sign, a.exp, a.mantissa};
    endfunction




    // next

    function automatic FpResult64 nextUpF64(input FpFormat64 a);
    	Dword bits = Dword'(a);

    	// SNaN -> exc Invalid, return QNaN?
    	if (isSNaN64(a))
    		return '{'{invalid: 1, default: 0}, FP64_CANONICAL_QNAN};
    	// QNaN, +inf -> copy
    	if (isQNaN64(a) || (isInfinity64(a) && !a.sign))
    		return '{NO_EXCEPTION, a};
    	
    	// -0 -> +0
    	if (isZero64(a) && a.sign)
    		return '{NO_EXCEPTION, FP64_PLUS_ZERO};

    	// elsif negative: dec
    	// else (positive): inc
    	if (a.sign)
    		return '{NO_EXCEPTION, FpFormat64'(bits-1)};
    	else
    		return '{NO_EXCEPTION, FpFormat64'(bits+1)};
    endfunction





endpackage
