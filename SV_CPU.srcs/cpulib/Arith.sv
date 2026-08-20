
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






    typedef struct {
    	logic sign;
    	logic subn;
    	Word exp;
    	Dword mantissa;
    } FpIntermediate;





	    // TODO: rounding
	    function automatic FpResult32 TMP_addF32(input FpFormat32 a, input FpFormat32 b);
	    	// any SNaN -> Invalid, QNaN
	    	// any QNaN -> copy the QNaN

	    	logic sign;


	    	if (isSNaN(a) || isSNaN(b))
		   		return '{'{invalid: 1, default: 0}, FP32_CANONICAL_QNAN};

		   	if (isQNaN(a))
		   		return '{NO_EXCEPTION, a};

		   	if (isQNaN(b))
		   		return '{NO_EXCEPTION, b};

		   	// Which input has bigger exponent?
		   	if (b.exp > a.exp) begin
				sign = b.sign;

		   		// Different signs?
		   		//if (a.sign != b.sign)


		   		// Same sign?
		   	end
		   	else begin
		   		
		   	end


	    endfunction







	function automatic FpIntermediate addInter(input FpIntermediate a, FpIntermediate b);
		FpIntermediate res;

		Word ediff = a.exp - b.exp;
		Dword bShifted = b.mantissa >> ediff;

		res.sign = a.sign;
		res.subn = a.subn;
		res.exp = a.exp;
		res.mantissa = a.mantissa + bShifted;

			$display("Nonc");
			$display("a: %08X|%08X", a.mantissa >> 32, Word'(a.mantissa));
			$display("b: %08X|%08X", bShifted >> 32, Word'(bShifted));
			$display("=: %08X|%08X", res.mantissa >> 32, Word'(res.mantissa));

		return res;
	endfunction


	function automatic FpIntermediate addInter_Comp(input FpIntermediate a, FpIntermediate b);
		FpIntermediate res;

		Word ediff = a.exp - b.exp;
		Dword bShifted = b.mantissa >> ediff;

		// bit 30 will represent all bits from it downwards
		if (bShifted[30:0] == 0) bShifted[30:0] = 0;
		else					 bShifted[30:0] = 'h40000000;

		res.sign = a.sign;
		res.subn = a.subn;
		res.exp = a.exp;
		res.mantissa = a.mantissa + bShifted;

			$display("Comp");
			$display("a: %08X|%08X", a.mantissa >> 32, Word'(a.mantissa));
			$display("b: %08X|%08X", bShifted >> 32, Word'(bShifted));
			$display("=: %08X|%08X", res.mantissa >> 32, Word'(res.mantissa));

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
			res.exp = a.exp + 1;
			res.mantissa = a.mantissa >> 1;
			// Now the bits [-1:-2] have shifted to [-2:-3], we must refill bit [-2] considering [-3]
			if (res.mantissa[30:29] != 0) res.mantissa[30:29] = 'h2;  
		end

		return res;
	endfunction




    function automatic FpIntermediate TMP_addMag(input FpFormat32 a, input FpFormat32 b);
    	FpIntermediate inter, interA, interB, interFull, interFull_Comp, interFullN, interFullCN;

    	assert (absF32(a) >= absF32(b)) else $error("Wrng, shoudl be abs(a) >= abs(b)");

    	begin
			Word expA = isSubnormal(a) ? a.exp + 1 : a.exp;
			Word expB = isSubnormal(b) ? b.exp + 1 : b.exp;
			//Word ediff = a.exp - b.exp;

			//Word expOut = expA;

			Word normA = isSubnormal(a) ? a.mantissa : ('h800000 | a.mantissa);
			Word normB = isSubnormal(b) ? b.mantissa : ('h800000 | b.mantissa);

			// Shift a to upper Word of a Dword
			Dword fullA = {normA, Word'(0)};
			Dword fullB = {normB, Word'(0)};

			// Dword shiftedB = fullB >> ediff; // TODO: 'persistent' bit
			// Dword summed = fullA + shiftedB;

			// Dword compressedB = shiftedB;
			// Dword summed_C;

			// if (shiftedB[30:0] === 0) compressedB[30:0] = 'h00000000;
			// else					  compressedB[30:0] = 'h40000000; 

			// summed_C = fullA + compressedB;

			interA = '{a.sign, isSubnormal(a), expA, fullA};
			interB = '{b.sign, isSubnormal(b), expB, fullB};


			$display("Add");
			$display("normA: %08X", normA);
			$display("normB: %08X", normB);

			interFull = addInter(interA, interB);
			interFull_Comp = addInter_Comp(interA, interB);

			// inter.sign = a.sign;
			// inter.exp = expOut;
			// inter.mantissa = summed;

				//assert (interFull.mantissa === summed) else $fatal(2, "ggg");
				//assert (interFull_Comp.mantissa === summed_C) else $fatal(2, "ggg C");

			$display("--------------------------");


			interFullN = normalizeAdded(interFull);
			interFullCN = normalizeAdded(interFull_Comp);

    	end

    	return inter;
    endfunction



    function automatic void TMP_subMag(input FpFormat32 a, input FpFormat32 b);
    	assert (absF32(a) >= absF32(b)) else $error("Wrng, shoudl be abs(a) >= abs(b)");

    	begin
			Word expA = isSubnormal(a) ? a.exp + 1 : a.exp;
			Word expB = isSubnormal(b) ? b.exp + 1 : b.exp;
			Word ediff = a.exp - b.exp;

			Word expOut = expA;

			Word normA = isSubnormal(a) ? a.mantissa : ('h800000 | a.mantissa);
			Word normB = isSubnormal(b) ? b.mantissa : ('h800000 | b.mantissa);

			// Shift a to upper Word of a Dword
			Dword fullA = {normA, Word'(0)};
			Dword fullB = {normB, Word'(0)};

			Dword shiftedB = fullB >> ediff; // TODO: 'persistent' bit
			Dword summed = fullA - shiftedB;

			Dword compressedB = shiftedB;
			Dword summed_C;

			// !! at bit [-3] in contrast to [-2] of addition! 
			if (shiftedB[29:0] === 0) compressedB[29:0] = 'h00000000;
			else					  compressedB[29:0] = 'h20000000; 

			summed_C = fullA - compressedB;

			$display("Sub");
			$display("normA: %08X", normA);
			$display("normB: %08X", normB);

			$display("a: %08X|%08X", fullA >> 32, Word'(fullA));
			$display("b: %08X|%08X", shiftedB >> 32, Word'(shiftedB));
			$display("=: %08X|%08X", summed >> 32, Word'(summed));

			$display("Comp:");
			$display("a: %08X|%08X", fullA >> 32, Word'(fullA));
			$display("b: %08X|%08X", compressedB >> 32, Word'(compressedB));
			$display("=: %08X|%08X", summed_C >> 32, Word'(summed_C));

			if (summed[31:30] !== summed_C[31:30]) $display("    Digits [31:30] differ!");

			$display("--------------------------");

			// We need to normalize if MSB fell to the right
			if (expA == 0) begin
				// TODO: both denorm: don't shift anything
			end
			else begin
				// Find first 1. There may be none because diff can be 0
				if ($countones(summed) == 0) begin
					expOut = 0;
				end
				else begin
					int expShift;
					int log = $clog2(summed);
					if (summed[log] == 0) log--; // $clog2 is ceiling, there may be 1 more to shift

					// We want MSB to be at [32 + 23];
					expShift = (32+23) - log;
					summed <<= expShift;
					expOut -= expShift;
				end
			end

    	end

    endfunction 






endpackage
