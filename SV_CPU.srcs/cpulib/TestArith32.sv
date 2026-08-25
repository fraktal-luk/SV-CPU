
package TestArith32;
	import Base::*;
	import Arith::*;


	`define ASSERT_EQ(a, b) assert (a === b) else begin	\
		$displayh("Failed EQ: %p vs %p", a, b); \
		$fatal(2, "Assertion failed"); \
	end

	function automatic void run();
		testNext();

		//TMP_testAdd();
		TestAdd_0();

		TestAdd_1();

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

			FP32_CANONICAL_QNAN: FP32_CANONICAL_QNAN,
			negateF32(FP32_CANONICAL_QNAN): negateF32(FP32_CANONICAL_QNAN)
		};

		foreach (expectedValues[arg]) begin
			FpResult32 result = nextUpF32(arg);
			assert (result.exc === NO_EXCEPTION) else $fatal(2, "Exception found");
			`ASSERT_EQ(result.value, expectedValues[arg]);
		end

		// Signaling NaN
		begin
			FpResult32 result = nextUpF32(FP32_SNAN);
			assert (result.exc === '{invalid: 1, default: 0}) else $fatal(2, "Exception wrong");
			`ASSERT_EQ(result.value, FP32_CANONICAL_QNAN);	
		end

		// Signaling NaN with - sign
		begin
			FpResult32 result = nextUpF32(negateF32(FP32_SNAN));
			assert (result.exc === '{invalid: 1, default: 0}) else $fatal(2, "Exception wrong");
			`ASSERT_EQ(result.value, FP32_CANONICAL_QNAN);
		end

	endfunction




	// function automatic void TMP_testAdd();
	// 	FpFormat32 x = '{0, 60, 'h130303};
	// 	FpFormat32 y = '{0, 50, 'h140021};

	// 	FpFormat32 u = '{0, 40, 'h100103};
	// 	FpFormat32 v = '{0, 18, 'h080021};

	// 	FpFormat32 w = '{0, 40, 'h000000};


	// 	FpFormat32 p = '{0, 39, 'h7FFFFF};
	// 	FpFormat32 q = '{0, 38, 'h7FFFFF};
	// 	FpFormat32 r = '{0, 37, 'h7FFFFF};

	// 	FpFormat32 a = '{0, 5, 'h7FFFFF};
	// 	FpFormat32 a0 = '{0, 5, 'h000000};
	// 	FpFormat32 b = '{0, 4, 'h7FFFFF};



	// 	FpFormat32 subX = '{0, 0, 'h080000};
	// 	FpFormat32 subY = '{0, 0, 'h070100};



	// 	TMP_addMag(x, y);
	// 	TMP_addMag(u, v);

	// 	TMP_subMag(x, y);
	// 	TMP_subMag(u, v);

	// 	TMP_subMag(u, p);
	// 	TMP_subMag(u, q);
	// 	TMP_subMag(u, r);

	// 	TMP_subMag(w, p);

	// 	TMP_subMag(a, b);
	// 	TMP_subMag(a0, b);

	// 	TMP_subMag(subX, subY);

	// endfunction



	function automatic void TestAdd_0();
		FpFormat32 zero = '{0, 0, 0};

		FpFormat32 a1 =  '{0, 127, 'h000000};	 	
		FpFormat32 a1h = '{0, 126, 'h000000};

		FpFormat32 b1 =  '{0, 127, 'h7FFFFF};	 	
		FpFormat32 b1h = '{0, 126, 'h7FFFFF};	 	

		FpFormat32 minSubn = '{0, 0, 'h000001};	 	
		FpFormat32 maxSubn = '{0, 0, 'h7FFFFF};	 	


		FpFormat32 maxNorm = '{0, 254, 'h7FFFFF};
		FpFormat32 bigHalfDigit = '{0, 230, 'h000000};



		TMP_addF32(a1, a1, RoundZero);
		TMP_addF32(a1h, a1h, RoundZero);

		TMP_addF32(b1, b1, RoundZero);
		TMP_addF32(b1h, b1h, RoundZero);

		TMP_addF32(b1, b1h, RoundZero);
		TMP_addF32(b1, b1h, RoundPlusInf);

		TMP_addF32(minSubn, minSubn, RoundZero);
		TMP_addF32(maxSubn, minSubn, RoundZero);

		TMP_addF32(maxSubn, maxSubn, RoundZero);


		TMP_addF32(maxNorm, maxNorm, RoundZero);

		TMP_addF32(maxNorm, bigHalfDigit, RoundZero);
		TMP_addF32(maxNorm, bigHalfDigit, RoundPlusInf);

		TMP_addF32(maxNorm, minSubn, RoundZero);
		TMP_addF32(maxNorm, minSubn, RoundPlusInf);


		TMP_addF32(maxNorm, zero, RoundZero);
		TMP_addF32(maxNorm, zero, RoundPlusInf);

	endfunction


	typedef struct {
		FpFormat32 arg0;
		FpFormat32 arg1;
		Rounding rm;
		ExceptionPack exc;
		FpFormat32 value;
	} Expectation2a;


	function automatic void checkExpectation_Add(input Expectation2a e);
		FpResult32 result = TMP_addF32(e.arg0, e.arg1, e.rm);
		FpResult32 expected = '{e.exc, e.value};
		assert (result === expected) else begin	
			$displayh("%p (actual) vs %p (expected)", result, expected);
			$fatal(2, "Failed expectation");
		end
	endfunction


	function automatic void TestAdd_1();
		//Expectation2a e = '{FP32_PLUS_ZERO, FP32_PLUS_ZERO, RoundZero, NO_EXCEPTION, 	FP32_PLUS_ZERO};

		Expectation2a list[] = '{
			'{FP32_PLUS_ZERO, FP32_PLUS_ZERO, RoundZero, NO_EXCEPTION, 	FP32_PLUS_ZERO},
			'{FP32_PLUS_ZERO, FP32_PLUS_ZERO, RoundPlusInf, NO_EXCEPTION, 	FP32_PLUS_ZERO},


			'{FP32_PLUS_ZERO, FP32_MINUS_ZERO, RoundPlusInf, NO_EXCEPTION, 	 FP32_PLUS_ZERO},
			'{FP32_PLUS_ZERO, FP32_MINUS_ZERO, RoundZero,	 NO_EXCEPTION, 	 FP32_PLUS_ZERO},
			'{FP32_PLUS_ZERO, FP32_MINUS_ZERO, RoundMinusInf, NO_EXCEPTION, FP32_MINUS_ZERO},


			'{FP32_MINUS_ZERO, FP32_MINUS_ZERO, RoundZero, NO_EXCEPTION, 	FP32_MINUS_ZERO},
			'{FP32_MINUS_ZERO, FP32_MINUS_ZERO, RoundPlusInf, NO_EXCEPTION, 	FP32_MINUS_ZERO},

			'{FP32_PLUS_MIN_SUBN, FP32_PLUS_ZERO, RoundZero, NO_EXCEPTION, 	FP32_PLUS_MIN_SUBN},
			'{FP32_PLUS_MAX_SUBN, FP32_PLUS_ZERO, RoundZero, NO_EXCEPTION, 	FP32_PLUS_MAX_SUBN},

			'{FP32_PLUS_MIN_SUBN, FP32_MINUS_ZERO, RoundZero, NO_EXCEPTION, 	FP32_PLUS_MIN_SUBN},
			'{FP32_PLUS_MAX_SUBN, FP32_MINUS_ZERO, RoundZero, NO_EXCEPTION, 	FP32_PLUS_MAX_SUBN},



			'{FP32_PLUS_MIN_SUBN, FP32_PLUS_MAX_SUBN, RoundZero, NO_EXCEPTION, 	FP32_PLUS_MIN_NORM},
			'{FP32_PLUS_MIN_SUBN, FP32_PLUS_MAX_SUBN, RoundPlusInf, NO_EXCEPTION, 	FP32_PLUS_MIN_NORM},


			'{FP32_PLUS_MAX_FINITE, FP32_PLUS_ZERO, RoundPlusInf, NO_EXCEPTION, 	FP32_PLUS_MAX_FINITE},


			'{FP32_PLUS_MAX_FINITE, FP32_PLUS_MIN_SUBN, RoundZero, '{inexact: 1, default: 0}, 	FP32_PLUS_MAX_FINITE},
			'{FP32_PLUS_MAX_FINITE, FP32_PLUS_MIN_SUBN, RoundPlusInf, '{inexact: 1, overflow: 1, default: 0}, 	FP32_PLUS_INF},


			'{'{0, 20, 'h7FFFFF}, '{0, 20, 'h7FFFFF}, RoundZero, NO_EXCEPTION,  '{0, 21, 'h7FFFFF}},
			'{'{0, 20, 'h7FFFFF}, '{0, 21, 'h7FFFFF}, RoundZero, '{inexact: 1, default: 0},  '{0, 22, 'h3FFFFF}},

			'{'{0, 20, 'h0}, '{0, 19, 'h7FFFFE}, RoundZero, '{inexact: 0, default: 0},  '{0, 20, 'h7FFFFF}},
			'{'{0, 20, 'h0}, '{0, 19, 'h7FFFFF}, RoundZero, '{inexact: 1, default: 0},  '{0, 20, 'h7FFFFF}},
			'{'{0, 20, 'h0}, '{0, 19, 'h7FFFFF}, RoundPlusInf, '{inexact: 1, default: 0},  '{0, 21, 'h0}},




			'{FP32_CANONICAL_QNAN, FP32_CANONICAL_QNAN, RoundPlusInf, NO_EXCEPTION, FP32_CANONICAL_QNAN}
		};

		foreach (list[i])
			checkExpectation_Add(list[i]);


	endfunction


endpackage