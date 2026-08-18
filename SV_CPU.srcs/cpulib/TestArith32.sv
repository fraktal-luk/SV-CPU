
package TestArith32;
	import Base::*;
	import Arith::*;


	`define ASSERT_EQ(a, b) assert (a === b) else $fatal(2, "Failed EQ: '{%x, %X, %X} vs '{%x, %X, %X}", a.sign, a.exp, a.mantissa, b.sign, b.exp, b.mantissa);

	function automatic void run();
		testNext();

	endfunction






	function automatic void testNext();
		FpFormat32 xNegNormal = '{1, 'h47, 'h010010};
		FpFormat32 xNegNormalExpected = '{1, 'h47, 'h01000F};

		FpFormat32 yNegNormal = '{1, 'h42, 'h000000};
		FpFormat32 yNegNormalExpected = '{1, 'h41, 'h7FFFFF};

		FpFormat32 xNegSubn = '{1, 0, 'h003000};
		FpFormat32 xNegSubnExpected = '{1, 0, 'h002FFF};


		FpFormat32 xPosNormal = '{0, 'hB3, 'h000440};
		FpFormat32 xPosNormalExpected = '{0, 'hB3, 'h000441};

		FpFormat32 yPosNormal = '{0, 'h05, 'h7FFFFF};
		FpFormat32 yPosNormalExpected = '{0, 'h06, 'h000000};

		FpFormat32 xPosSubn = '{0, 0, 'h0a1004};
		FpFormat32 xPosSubnExpected = '{0, 0, 'h0a1005};


		FpFormat32 expectedValues[FpFormat32] = '{
			FP32_MINUS_INF: FP32_MINUS_MAX_FINITE,
			xNegNormal: xNegNormalExpected,
			yNegNormal: yNegNormalExpected,
			FP32_MINUS_MIN_NORM: FP32_MINUS_MAX_SUBN,
			xNegSubn: xNegSubnExpected,
			FP32_MINUS_MIN_SUBN: FP32_MINUS_ZERO,
			FP32_MINUS_ZERO: FP32_PLUS_ZERO,

			FP32_PLUS_ZERO: FP32_PLUS_MIN_SUBN,
			xPosSubn: xPosSubnExpected,
			FP32_PLUS_MAX_SUBN: FP32_PLUS_MIN_NORM,
			xPosNormal: xPosNormalExpected,
			yPosNormal: yPosNormalExpected,
			FP32_PLUS_MAX_FINITE: FP32_PLUS_INF,
			FP32_PLUS_INF: FP32_PLUS_INF,

			FP32_CANONICAL_QNAN: FP32_CANONICAL_QNAN
		};

		foreach (expectedValues[arg]) begin
			FpResult32 result = nextUpF32(arg);
			assert (result.exc === NO_EXCEPTION) else $fatal(2, "Exception found");
			`ASSERT_EQ(result.value, expectedValues[arg]);
		end

		begin
			FpResult32 result = nextUpF32(FP32_SNAN);
			assert (result.exc === '{invalid: 1, default: 0}) else $fatal(2, "Exception wrong");
			`ASSERT_EQ(result.value, FP32_CANONICAL_QNAN);	
		end


	endfunction

endpackage