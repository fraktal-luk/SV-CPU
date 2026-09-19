
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




	function automatic FpIntermediate64 convToIntermediate64(input FpFormat64 a);
		Word expA = (a.exp == 0) ? a.exp + 1 : a.exp;
		Dword normA = (a.exp == 0) ? a.mantissa : ('h100000000000000000000000000000 | a.mantissa);

		// Shift a to upper Word of a Dword
		Qword fullA = {normA, Dword'(0)};

		return '{a.sign, (a.exp == 0), expA, fullA};
	endfunction

    function automatic FpFormat64 fromIntermediate64(input FpIntermediate64 inter);
    	FpFormat64 res;
    	res.sign = inter.sign;
    	res.exp = inter.subn ? 0 : inter.exp;
    	res.mantissa = inter.mantissa[51+64:64];

    	return res;
    endfunction




	// Shifts right, preserving 1 extra bit in [63] and 'permanent' bit in [62]
	function automatic Qword shiftCompress62(input Qword v, input int shift);
		Qword res = v;
		// Which bit will go to pos [63]?  v[63 + sh]
		// Which bit will go to pos [62]?  v[62 + sh]

		Qword mask = 'h1FFFFFFFFFFFFF;
		Qword mask62;

		if (shift >= 63)
			mask62 = (mask << shift) | 'hFFFFFFFFFFFFFFFF;
		else
			mask62 = (mask << shift) | mask;

		if (shift >= 66) begin
			if (v != 0) res = 'h4000000000000000;
			else res = 0;
		end
		else begin
			if ((v & mask62) != 0) res[62+shift] = 1;
			else 				   res[62+shift] = 0;

			res >>= shift;
		end

		return res;
	endfunction


	// Shifts right, preserving 2 extra bits in [31:30] and 'permanent' bit in [29]
	function automatic Qword shiftCompress61(input Qword v, input int shift);
		Qword res = v;
		// Which bit will go to pos [61]?  v[61 + sh]

		Qword mask = 'h000000003FFFFFFFFFFFFFFF;
		Qword mask61;

		if (shift >= 62)
			mask61 = (mask << shift) | 'hFFFFFFFFFFFFFFFF;
		else
			mask61 = (mask << shift) | mask;

		if (shift >= 66) begin
			if (v != 0) res = 'h2000000000000000;
			else res = 0;
		end
		else begin
			if ((v & mask61) != 0) res[61+shift] = 1;
			else 				   res[61+shift] = 0;

			res >>= shift;
		end

		return res;
	endfunction




	function automatic FpIntermediate64 addInter64(input FpIntermediate64 a, FpIntermediate64 b);
		FpIntermediate64 res, bSh;

		Dword ediff = a.exp - b.exp;
		Qword bShifted = shiftCompress62(b.mantissa, ediff);

		res.sign = a.sign;
		res.subn = a.subn;
		res.exp = a.exp;
		res.mantissa = a.mantissa + bShifted;

		bSh = '{b.sign, b.subn, a.exp, bShifted};

			/*$display("Nonc");
			dispInter("a: ", a);
			dispInter("b: ", bSh);
			dispInter(" = ", res);
			*/
		return res;
	endfunction


	function automatic FpIntermediate64 normalizeAdded64(input FpIntermediate64 a);
		FpIntermediate64 res;
		
		res.sign = a.sign;
		// Denorm: if bit [52] of mantissa becomes 1, we crossed to normal range
		if (a.subn) begin
			if (a.mantissa[64 + 52]) begin
				res.exp = 1; // We don't shift, the bit at [52] is accounted for by Normal exponent
				res.subn = 0;
			end
			else begin
				res.exp = 1;
				res.subn = 1;
			end
			res.mantissa = a.mantissa;
		end
		// Normal: if bit [53] becomes 1, exp increased and we need to normalize
		else if (a.mantissa[64 + 53] === 1) begin
			res.subn = 0;
			res.exp = a.exp + 1;
			res.mantissa = a.mantissa >> 1;
			// Now the bits [-1:-2] have shifted to [-2:-3], we must refill bit [-2] considering [-3]
			if (res.mantissa[62:61] != 0) res.mantissa[62:61] = 'h2;  
		end
		else begin
			res.exp = a.exp;
			res.subn = 0;
			res.mantissa = a.mantissa;
		end

		// If reached infinity
		if (res.exp >= EXP_MAX_64) begin
			res.exp = EXP_MAX_64;
			res.mantissa = 'h80000000000000000000000000000;
		end

		return res;
	endfunction





	function automatic FpIntermediate64 subInter64(input FpIntermediate64 a, FpIntermediate64 b);
		FpIntermediate64 res;

		FpIntermediate64 bSh;

		Dword ediff = a.exp - b.exp;
		Qword bShifted = shiftCompress61(b.mantissa, ediff);

		bSh = '{b.sign, b.subn, a.exp, bShifted};

		res.sign = a.sign;
		res.subn = a.subn;
		res.exp = a.exp;
		res.mantissa = a.mantissa - bShifted;

		/*	$display("Nonc");
			dispInter("a: ", a);
			dispInter("b: ", bSh);
			dispInter(" = ", res);
*/
		return res;
	endfunction



	function automatic FpIntermediate64 normalizeSubtracted64(input FpIntermediate64 a);
		FpIntermediate64 res;

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

				// We want MSB to be at [64 + 52];
				expShift = (64+52) - log;
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





    function automatic FpIntermediate64 TMP_addMag64(input FpFormat64 a, input FpFormat64 b);
    	FpIntermediate64 inter, interA, interB, interFull, interFull_Comp, interFullN, interFullCN;

    	assert (absF64(a) >= absF64(b)) else $error("Wrng, shoudl be abs(a) >= abs(b)");

    	begin
			Dword normA = (a.exp == 0) ? a.mantissa : ('h10000000000000 | a.mantissa);
			Dword normB = (b.exp == 0) ? b.mantissa : ('h10000000000000 | b.mantissa);

			interA = convToIntermediate64(a);
			interB = convToIntermediate64(b);

			//$display("Add  normA: %08X, normB: %08X", normA, normB);
			interFull = addInter64(interA, interB);

			interFullN = normalizeAdded64(interFull);
			//dispInter(" n ", interFullN);
    	end

    	return interFullN;
    endfunction



    function automatic FpIntermediate64 TMP_subMag64(input FpFormat64 a, input FpFormat64 b);
    	FpIntermediate64 inter, interA, interB, interFull, interFull_Comp, interFullN, interFullCN;

    	assert (absF64(a) >= absF64(b)) else $error("Wrng, shoudl be abs(a) >= abs(b)");

    	begin
			Dword normA = (a.exp == 0) ? a.mantissa : ('h10000000000000 | a.mantissa);
			Dword normB = (b.exp == 0) ? b.mantissa : ('h10000000000000 | b.mantissa);

			interA = convToIntermediate64(a);
			interB = convToIntermediate64(b);

			//$display("Sub  normA: %08X, normB: %08X", normA, normB);
			interFull = subInter64(interA, interB);
			interFullN = normalizeSubtracted64(interFull);
			//dispInter(" n ", interFullN);

			//$display("--------------------------");
    	end

    	return interFullN;
    endfunction 




    function automatic FpIntermediate64 multiplyInter64(input FpIntermediate64 a, input FpIntermediate64 b);
    	FpIntermediate64 res, aSh;

    	Word expOut = a.exp + b.exp - 1023; // 127 is the exp of 1.0

    	// Shifted by 12 to align with high sub-dword
    	Qword product = (a.mantissa << 12) * b.mantissa;

    	aSh = '{a.sign, a.subn, a.exp, a.mantissa << 12};

    	res.sign = a.sign ^ b.sign;
    	res.subn = 'x; // TODO
    	res.exp = expOut;
    	res.mantissa = product;

	    /*	$display("Mult");
	    	dispInter("a: ", aSh);
	    	dispInter("b: ", b);
	    	dispInter(" =", res);
*/
    	return res;
    endfunction



    // TODO: this doesn't distinguish zero of undefined sign form zero of defined sign (problem when rounding X - X vs +0 + +0 or -0 + -0)
    function automatic FpIntermediate64 roundInter64(input FpIntermediate64 x, input Rounding rd);
    	FpIntermediate64 res;

    	if (x.mantissa === 0)
    		return x;

    	case (rd)
    		RoundNearestEven:
    			res = roundNearestEven64(x);
    		RoundNearestAway:
    			res = roundNearestAway64(x);
    		RoundPlusInf:
    			if (x.sign) res = roundMagDown64(x);
    			else res = roundMagUp64(x);
    		RoundZero:
    			res = roundMagDown64(x);
    		RoundMinusInf:
    			if (x.sign) res = roundMagUp64(x);
    			else res = roundMagDown64(x);
    	endcase

    	return res;
    endfunction





    function automatic FpIntermediate64 roundMagUp64(input FpIntermediate64 x);
    	FpIntermediate64 res, xPlus;
    	Qword newMantissa;
    	if (x.mantissa[63:62] == 0) return x;

    	newMantissa = x.mantissa + 'h10000000000000000;
    	xPlus = '{x.sign, x.subn, x.exp, newMantissa};
    	res = normalizeAdded64(xPlus);
    	return res;
    endfunction

    function automatic FpIntermediate64 roundMagDown64(input FpIntermediate64 x);
    	FpIntermediate64 res;
    	Qword newMantissa = x.mantissa;
    	newMantissa[63:0] = 0;

    	res = '{x.sign, x.subn, x.exp, newMantissa};
    	return res;
    endfunction


    function automatic FpIntermediate64 roundNearestEven64(input FpIntermediate64 x);
    	FpIntermediate64 res;

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

    	case (x.mantissa[64:62])
    		'b111, 'b110, 'b011: return roundMagUp64(x);
    		default: return roundMagDown64(x);
    	endcase

    endfunction


    function automatic FpIntermediate64 roundNearestAway64(input FpIntermediate64 x);
    	FpIntermediate64 res;

    	if (x.mantissa[63] == 1) return roundMagUp64(x);
    	else return roundMagDown64(x);
    endfunction



    function automatic FpResult64 handleNanArgs64(input FpFormat64 a, input FpFormat64 b);
    	if (isSNaN64(a) || isSNaN64(b))
	   		return '{'{invalid: 1, default: 0}, FP64_CANONICAL_QNAN};

	   	if (isQNaN64(a))
	   		return '{NO_EXCEPTION, a};

	   	if (isQNaN64(b))
	   		return '{NO_EXCEPTION, b};

	   	$fatal(2, "Args are not NaN");
    endfunction



endpackage
