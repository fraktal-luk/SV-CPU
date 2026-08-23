
package Arith;
	import Base::*;

	typedef logic[127:0] Qword; 



		typedef enum {
			RoundNearestEven,
			RoundNearestAway,
			RoundPlusInf,
			RoundZero,
			RoundMinusInf
		} Rounding;



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






    typedef struct {
    	logic sign;
    	logic subn;
    	Word exp;
    	Dword mantissa;
    } FpIntermediate;






	function automatic FpIntermediate convToIntermediate(input FpFormat32 a);
		Word expA = isSubnormal(a) ? a.exp + 1 : a.exp;
		Word normA = isSubnormal(a) ? a.mantissa : ('h800000 | a.mantissa);

		// Shift a to upper Word of a Dword
		Dword fullA = {normA, Word'(0)};

		return '{a.sign, isSubnormal(a), expA, fullA};
	endfunction


	// Shifts right, preserving 1 extra bit in [31] and 'permanent' bit in [30]
	function automatic Dword shiftCompress30(input Dword v, input int shift);
		Dword res = v;
		// Which bit will go to pos [31]?  v[31 + sh]
		// Which bit will go to pos [30]?  v[30 + sh]

		Dword mask = 'h000000007FFFFFFF;
		Dword mask30 = (mask << shift) | mask;

		if (v & mask30 != 0) res[30+shift] = 1;
		else 				 res[30+shift] = 0;

		res >>= shift;

		return res;
	endfunction

	// Shifts right, preserving 2 extra bits in [31:30] and 'permanent' bit in [29]
	function automatic Dword shiftCompress29(input Dword v, input int shift);
		Dword res = v;
		// Which bit will go to pos [29]?  v[29 + sh]

		Dword mask = 'h000000003FFFFFFF;
		Dword mask29 = (mask << shift) | mask;

		if (v & mask29 != 0) res[29+shift] = 1;
		else 				 res[29+shift] = 0;

		res >>= shift;

		return res;
	endfunction


	function automatic FpIntermediate addInter(input FpIntermediate a, FpIntermediate b);
		FpIntermediate res, bSh;

		Word ediff = a.exp - b.exp;
		Dword bShifted = //b.mantissa >> ediff;
						 shiftCompress30(b.mantissa, ediff);

		res.sign = a.sign;
		res.subn = a.subn;
		res.exp = a.exp;
		res.mantissa = a.mantissa + bShifted;

		bSh = '{b.sign, b.subn, a.exp, bShifted};

			$display("Nonc");
			dispInter("a: ", a);
			dispInter("b: ", bSh);
			dispInter(" = ", res);
		return res;
	endfunction


	function automatic FpIntermediate addInter_Comp(input FpIntermediate a, FpIntermediate b);
		FpIntermediate res, bSh;

		Word ediff = a.exp - b.exp;
		Dword bShifted = b.mantissa >> ediff;

		// bit 30 will represent all bits from it downwards
		if (bShifted[30:0] == 0) bShifted[30:0] = 0;
		else					 bShifted[30:0] = 'h40000000;

		res.sign = a.sign;
		res.subn = a.subn;
		res.exp = a.exp;
		res.mantissa = a.mantissa + bShifted;

		bSh = '{b.sign, b.subn, a.exp, bShifted};

			$display("Comp");
			dispInter("a: ", a);
			dispInter("b: ", bSh);
			dispInter(" = ", res);

		return res;
	endfunction


	function automatic FpIntermediate normalizeAdded(input FpIntermediate a);
		FpIntermediate res;
		
		res.sign = a.sign;
		// Denorm: if bit [23] of mantissa becomes 1, we crossed to normal range
		if (a.subn) begin
			if (a.mantissa[32 + 23]) begin
				res.exp = 1; // We don't shift, the bit at [23] is accounted for by Normal exponent
				res.subn = 0;
			end
			else begin
				res.exp = 1;
				res.subn = 1;
			end
			res.mantissa = a.mantissa;
		end
		// Normal: if bit [24] becomes 1, exp increased and we need to normalize
		else if (a.mantissa[32 + 24] === 1) begin
			res.subn = 0;
			res.exp = a.exp + 1;
			res.mantissa = a.mantissa >> 1;
			// Now the bits [-1:-2] have shifted to [-2:-3], we must refill bit [-2] considering [-3]
			if (res.mantissa[30:29] != 0) res.mantissa[30:29] = 'h2;  
		end

		return res;
	endfunction


		function automatic void dispLong(input string s, input Dword x);
			$display({s, "%08X|%08X"}, x >> 32, Word'(x));
		endfunction


		function automatic void dispInter(input string s, input FpIntermediate x);
			$display({s, "%d (%d) %08X|%08X"}, x.sign, x.exp, x.mantissa >> 32, Word'(x.mantissa));
		endfunction




	function automatic FpIntermediate subInter(input FpIntermediate a, FpIntermediate b);
		FpIntermediate res;

		FpIntermediate bSh;

		Word ediff = a.exp - b.exp;
		Dword bShifted = //b.mantissa >> ediff;
						 shiftCompress29(b.mantissa, ediff);

		bSh = '{b.sign, b.subn, a.exp, bShifted};

		res.sign = a.sign;
		res.subn = a.subn;
		res.exp = a.exp;
		res.mantissa = a.mantissa - bShifted;

			$display("Nonc");
			dispInter("a: ", a);
			dispInter("b: ", bSh);
			dispInter(" = ", res);

		return res;
	endfunction


	function automatic FpIntermediate subInter_Comp(input FpIntermediate a, FpIntermediate b);
		FpIntermediate res;

		FpIntermediate bSh;

		Word ediff = a.exp - b.exp;
		Dword bShifted = b.mantissa >> ediff;

		// bit 29 will represent all bits from it downwards
		if (bShifted[29:0] == 0) bShifted[29:0] = 0;
		else					 bShifted[29:0] = 'h20000000;

		bSh = '{b.sign, b.subn, a.exp, bShifted};

		res.sign = a.sign;
		res.subn = a.subn;
		res.exp = a.exp;
		res.mantissa = a.mantissa - bShifted;

			$display("Comp");
			dispInter("a: ", a);
			dispInter("b: ", bSh);
			dispInter(" = ", res);


		return res;
	endfunction




	function automatic FpIntermediate normalizeSubtracted(input FpIntermediate a);
		FpIntermediate res;

		res.sign = a.sign;

		// We need to normalize if MSB fell to the right
		if (a.subn) begin
			// TODO: both denorm: don't shift anything
			res.exp = 1;
			res.subn = 1;
			res.mantissa = a.mantissa;
		end
		else begin
			// Find first 1. There may be none because diff can be 0
			if ($countones(a.mantissa) == 0) begin
				res.exp = 1;
				res.subn = 1;
				res.mantissa = 0;
			end
			else begin
				int expShift, newExp;
				int log = $clog2(a.mantissa);
				if (a.mantissa[log] == 0) log--; // $clog2 is ceiling, there may be 1 more to shift

				// We want MSB to be at [32 + 23];
				expShift = (32+23) - log;
				if (expShift > a.exp) expShift = a.exp;
				newExp = a.exp - expShift;

				// Maybe we went too far, below exp 0?
				if (newExp == 0) begin
					res.exp = 1;
					res.subn = 1;
					res.mantissa = a.mantissa << (expShift-1); // We don't want to fill default '1' if subnormal arises
				end
				else begin
					res.exp = newExp;
					res.subn = 0;
					res.mantissa = a.mantissa << expShift;
				end
			end
		end

		return res;
	endfunction






    function automatic FpIntermediate TMP_addMag(input FpFormat32 a, input FpFormat32 b);
    	FpIntermediate inter, interA, interB, interFull, interFull_Comp, interFullN, interFullCN;

    	assert (absF32(a) >= absF32(b)) else $error("Wrng, shoudl be abs(a) >= abs(b)");

    	begin
			Word normA = isSubnormal(a) ? a.mantissa : ('h800000 | a.mantissa);
			Word normB = isSubnormal(b) ? b.mantissa : ('h800000 | b.mantissa);

			interA = convToIntermediate(a); //'{a.sign, isSubnormal(a), expA, fullA};
			interB = convToIntermediate(b); //'{b.sign, isSubnormal(b), expB, fullB};

			$display("Add");
			$display("normA: %08X", normA);
			$display("normB: %08X", normB);

			interFull = addInter(interA, interB);
			//interFull_Comp = addInter_Comp(interA, interB);

			interFullN = normalizeAdded(interFull);
			//interFullCN = normalizeAdded(interFull_Comp);

			dispInter(" n ", interFullN);
			//dispInter("cn ", interFullCN);
    	end

    	return interFullN;
    endfunction



    function automatic FpIntermediate TMP_subMag(input FpFormat32 a, input FpFormat32 b);
    	FpIntermediate inter, interA, interB, interFull, interFull_Comp, interFullN, interFullCN;

    	assert (absF32(a) >= absF32(b)) else $error("Wrng, shoudl be abs(a) >= abs(b)");

    	begin
			Word normA = isSubnormal(a) ? a.mantissa : ('h800000 | a.mantissa);
			Word normB = isSubnormal(b) ? b.mantissa : ('h800000 | b.mantissa);

			interA = convToIntermediate(a);
			interB = convToIntermediate(b);

			$display("Sub");
			$display("normA: %08X", normA);
			$display("normB: %08X", normB);

			interFull = subInter(interA, interB);
			//interFull_Comp = subInter_Comp(interA, interB);

			//if (summed[31:30] !== summed_C[31:30]) $display("    Digits [31:30] differ!");


			interFullN = normalizeSubtracted(interFull);
			//interFullCN = normalizeSubtracted(interFull_Comp);

			dispInter(" n ", interFullN);
			//dispInter("cn ", interFullCN);

			$display("--------------------------");

    	end

    	return interFullN;
    endfunction 


    function automatic FpIntermediate multiplyInter(input FpIntermediate a, input FpIntermediate b);
    	FpIntermediate res, aSh;

    	Word expOut = a.exp + b.exp - 127; // 127 is the exp of 1.0

    	// Shifted by 8 to align with high subword
    	Dword product = (a.mantissa << 8) * b.mantissa;

    	aSh = '{a.sign, a.subn, a.exp, a.mantissa << 8};

    	res.sign = a.sign ^ b.sign;
    	res.subn = 'x; // TODO
    	res.exp = expOut;
    	res.mantissa = product;

    	$display("Mult");
    	dispInter("a: ", aSh);
    	dispInter("b: ", b);
    	dispInter(" =", res);

    	return res;
    endfunction



    function automatic FpIntermediate roundInter(input FpIntermediate x, input Rounding rd);
    	FpIntermediate res;

    	/*  RM

			nrEven:
				plus -> tieEven
				0 -> +0
				minus -> tieEven
			nrAway:
				plus -> tieAway
				0 -> +0
				minus -> tieAway
			+Inf:
				plus -> magUp
				0 -> +0
				minus -> magDown
			Zero:
				plus -> magDown
				0 -> +0
				minus -> magDown
			-Inf:
				plus -> magDown
				0 -> -0
				minus -> magUp
    	*/

    	//  Above: 4 impl modes for nonzero: even, tieAway, magDown, magUp
    	//		   2 impl modes for zero: -0, +0

    	if (x.mantissa === 0) begin
    		res = x;

    		if (rd == RoundMinusInf) res.sign = 1;
    		else res.sign = 0; 

    		return res;
    	end

    	case (rd)
    		RoundNearestEven:
    			res = roundNearestEven(x);
    		RoundNearestAway:
    			res = roundNearestAway(x);
    		RoundPlusInf:
    			if (x.sign) res = roundMagDown(x);
    			else res = roundMagUp(x);
    		RoundZero:
    			res = roundMagDown(x);
    		RoundMinusInf:
    			if (x.sign) res = roundMagUp(x);
    			else res = roundMagDown(x);
    	endcase


    	return res;
    endfunction


    function automatic FpIntermediate roundMagUp(input FpIntermediate x);
    	FpIntermediate res, xPlus;
    	Dword newMantissa;

    	if (x.mantissa[31:30] == 0) return x;

    	newMantissa = x.mantissa + 'h100000000;

    	xPlus = '{x.sign, x.subn, x.exp, newMantissa};

    	res = normalizeAdded(xPlus);

    	return res;
    endfunction

    function automatic FpIntermediate roundMagDown(input FpIntermediate x);
    	FpIntermediate res;
    	Dword newMantissa = x.mantissa;
    	newMantissa[31:0] = 0;

    	res = '{x.sign, x.subn, x.exp, newMantissa};
    	return res;
    endfunction

    function automatic FpIntermediate roundNearestEven(input FpIntermediate x);
    	FpIntermediate res;

    	/* 
    	   1|11 u
    	   1|10 u
    	   1|01 d
    	   1|00 d
    	   0|11 u
    	   0|10 d
    	   0|01 d
    	   0|00 d
    	*/

    	case (x.mantissa[32:30])
    		'b111, 'b110, 'b011: return roundMagUp(x);
    		default: return roundMagDown(x);
    	endcase

    	//return res;
    endfunction

     function automatic FpIntermediate roundNearestAway(input FpIntermediate x);
    	FpIntermediate res;

    	if (x.mantissa[31] == 1) return roundMagUp(x);
    	else return roundMagDown(x);
    endfunction




    function automatic FpFormat32 fromIntermediate(input FpIntermediate inter);
    	FpFormat32 res;
    	res.sign = inter.sign;
    	res.exp = inter.subn ? 0 : inter.exp;
    	res.mantissa = inter.mantissa[22+32:32];

    	return res;
    endfunction



    function automatic FpResult32 TMP_addF32(input FpFormat32 a, input FpFormat32 b, input Rounding rm);
    	// any SNaN -> Invalid, QNaN
    	// any QNaN -> copy the QNaN

    	FpFormat32 res, arg0, arg1;
    	logic sign;


    	if (isSNaN(a) || isSNaN(b))
	   		return '{'{invalid: 1, default: 0}, FP32_CANONICAL_QNAN};

	   	if (isQNaN(a))
	   		return '{NO_EXCEPTION, a};

	   	if (isQNaN(b))
	   		return '{NO_EXCEPTION, b};

	   	// Which input has bigger exponent?
	   	if (b.exp > a.exp) begin
			arg0 = b;
			arg1 = a;
	   	end
	   	else begin
	   		arg0 = a;
	   		arg1 = b;
	   	end

	   	// Now arg0 is at least a big in magnitude as arg1, NaNs have been handled
	   	if (isInfinity(arg0)) begin
	   		if (isInfinity(arg1)) begin
	   			if (a.sign == b.sign)
	   				return '{NO_EXCEPTION, arg0};
	   			else
	   				return '{'{invalid: 1 /*??*/, default: 0}, FP32_CANONICAL_QNAN};
	   		end
	   		else
	   			return '{NO_EXCEPTION, arg0};
	   	end

	   	// Now regular cases
	   	begin
	   		FpIntermediate inter, interRounded;

	   		if (arg0.sign != arg1.sign) inter = TMP_subMag(arg0, arg1);
	   		else inter = TMP_addMag(arg0, arg1);

	   		interRounded = roundInter(inter, rm);
	   		res = fromIntermediate(interRounded);

	   			$displayh("... %p\n... %p", inter, interRounded);

			$display(" %8X\n+%08X\n=%08X", arg0, arg1, res);
			$display("--------------------------");

	   		return '{NO_EXCEPTION, res};
	   	end

    endfunction


endpackage
