
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


	localparam logic[30:23] EXP_MAX_32 = 'b11111111;


	typedef struct packed {
		logic sign;
		logic[30:23] exp;
		logic[22:0] mantissa;
	} FpFormat32;

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


    function automatic FpResult32 nextUpF32(input FpFormat32 a);
    	// SNaN -> exc Invalid, return QNaN?
    	// QNaN -> copy

    	// -inf -> -MAX_FINITE
    	// 


		// -0 is equal to +0, so next(-0) == next(+0)    	

		FpFormat32 outValue;

		Word exp = a.exp;
		
		// This will work for positive values
		if (exp == 0) begin
			Word mantissa = a.mantissa;
			mantissa++;
			if (mantissa[23]) exp++;
			outValue.exp = exp;
			outValue.mantissa = mantissa[22:0];
		end
		else if (exp == EXP_MAX_32) begin
			outValue = a;
		end
		else begin
			Word mantissaFull = 'h00800000 | a.mantissa;
			mantissaFull++;
			if (mantissaFull[23]) exp++;

			if (exp == EXP_MAX_32) begin
				outValue.exp = EXP_MAX_32;
				outValue.mantissa = 0;
			end
			else begin
				outValue.exp = exp;
				outValue.mantissa = mantissaFull[22:0];
			end
		end


    	return '{'{default: 0}, outValue};
    endfunction


    // adds eps to positive numbers and adds -eps to negative numbers
    function automatic FpFormat32 incMag(input FpFormat32 a);
		FpFormat32 outValue;

		Word exp = a.exp;
		
		// This will work for positive values
		if (exp == 0) begin
			Word mantissa = a.mantissa;
			mantissa++;
			if (mantissa[23]) exp++;
			outValue.exp = exp;
			outValue.mantissa = mantissa[22:0];
		end
		else if (exp == EXP_MAX_32) begin
			outValue = a;
		end
		else begin // OR: if mantissa is max, {exp+1, 0}, otherwise {exp, mantissa+1}
			Word mantissaFull = 'h00800000 | a.mantissa;
			mantissaFull++;
			if (mantissaFull[24]) begin
				exp++;
				mantissaFull >>= 1;
			end

			if (exp == EXP_MAX_32) begin // We got to infinity
				outValue.exp = EXP_MAX_32;
				outValue.mantissa = 0;
			end
			else begin
				outValue.exp = exp;
				outValue.mantissa = mantissaFull[22:0];
			end
		end

		outValue.sign = a.sign;

		return outValue;
    endfunction;

endpackage
