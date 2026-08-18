
package TestArith32;
	import Base::*;
	import Arith::*;


	function automatic void run();
		testNext();

	endfunction






	function automatic void testNext();
		begin
			FpResult32 res_MinusInf = nextUpF32(FP32_MINUS_INF);
			assert (res_MinusInf.value === FP32_MINUS_MAX_FINITE);
		end

		begin
			FpResult32 res_MinusMinNorm = nextUpF32(FP32_MINUS_MIN_NORM);
			assert (res_MinusMinNorm.value === FP32_MINUS_MAX_SUBN);// else $fatal(2, "Not equal: %p vs %p", res_Minus0.value, FP32_PLUS_ZERO);
		end

		begin
			FpResult32 res_MinusMinSubn = nextUpF32(FP32_MINUS_MIN_SUBN);
			assert (res_MinusMinSubn.value === FP32_MINUS_ZERO);// else $fatal(2, "Not equal: %p vs %p", res_Minus0.value, FP32_PLUS_ZERO);
		end

		begin
			FpResult32 res_Minus0 = nextUpF32(FP32_MINUS_ZERO);
			assert (res_Minus0.value === FP32_PLUS_ZERO) else $fatal(2, "Not equal: %p vs %p", res_Minus0.value, FP32_PLUS_ZERO);
		end


	endfunction

endpackage