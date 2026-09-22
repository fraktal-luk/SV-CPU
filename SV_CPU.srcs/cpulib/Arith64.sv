
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



		function automatic void dispLong64(input string s, input Qword x);
			$display({s, "%016X|%016X"}, x >> 64, Dword'(x));
		endfunction


		function automatic void dispInter64(input string s, input FpIntermediate64 x);
			$display({s, "%d (%d) %016X|%016X"}, x.sign, x.exp, x.mantissa >> 64, Dword'(x.mantissa));
		endfunction




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
		Dword normA = (a.exp == 0) ? a.mantissa : ('h0010000000000000 | a.mantissa);

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

		Qword mask = 'h7FFFFFFFFFFFFFFF;
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
			res.mantissa = 'h100000000000000000000000000000;
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

				$display("Add  normA: %016X, normB: %016X", normA, normB);
			interFull = addInter64(interA, interB);

				dispInter64(" a ", interA);
				dispInter64(" b ", interB);

				dispInter64(" . ", interFull);

			interFullN = normalizeAdded64(interFull);
				dispInter64(" n ", interFullN);
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




    function automatic FpResult64 TMP_addF64(input FpFormat64 a, input FpFormat64 b, input Rounding rm);
    	FpFormat64 arg0, arg1;

    	if (isNaN64(a) || isNaN64(b))
    		return handleNanArgs64(a, b);

	   	// Which input has bigger exponent?
	   	//if (b.exp > a.exp) begin
	   	if (absF64(b) >= absF64(a)) begin
			arg0 = b;
			arg1 = a;
	   	end
	   	else begin
	   		arg0 = a;
	   		arg1 = b;
	   	end

	   	// Now arg0 is at least a big in magnitude as arg1, NaNs have been handled
	   	if (isInfinity64(arg0)) begin
	   		if (isInfinity64(arg1)) begin
	   			if (arg0.sign == arg1.sign)
	   				return '{NO_EXCEPTION, arg0};
	   			else
	   				return '{'{invalid: 1, default: 0}, FP64_CANONICAL_QNAN};
	   		end
	   		else
	   			return '{NO_EXCEPTION, arg0};
	   	end

	   	return addRegularF64(arg0, arg1, rm);
    endfunction


  function automatic FpResult64 TMP_subF64(input FpFormat64 a, input FpFormat64 b, input Rounding rm);
    	FpFormat64 arg0, arg1;

    	if (isNaN64(a) || isNaN64(b))
    		return handleNanArgs64(a, b);

	   	// Which input has bigger exponent?
	   	if (b.exp > a.exp) begin
			arg0 = negateF64(b);
			arg1 = a;
	   	end
	   	else begin
	   		arg0 = a;
	   		arg1 = negateF64(b);
	   	end

	   	// Now arg0 is at least a big in magnitude as arg1, NaNs have been handled
	   	if (isInfinity64(arg0)) begin
	   		if (isInfinity64(arg1)) begin
	   			if (arg0.sign == arg1.sign)
	   				return '{NO_EXCEPTION, arg0};
	   			else
	   				return '{'{invalid: 1, default: 0}, FP32_CANONICAL_QNAN};
	   		end
	   		else
	   			return '{NO_EXCEPTION, arg0};
	   	end

	   	return addRegularF64(arg0, arg1, rm);
    endfunction



    // CAREFUL: assumes abs(arg0) >= abs(arg1)
    function automatic FpResult64 addRegularF64(input FpFormat64 arg0, input FpFormat64 arg1, input Rounding rm);
   		FpFormat64 res;
   		logic inexact, overflow, underflow = 0;
   		FpIntermediate64 inter, interRounded;

   		if (arg0.sign != arg1.sign) inter = TMP_subMag64(arg0, arg1);
   		else inter = TMP_addMag64(arg0, arg1);

   		if (inter.mantissa[63:0] != 0) inexact = 1;
   		else inexact = 0;

   		interRounded = roundInter64(inter, rm);

   		if (interRounded.mantissa == 0 && (arg0.sign != arg1.sign)) begin
   			if (rm == RoundMinusInf) interRounded.sign = 1;
   			else interRounded.sign = 0;
   		end

   		if (interRounded.exp >= EXP_MAX_64) overflow = 1;
   		else overflow = 0;

   		if (overflow || underflow) inexact = 1;

   		res = fromIntermediate64(interRounded);

   			/*$displayh("... %p\n... %p", inter, interRounded);
			$display(" %8X\n+%08X\n=%08X", arg0, arg1, res);
			$display("--------------------------");
*/
   		return '{'{inexact: inexact, overflow: overflow, underflow: underflow, default: 0}, res};
    endfunction



    // TODO: exact and non-exact variants:
    //			exact signals Inexact when input is not integer
    function automatic FpResult64 TMP_roundToInteger64(input FpFormat64 x, input Rounding rm);
    	// If SNaN input -> Invalid
    	// If QNaN or inf -> copy?

    	FpFormat64 res;
    	FpIntermediate64 inter, interRounded;
    	logic isInexact = 0;

    	if (isSNaN64(x))
    		return '{'{invalid: 1, default: 0}, FP64_CANONICAL_QNAN};

    	if (isQNaN64(x) || isInfinity64(x))
    		return '{NO_EXCEPTION, x};

    	inter = convToIntermediate64(x);

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

    	if (inter.exp >= 1023 + 52) begin
    		interRounded = inter;
    			//$display("   Big");
    	end
    	else if (inter.exp <= 1023 - 2) begin
    		logic dirUp = 0;

    			//$display("  Small");

    		interRounded = inter;
    		if (inter.mantissa != 0)
    			interRounded.mantissa = 'h000000004000000000000000;

    		// TODO: now detect Inexact - is Inexact if mantissa[31:0] != 0
    		if (interRounded.mantissa[63:0] !== 0) isInexact = 1;

    		case (rm)
	    		RoundNearestEven: ;	    			
	    		RoundNearestAway: ;
	    		RoundPlusInf:
	    			dirUp = !inter.sign && (interRounded.mantissa != 0);
	    		RoundZero: ;
	    		RoundMinusInf:
	    			dirUp = inter.sign && (interRounded.mantissa != 0);
    		endcase

    		if (dirUp) interRounded.mantissa += 'h10000000000000000;

    		interRounded.mantissa[63:0] = 0;

    		interRounded.mantissa = interRounded.mantissa << 52;
    		interRounded.exp = 1023;
    		interRounded.subn = 0;

    		interRounded = normalizeAdded64(interRounded);

    		 //   $displayh("inter__A____: %p\ninterRounded: %p", inter, interRounded);
    	end
    	else begin
    		logic dirUp = 0;
    		int sh = 1023 + 52 - inter.exp;
    		Qword shiftedMantissa = shiftCompress62(inter.mantissa, sh);
    		// TODO: now detect Inexact - is Inexact if mantissa[31:0] != 0

    		if (shiftedMantissa[63:0] !== 0) isInexact = 1;

    		interRounded = inter;

    		case (rm)
	    		RoundNearestEven:
	    			if (shiftedMantissa[64:62] inside {'b111, 'b110, 'b011}) dirUp = 1;
	    		RoundNearestAway:
	    			if (shiftedMantissa[63:62] inside {'b10, 'b11}) dirUp = 1;
	    		RoundPlusInf:
	    			dirUp = !inter.sign && (shiftedMantissa[63:62] != 0);
	    		RoundZero:
	    			dirUp = 0;
	    		RoundMinusInf:
	    			dirUp = inter.sign && (shiftedMantissa[63:62] != 0);
    		endcase

    		if (dirUp) shiftedMantissa += 'h10000000000000000;

    		shiftedMantissa[63:0] = 0;

    		interRounded.mantissa = shiftedMantissa << sh;

    		interRounded = normalizeAdded64(interRounded);

    		//    $displayh("inter__B____: %p\ninterRounded: %p", inter, interRounded);
    	end

    	if (interRounded.mantissa == 0) begin
    		interRounded.exp = 1;
    		interRounded.subn = 1;
    	end

    	res = fromIntermediate64(interRounded);

    	//	$display("Rounded %.10f -> %.10f\n", $bitstoshortreal(x), $bitstoshortreal(res));

    	return '{'{inexact: isInexact, default: 0}, res};
    endfunction





    function automatic FpResult64 TMP_cmpF64(input FpFormat64 a, input FpFormat64 b, input CmpPredicate pred, input logic signalling);
    	logic answer;
    	Relation r;

    	Dword ma = absF64(a);
    	Dword mb = absF64(b);

    	if (isSNaN64(a) || isSNaN64(b))
    		return '{'{invalid: 1, default: 0}, FP64_CANONICAL_QNAN}; // ???

    	r = cmpInternalF64(a, b);

    	if (signalling && (r == R_UNORDERED))
    		return '{'{invalid: 1, default: 0}, FP64_CANONICAL_QNAN}; // ???

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

    	if (answer) return '{NO_EXCEPTION, 1};
    	else return '{NO_EXCEPTION, 0};
    endfunction



    function automatic Relation cmpInternalF64(input FpFormat64 a, input FpFormat64 b);
    	Dword ma = absF64(a);
    	Dword mb = absF64(b);

    	if (isNaN64(a) || isNaN64(b))
    		return R_UNORDERED;
    	else if (isZero64(a) && isZero64(b))
    		return R_EQUAL;
    	else if (!a.sign && !b.sign) begin
    		if (ma > mb) return R_GREATER;
    		if (ma < mb) return R_LESS;
    		return R_EQUAL;
    	end
    	else if (!a.sign && b.sign)
    		return R_GREATER;
    	else if (a.sign && !b.sign)
    		return R_LESS;
    	else if (a.sign && b.sign) begin
    		if (ma > mb) return R_LESS;
    		if (ma < mb) return R_GREATER;
    		return R_EQUAL;
    	end
    endfunction






    function automatic FpResult64 TMP_int64toFP64(input Dword x, input logic isSigned, input Rounding rm);
    	logic sign = 0;
    	logic inexact;
    	Dword absX;

    	if (isSigned) sign = x[63];

    	absX = sign ? -x : x; // If x is the most negative number, no problem because it will stay the same in bits
    						  // but be interpreted as unsigned magnitude

    	if (absX == 0) begin
    		if (rm == RoundMinusInf) // ???
    			return '{NO_EXCEPTION, FP64_MINUS_ZERO};
    		else
    			return '{NO_EXCEPTION, FP64_PLUS_ZERO};
    	end
    	begin
    		Qword mantissa, mantissaC;
    		FpIntermediate64 inter, interRounded;
    		FpFormat64 result;

    		// Determine exp
			int exp, shiftNeeded;
			int wantedMag = 64 + 52;
			int log = $clog2(absX);
			if (absX[log] === 0) log--;

			// log == 0 corresponds to exp 127
			exp = 1023 + log;

			// We want MSB of input at index [23 + 32] of extended mantissa
			shiftNeeded = wantedMag - log;

			if (shiftNeeded >= 0)
				mantissa = absX << shiftNeeded;
			else
				mantissa = absX >> -shiftNeeded;

			mantissaC = shiftCompress62(mantissa, 0);


			inter = '{sign, 0, exp, mantissaC};

			inexact = (inter.mantissa[63:0] != 0);

			interRounded = roundInter64(inter, rm);

			//	$display(" conv: %016X  -> (%d) %016X // (%d) %016X", absX, exp, mantissa,  exp,  mantissaC);

			result = fromIntermediate64(interRounded);

			//	$displayh("    rounded: %p\n %d -> %.2f", interRounded,  x, $bitstoshortreal(result));

			return '{'{inexact: inexact, default: 0}, result};
    	end

    endfunction





    // FP -> Int: when is input out of range?
    // range u32: [0, 2^32)		 - sign 0, exp 127+31 ; -0 is allowed!   What about range (-1, 0) if rounded up?
    // range s32: [-2^31, 2^31)  - exp 127+30; if sign 1, then exp 127+31 with 0 mantissa is allowed	
    // range u64: [0, 2^64)		 - sign 0, exp 127+63 ; -0 is allowed!   What about range (-1, 0) if rounded up?
    // range s64: [-2^63, 2^63)  - exp 127+62; if sign 1, then exp 127+63 with 0 mantissa is allowed
    function automatic FpResult64 fp64toInt64(input FpFormat64 x, input Rounding rm, input logic isSigned);
    	if (isSNaN64(x))
    		return '{'{invalid: 1, default: 0}, 0};

    	// QNaN treated the same as SNaN?
       	if (isQNaN64(x))
    		return '{'{invalid: 1, default: 0}, 0};
	
    	begin
	    	FpResult64 res;
	    	Qword mantissaSh;
	    	Dword intValue;

	    	FpResult64 fpRounded = TMP_roundToInteger64(x, rm);
	    	FpIntermediate64 inter = convToIntermediate64(fpRounded.value);

	    	int shiftNeeded = 1023 - inter.exp + 52;

	    	// Check range
	    	if (isSigned) begin
	    		// Effective power above 62 is invalid, unless special case: sign negative, eff power == 63 AND mantissa[64+51:64] == 0
	    		if (int'(inter.exp) - 1023 > 62) begin
	    			if (inter.sign && inter.exp - 1023 == 63 && inter.mantissa[51+64:64] === 0) /* Allowed */;
	    			else
	    				return '{'{invalid: 1, default: 0}, 0};
	    		end
	    	end
	    	else begin
	    		if (int'(inter.exp) - 1023 > 63) // Effective power above 63 is invalid
	    			return '{'{invalid: 1, default: 0}, 0};

	    		if (inter.sign && !isZero64(x)) // Negative are invalid unless zero
	    			return '{'{invalid: 1, default: 0}, 0};
	    	end


	    	if (shiftNeeded >= 0)
	    		mantissaSh = inter.mantissa >> shiftNeeded;
	    	else
	    		mantissaSh = inter.mantissa << -shiftNeeded;

	    	if (isSigned && inter.sign)
	    		intValue = -mantissaSh[127:64];
	    	else
	    		intValue = mantissaSh[127:64];

	    	res = '{'{inexact: fpRounded.exc.inexact, default: 0}, intValue};

	    	return res;
    	end
    endfunction



    	function automatic FpIntermediate narrowIntermediate(input FpIntermediate64 x);
    		FpIntermediate inter;

    		inter.sign = x.sign;
    		inter.subn = 0;
    		inter.exp = x.exp; 
    		inter.mantissa = x.mantissa >> (52-23 + 32);

    		return inter;
    	endfunction 



    function automatic FpResult32 convertF64to32(input FpFormat64 x, input Rounding rm);
    	int effPower = x.exp - 1023;

    	FpIntermediate64 inter64 = convToIntermediate64(x);
    	FpIntermediate inter32 = narrowIntermediate(inter64);

    	// handle SNaN
    	// QNaN copy
    	// inf copy
    	if (isSNaN64(x))
    		return '{'{invalid: 1}, FP32_CANONICAL_QNAN};

    	if (isQNaN64(x))
    		return '{NO_EXCEPTION, FP32_CANONICAL_QNAN}; // TODO: preserve payload

    	if (isInfinity64(x)) begin
    		if (x.sign) return '{NO_EXCEPTION, FP32_MINUS_INF};
    		else return '{NO_EXCEPTION, FP32_PLUS_INF};
    	end

    	if (isZero64(x)) begin
    		if (x.sign) return '{NO_EXCEPTION, FP32_MINUS_ZERO};
    		else return '{NO_EXCEPTION, FP32_PLUS_ZERO};
    	end

    	// else:
    	//  effective exp > 128 -> inf Ov Inex? | max finite Inex? (dep on rounding?)
    	//  effective exp <= -127 -> subnormal, may underflow? 
    	//  mantissa over precision -> round Inex ?
    	//  else trunc

    	if  (effPower > 127) begin
    		// Too big

    	end
    	else if (effPower < -126) begin
    		int expShift;
			logic inexact, und;// = inter32.mantissa[31:0] != 0;
			FpIntermediate rounded;// = roundInter(inter32, rm);
			FpFormat32 res;// = fromIntermediate(rounded);

			inter32.exp += (127-1023);
			inter32.mantissa = shiftCompress30(inter32.mantissa, 0); // Shift by 0 to correctly encode bits [-1:-2]

			expShift = 1 - inter32.exp;

			inter32.mantissa = shiftCompress30(inter32.mantissa, expShift);
			inter32.exp = 1;
			inter32.subn = 1;

			inexact = inter32.mantissa[31:0] != 0;

			rounded = roundInter(inter32, rm);

			und = rounded.mantissa == 0;

			res = fromIntermediate(rounded);

			return '{'{inexact: inexact, underflow: und, default: 0}, res};		
    	end
		else begin
			logic inexact = inter32.mantissa[31:0] != 0;
			logic ov;
			FpIntermediate rounded;// = roundInter(inter32, rm);
			FpFormat32 res;// = fromIntermediate(rounded);


			inter32.exp += (127-1023);
			inter32.mantissa = shiftCompress30(inter32.mantissa, 0); // Shift by 0 to correctly encode bits [-1:-2]

			rounded = roundInter(inter32, rm);

			//rounded.exp += (127 - 1023);

			ov = rounded.exp > 254;
			
				$displayh("inter64: %p", inter64);
				$displayh("inter32: %p", inter32);
				$displayh("rounded: %p", rounded);

			res = fromIntermediate(rounded);

			return '{'{inexact: inexact, overflow: ov, default: 0}, res};
		end

    	return '{NO_EXCEPTION, 'x};
    endfunction


    function automatic FpResult64 convertF32to64();
    	// handle SnaN
    	// QNan copy
    	// inf copy

    	// else:
    	// zero: extend
    	// subn: normalize into F64
    	// normal: exp - 127 + 1023, extend

    	return '{NO_EXCEPTION, 'x};
    endfunction



endpackage
