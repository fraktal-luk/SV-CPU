
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
    	return a.exp < EXP_MAX_32;
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


  	function automatic isNaN(input FpFormat32 a);
    	return a.exp == EXP_MAX_32 && a.mantissa !== 0;
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
		Word expA = (a.exp == 0) ? a.exp + 1 : a.exp;
		Word normA = (a.exp == 0) ? a.mantissa : ('h800000 | a.mantissa);

		// Shift a to upper Word of a Dword
		Dword fullA = {normA, Word'(0)};

		return '{a.sign, (a.exp == 0), expA, fullA};
	endfunction

    function automatic FpFormat32 fromIntermediate(input FpIntermediate inter);
    	FpFormat32 res;
    	res.sign = inter.sign;
    	res.exp = inter.subn ? 0 : inter.exp;
    	res.mantissa = inter.mantissa[22+32:32];

    	return res;
    endfunction



	// Shifts right, preserving 1 extra bit in [31] and 'permanent' bit in [30]
	function automatic Dword shiftCompress30(input Dword v, input int shift);
		Dword res = v;
		// Which bit will go to pos [31]?  v[31 + sh]
		// Which bit will go to pos [30]?  v[30 + sh]

		Dword mask = 'h000000007FFFFFFF;
		Dword mask30;

		if (shift >= 31)
			mask30 = (mask << shift) | 'hFFFFFFFF;
		else
			mask30 = (mask << shift) | mask;

		if (shift >= 33) begin
			if (v != 0) res = 'h40000000;
			else res = 0;
		end
		else begin
			if ((v & mask30) != 0) res[30+shift] = 1;
			else 				 res[30+shift] = 0;

			res >>= shift;
		end

		return res;
	endfunction

	// Shifts right, preserving 2 extra bits in [31:30] and 'permanent' bit in [29]
	function automatic Dword shiftCompress29(input Dword v, input int shift);
		Dword res = v;
		// Which bit will go to pos [29]?  v[29 + sh]

		Dword mask = 'h000000003FFFFFFF;
		Dword mask29;

		if (shift >= 30)
			mask29 = (mask << shift) | 'hFFFFFFFF;
		else
			mask29 = (mask << shift) | mask;

		if (shift >= 34) begin
			if (v != 0) res = 'h20000000;
			else res = 0;
		end
		else begin
			if ((v & mask29) != 0) res[29+shift] = 1;
			else 				   res[29+shift] = 0;

			res >>= shift;
		end

		return res;
	endfunction


	function automatic FpIntermediate addInter(input FpIntermediate a, FpIntermediate b);
		FpIntermediate res, bSh;

		Word ediff = a.exp - b.exp;
		Dword bShifted = shiftCompress30(b.mantissa, ediff);

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
		else begin
			res.exp = a.exp;
			res.subn = 0;
			res.mantissa = a.mantissa;
		end

		// If reached infinity
		if (res.exp >= EXP_MAX_32) begin
			res.exp = EXP_MAX_32;
			res.mantissa = 'h80000000000000;
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
		Dword bShifted = shiftCompress29(b.mantissa, ediff);

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



	function automatic FpIntermediate normalizeSubtracted(input FpIntermediate a);
		FpIntermediate res;

		res.sign = a.sign;

		// We need to normalize if MSB fell to the right
		if (a.subn) begin
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
			Word normA = (a.exp == 0) ? a.mantissa : ('h800000 | a.mantissa);
			Word normB = (b.exp == 0) ? b.mantissa : ('h800000 | b.mantissa);

			interA = convToIntermediate(a);
			interB = convToIntermediate(b);

			$display("Add  normA: %08X, normB: %08X", normA, normB);
			interFull = addInter(interA, interB);

			interFullN = normalizeAdded(interFull);
			dispInter(" n ", interFullN);
    	end

    	return interFullN;
    endfunction



    function automatic FpIntermediate TMP_subMag(input FpFormat32 a, input FpFormat32 b);
    	FpIntermediate inter, interA, interB, interFull, interFull_Comp, interFullN, interFullCN;

    	assert (absF32(a) >= absF32(b)) else $error("Wrng, shoudl be abs(a) >= abs(b)");

    	begin
			Word normA = (a.exp == 0) ? a.mantissa : ('h800000 | a.mantissa);
			Word normB = (b.exp == 0) ? b.mantissa : ('h800000 | b.mantissa);

			interA = convToIntermediate(a);
			interB = convToIntermediate(b);

			$display("Sub  normA: %08X, normB: %08X", normA, normB);
			interFull = subInter(interA, interB);
			interFullN = normalizeSubtracted(interFull);
			dispInter(" n ", interFullN);

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


    // TODO: this doesn't distinguish zero of undefined sign form zero of defined sign (problem when rounding X - X vs +0 + +0 or -0 + -0)
    function automatic FpIntermediate roundInter(input FpIntermediate x, input Rounding rd);
    	FpIntermediate res;

    	if (x.mantissa === 0)
    		return x;

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

    endfunction

    function automatic FpIntermediate roundNearestAway(input FpIntermediate x);
    	FpIntermediate res;

    	if (x.mantissa[31] == 1) return roundMagUp(x);
    	else return roundMagDown(x);
    endfunction


    function automatic FpResult32 handleNanArgs(input FpFormat32 a, input FpFormat32 b);
    	if (isSNaN(a) || isSNaN(b))
	   		return '{'{invalid: 1, default: 0}, FP32_CANONICAL_QNAN};

	   	if (isQNaN(a))
	   		return '{NO_EXCEPTION, a};

	   	if (isQNaN(b))
	   		return '{NO_EXCEPTION, b};

	   	$fatal(2, "Args are not NaN");
    endfunction



    function automatic FpResult32 TMP_addF32(input FpFormat32 a, input FpFormat32 b, input Rounding rm);
    	FpFormat32 arg0, arg1;

    	if (isNaN(a) || isNaN(b))
    		return handleNanArgs(a, b);

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
	   			if (arg0.sign == arg1.sign)
	   				return '{NO_EXCEPTION, arg0};
	   			else
	   				return '{'{invalid: 1, default: 0}, FP32_CANONICAL_QNAN};
	   		end
	   		else
	   			return '{NO_EXCEPTION, arg0};
	   	end

	   	return addRegularF32(arg0, arg1, rm);
    endfunction


  function automatic FpResult32 TMP_subF32(input FpFormat32 a, input FpFormat32 b, input Rounding rm);
    	FpFormat32 arg0, arg1;

    	if (isNaN(a) || isNaN(b))
    		return handleNanArgs(a, b);

	   	// Which input has bigger exponent?
	   	if (b.exp > a.exp) begin
			arg0 = negateF32(b);
			arg1 = a;
	   	end
	   	else begin
	   		arg0 = a;
	   		arg1 = negateF32(b);
	   	end

	   	// Now arg0 is at least a big in magnitude as arg1, NaNs have been handled
	   	if (isInfinity(arg0)) begin
	   		if (isInfinity(arg1)) begin
	   			if (arg0.sign == arg1.sign)
	   				return '{NO_EXCEPTION, arg0};
	   			else
	   				return '{'{invalid: 1, default: 0}, FP32_CANONICAL_QNAN};
	   		end
	   		else
	   			return '{NO_EXCEPTION, arg0};
	   	end

	   	return addRegularF32(arg0, arg1, rm);
    endfunction



    // CAREFUL: assumes abs(arg0) >= abs(arg1)
    function automatic FpResult32 addRegularF32(input FpFormat32 arg0, input FpFormat32 arg1, input Rounding rm);
   		FpFormat32 res;
   		logic inexact, overflow, underflow = 0;
   		FpIntermediate inter, interRounded;

   		if (arg0.sign != arg1.sign) inter = TMP_subMag(arg0, arg1);
   		else inter = TMP_addMag(arg0, arg1);

   		if (inter.mantissa[31:0] != 0) inexact = 1;
   		else inexact = 0;

   		interRounded = roundInter(inter, rm);

   		if (interRounded.mantissa == 0 && (arg0.sign != arg1.sign)) begin
   			if (rm == RoundMinusInf) interRounded.sign = 1;
   			else interRounded.sign = 0;
   		end


   		if (interRounded.exp >= EXP_MAX_32) overflow = 1;
   		else overflow = 0;

   		if (overflow || underflow) inexact = 1;

   		res = fromIntermediate(interRounded);

   			$displayh("... %p\n... %p", inter, interRounded);

		$display(" %8X\n+%08X\n=%08X", arg0, arg1, res);
		$display("--------------------------");

   		return '{'{inexact: inexact, overflow: overflow, underflow: underflow, default: 0}, res};
    endfunction



    // TODO: exact and non-exact variants:
    //			exact signals Inexact when input is not integer
    function automatic FpResult32 TMP_roundToInteger(input FpFormat32 x, input Rounding rm);
    	// If SNaN input -> Invalid
    	// If QNaN or inf -> copy?

    	FpFormat32 res;
    	FpIntermediate inter = convToIntermediate(x), interRounded;

    	// LSB of integer range [127]
    	// if exp == 127, implicit '1' (m[23]) is the Unit bit
    	// if exp == 150, m[0] is the Unit bit
    	// if exp > 150, Unit bit is lower than eps
    	// if exp == 126, Unit bit is 0, m[23] is at[-1], m[22:0] goes to [-2]
    	// if exp == 125, Unit bit is 0, [-1] is 0, all mantissa goes to [-2]
    	// if exp < 125, the above applies too

    	// exp >= 150 -> stays the same
    	// exp <= 125 -> [-1:-2] = {0, mantissa != 0};  the result will have exp 127

    	// when 125 < exp < 150:
    	//	shift right by (150-exp) 
    	// 	round
    	//  shift back left (remember that at rounding exp may have grown by 1)

    	if (inter.exp >= 150) begin
    		interRounded = inter;
    	end
    	else if (inter.exp <= 125) begin
    		logic dirUp = 0;
    		interRounded = inter;
    		if (inter.mantissa != 0)
    			interRounded.mantissa = 'h0000000040000000;

    		// TODO: now detect Inexact - is Inexact if mantissa[31:0] != 0


    		case (rm)
	    		RoundNearestEven: ;	    			
	    		RoundNearestAway: ;
	    		RoundPlusInf:
	    			dirUp = !inter.sign && (interRounded.mantissa != 0);
	    		RoundZero: ;
	    		RoundMinusInf:
	    			dirUp = inter.sign && (interRounded.mantissa != 0);
    		endcase

    		if (dirUp) interRounded.mantissa += 'h100000000;

    		interRounded.mantissa[31:0] = 0;

    		interRounded.mantissa = interRounded.mantissa << 23;
    		interRounded.exp = 127;
    		interRounded.subn = 0;

    		interRounded = normalizeAdded(interRounded);

    		    		$displayh("inter__A____: %p\ninterRounded: %p", inter, interRounded);

    	end
    	else begin
    		logic dirUp = 0;
    		int sh = 150 - inter.exp;
    		Dword shiftedMantissa = shiftCompress30(inter.mantissa, sh);
    		// TODO: now detect Inexact - is Inexact if mantissa[31:0] != 0

    		interRounded = inter;

    		case (rm)
	    		RoundNearestEven:
	    			if (shiftedMantissa[32:30] inside {'b111, 'b110, 'b011}) dirUp = 1;
	    		RoundNearestAway:
	    			if (shiftedMantissa[31:30] inside {'b10, 'b11}) dirUp = 1;
	    		RoundPlusInf:
	    			dirUp = !inter.sign && (shiftedMantissa[31:30] != 0);
	    		RoundZero:
	    			dirUp = 0;
	    		RoundMinusInf:
	    			dirUp = inter.sign && (shiftedMantissa[31:30] != 0);
    		endcase

    		if (dirUp) shiftedMantissa += 'h100000000;

    		shiftedMantissa[31:0] = 0;

    		interRounded.mantissa = shiftedMantissa << sh;

    		interRounded = normalizeAdded(interRounded);

    		    		$displayh("inter__B____: %p\ninterRounded: %p", inter, interRounded);

    	end

    	if (interRounded.mantissa == 0) begin
    		interRounded.exp = 1;
    		interRounded.subn = 1;
    	end

    	res = fromIntermediate(interRounded);

    		$display("Rounded %.10f -> %.10f\n", $bitstoshortreal(x), $bitstoshortreal(res));

    	return '{NO_EXCEPTION, res};
    endfunction


    typedef enum {
    	R_EQUAL, R_GREATER, R_LESS, R_UNORDERED
    } Relation;


    typedef enum {
    	CMP_EQ, CMP_NE,
    	CMP_GT, CMP_GE, CMP_GU, CMP_NG,
    	CMP_LT, CMP_LE, CMP_LU, CMP_NL,
    	CMP_UN, CMP_OR
    } CmpPredicate;


    function automatic FpResult32 TMP_cmpF32(input FpFormat32 a, input FpFormat32 b, input CmpPredicate pred, input logic signalling);
    	logic answer;

    	// Magnitude
    	Word ma = absF32(a);
    	Word mb = absF32(b);

    	Relation r;

    	if (isSNaN(a) || isSNaN(b)) begin
    		// Signal Invqlid 
    		return '{{invalid: 1, default: 0}, FP32_CANONICAL_QNAN}; // ???
    	end

    	r = cmpInternalF32(a, b);

    	if (signalling && (r == R_UNORDERED)) begin
    		// signal Invalid
    		return '{{invalid: 1, default: 0}, FP32_CANONICAL_QNAN}; // ???
    	end

    	case (pred)
    		CMP_EQ: answer = r == R_EQUAL;
    		CMP_NE: answer = r != R_EQUAL; 
    		
    		CMP_GT: answer = r == R_GREATER;
    		CMP_GE: answer = r inside {R_GREATER, R_EQUAL};
    		CMP_GU: answer = r inside {R_GREATER, R_UNORDERED};
    		CMP_NG: answer = r != R_GREATER; 

    		CMP_LT: answer = r == R_LESS;
    		CMP_LE: answer = r inside {R_LESS, R_EQUAL};
    		CMP_LU: answer = r inside {R_LESS, R_UNORDERED};
    		CMP_NL: answer = r != R_LESS;

    		CMP_UN: answer = r == R_UNORDERED;
    		CMP_OR: answer = r != R_UNORDERED;
    	endcase

    	if (answer) return '{NO_EXCEPTION, FP32_PLUS_MIN_SUBN};
    	else return '{NO_EXCEPTION, FP32_PLUS_ZERO};
    endfunction



    function automatic Relation cmpInternalF32(input FpFormat32 a, input FpFormat32 b);
    	logic eq, gt = 0, lt = 0, un = 0, invalid = 1;

    	// Magnitude
    	Word ma = absF32(a);
    	Word mb = absF32(b);

    	if (isNaN(a) || isNaN(b)) return R_UNORDERED;
    	else if (isZero(a) && isZero(b)) return R_EQUAL;
    	else if (!a.sign && !b.sign) begin
    		gt = ma > mb;
    		lt = ma < mb;
    		eq = ma == mb;

    		if (ma > mb) return R_GREATER;
    		if (ma < mb) return R_LESS;
    		return R_EQUAL;
    	end
    	else if (!a.sign && b.sign) begin
    		return R_GREATER;
    	end
    	else if (a.sign && !b.sign) begin
    		return R_LESS;
    	end
    	else if (a.sign && b.sign) begin
    		if (ma > mb) return R_LESS;
    		if (ma < mb) return R_GREATER;
    		return R_EQUAL;
    	end
    endfunction



endpackage
