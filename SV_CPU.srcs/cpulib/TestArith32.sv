
package TestArith32;
	import Base::*;
	import Arith::*;


	`define ASSERT_EQ(a, b) assert (a === b) else begin	\
		$displayh("Failed EQ: %p vs %p", a, b); \
		$fatal(2, "Assertion failed"); \
	end

	function automatic void run();
		testNext();

		TestAdd_1();

		Test_Rounding0();

		Test_Cmp0();

		Test_i2f();
		
		Test_f2i();

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



	typedef struct {
		FpFormat32 arg0;
		Rounding rm;
		ExceptionPack exc;
		FpFormat32 value;
	} Expectation1a;


	typedef struct {
		FpFormat32 arg0;
		FpFormat32 arg1;
		Rounding rm;
		ExceptionPack exc;
		FpFormat32 value;
	} Expectation2a;


	typedef struct {
		FpFormat32 arg0;
		FpFormat32 arg1;
		FpFormat32 arg2;
		Rounding rm;
		ExceptionPack exc;
		FpFormat32 value;
	} Expectation3a;


	function automatic void checkExpectation_Add(input Expectation2a e);
		FpResult32 result = TMP_addF32(e.arg0, e.arg1, e.rm);
		FpResult32 expected = '{e.exc, e.value};

		assert (result === expected) else begin	
			$displayh("%p (actual) vs %p (expected)", result, expected);
			$fatal(2, "Failed expectation");
		end
	endfunction


	function automatic void TestAdd_1();
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


			'{'{0, 46, 'h0}, '{0, 15, 'h7FFFFF}, RoundPlusInf, '{inexact: 1, default: 0},  '{0, 46, 'h1}},
			'{'{0, 46, 'h0}, '{0, 15, 'h7FFFFF}, RoundMinusInf, '{inexact: 1, default: 0},  '{0, 46, 'h0}},


			'{'{0, 46, 'h0}, '{0, 21, 'h7FFFFF}, RoundPlusInf, '{inexact: 1, default: 0},  '{0, 46, 'h1}},
			'{'{0, 46, 'h0}, '{0, 21, 'h7FFFFF}, RoundMinusInf, '{inexact: 1, default: 0},  '{0, 46, 'h0}},


			'{'{0, 46, 'h0}, '{0, 22, 'h7FFFFF}, RoundPlusInf, '{inexact: 1, default: 0},  '{0, 46, 'h1}},
			'{'{0, 46, 'h0}, '{0, 22, 'h7FFFFF}, RoundMinusInf, '{inexact: 1, default: 0},  '{0, 46, 'h0}},


			'{'{0, 46, 'h0}, '{0, 23, 'h7FFFFF}, RoundPlusInf, '{inexact: 1, default: 0},  '{0, 46, 'h2}},
			'{'{0, 46, 'h0}, '{0, 23, 'h7FFFFF}, RoundMinusInf, '{inexact: 1, default: 0},  '{0, 46, 'h1}},


			'{'{0, 254, 'h770FFF}, '{0, 250, 'h0F0000}, RoundPlusInf, '{inexact: 0, default: 0}, FP32_PLUS_MAX_FINITE},
			'{'{0, 254, 'h770FFF}, '{0, 250, 'h0F0100}, RoundZero, '{inexact: 1, overflow: 1, default: 0}, FP32_PLUS_INF},
			'{'{0, 254, 'h770FFF}, '{0, 250, 'h0F0001}, RoundZero, '{inexact: 1, overflow: 0, default: 0}, FP32_PLUS_MAX_FINITE},
			'{'{0, 254, 'h770FFF}, '{0, 250, 'h0F0001}, RoundPlusInf, '{inexact: 1, overflow: 1, default: 0}, FP32_PLUS_INF},


			'{FP32_PLUS_MIN_SUBN, FP32_MINUS_MIN_SUBN, RoundZero, 	 NO_EXCEPTION, 	FP32_PLUS_ZERO},
			'{FP32_PLUS_MIN_SUBN, FP32_MINUS_MIN_SUBN, RoundMinusInf, NO_EXCEPTION, 	FP32_MINUS_ZERO},

			'{'{1, 20, 0}, '{0, 20, 0}, RoundZero, 	 NO_EXCEPTION, 	FP32_PLUS_ZERO},
			'{'{1, 20, 0}, '{0, 20, 0}, RoundMinusInf, NO_EXCEPTION, 	FP32_MINUS_ZERO},

			'{'{0, 150, 'h7FFFFF}, FP32_MINUS_MIN_SUBN, RoundZero, 	 '{inexact: 1, default: 0}, 	'{0, 150, 'h7FFFFE}},
			'{'{0, 150, 'h7FFFFF}, FP32_MINUS_MIN_SUBN, RoundMinusInf, 	 '{inexact: 1, default: 0}, 	'{0, 150, 'h7FFFFE}},
			'{'{0, 150, 'h7FFFFF}, FP32_MINUS_MIN_SUBN, RoundPlusInf, 	 '{inexact: 1, default: 0}, 	'{0, 150, 'h7FFFFF}},

			'{'{1, 150, 'h7FFFFF}, FP32_PLUS_MIN_SUBN, RoundZero, 	 '{inexact: 1, default: 0}, 	'{1, 150, 'h7FFFFE}},
			'{'{1, 150, 'h7FFFFF}, FP32_PLUS_MIN_SUBN, RoundMinusInf, 	 '{inexact: 1, default: 0}, 	'{1, 150, 'h7FFFFF}},
			'{'{1, 150, 'h7FFFFF}, FP32_PLUS_MIN_SUBN, RoundPlusInf, 	 '{inexact: 1, default: 0}, 	'{1, 150, 'h7FFFFE}},


			'{FP32_PLUS_INF, FP32_PLUS_INF, RoundPlusInf, NO_EXCEPTION, FP32_PLUS_INF},
			'{FP32_PLUS_INF, FP32_PLUS_INF, RoundZero, NO_EXCEPTION, FP32_PLUS_INF},
			'{FP32_PLUS_INF, FP32_PLUS_INF, RoundMinusInf, NO_EXCEPTION, FP32_PLUS_INF},


			'{FP32_MINUS_INF, FP32_MINUS_INF, RoundPlusInf, NO_EXCEPTION, FP32_MINUS_INF},
			'{FP32_MINUS_INF, FP32_MINUS_INF, RoundZero, NO_EXCEPTION, FP32_MINUS_INF},
			'{FP32_MINUS_INF, FP32_MINUS_INF, RoundMinusInf, NO_EXCEPTION, FP32_MINUS_INF},


			'{FP32_PLUS_INF, FP32_MINUS_INF, RoundPlusInf, '{invalid: 1, default: 0}, FP32_CANONICAL_QNAN},

			'{FP32_MINUS_INF, FP32_PLUS_MIN_SUBN, RoundZero, NO_EXCEPTION, FP32_MINUS_INF},
			'{FP32_MINUS_INF, '{0, 32, 'h00FFFF}, RoundZero, NO_EXCEPTION, FP32_MINUS_INF},
			'{FP32_MINUS_INF, FP32_MINUS_MAX_FINITE, RoundMinusInf, NO_EXCEPTION, FP32_MINUS_INF},

			'{FP32_CANONICAL_QNAN, FP32_MINUS_MAX_FINITE, RoundMinusInf, NO_EXCEPTION, FP32_CANONICAL_QNAN},
			'{'{1, 20, 0}, FP32_CANONICAL_QNAN, RoundMinusInf, NO_EXCEPTION, 	FP32_CANONICAL_QNAN},


			'{FP32_CANONICAL_QNAN, FP32_CANONICAL_QNAN, RoundPlusInf, NO_EXCEPTION, FP32_CANONICAL_QNAN}
		};

		foreach (list[i])
			checkExpectation_Add(list[i]);

	endfunction



	function automatic void checkRoundToInteger(input FpFormat32 x, input Rounding rm, input FpResult32 expected);
		FpResult32 actual = TMP_roundToInteger(x, rm);

		assert (actual === expected) else begin
			$displayh("Rounding %p, %p -> %p", x, rm, expected);
			$displayh("%p\n%p", actual, expected);
			$fatal(2, "Wrong rounding");
		end
	endfunction

	localparam ExceptionPack EXC_INEXACT = '{inexact: 1, default: 0};


	function automatic void Test_Rounding0();
		FpResult32 res0;
		FpFormat32 x = '{0, 135, 'h037301};

		checkRoundToInteger(x, RoundPlusInf, '{EXC_INEXACT , '{0, 135, 'h038000}});

		checkRoundToInteger('{0, 221, 'h7FFFFF}, RoundMinusInf, '{NO_EXCEPTION, '{0, 221, 'h7FFFFF}});
		checkRoundToInteger('{0, 221, 'h7FFFFF}, RoundPlusInf, '{NO_EXCEPTION, '{0, 221, 'h7FFFFF}});


		checkRoundToInteger('{0, 145, 'h7FFFFF}, RoundMinusInf, '{EXC_INEXACT , '{0, 145, 'h7FFFE0}});
		checkRoundToInteger('{0, 139, 'h7FF800}, RoundMinusInf, '{NO_EXCEPTION, '{0, 139, 'h7FF800}});
		checkRoundToInteger('{0, 139, 'h7FFFFF}, RoundMinusInf, '{EXC_INEXACT, '{0, 139, 'h7FF800}});
		checkRoundToInteger('{0, 130, 'h7FFFFF}, RoundMinusInf, '{EXC_INEXACT, '{0, 130, 'h700000}});
		checkRoundToInteger('{0, 128, 'h7FFFFF}, RoundMinusInf, '{EXC_INEXACT, '{0, 128, 'h400000}});
		checkRoundToInteger('{0, 127, 'h7FFFFF}, RoundMinusInf, '{EXC_INEXACT, '{0, 127, 'h000000}});


		checkRoundToInteger('{0, 126, 'h7FFFFF}, RoundMinusInf, '{EXC_INEXACT,  FP32_PLUS_ZERO});
		checkRoundToInteger('{0, 125, 'h7FFFFF}, RoundMinusInf, '{EXC_INEXACT, FP32_PLUS_ZERO});
		checkRoundToInteger('{0, 89, 'h7FFFFF}, RoundMinusInf, '{EXC_INEXACT, FP32_PLUS_ZERO});
		checkRoundToInteger('{0, 0, 'h7FFFFF}, RoundMinusInf, '{EXC_INEXACT, FP32_PLUS_ZERO});
		checkRoundToInteger(FP32_PLUS_ZERO, RoundMinusInf, '{NO_EXCEPTION, FP32_PLUS_ZERO});


		checkRoundToInteger('{0, 145, 'h7FFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 146, 0}});
		checkRoundToInteger('{0, 139, 'h7FFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 140, 0}});
		checkRoundToInteger('{0, 130, 'h7FFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 131, 0}});
		checkRoundToInteger('{0, 128, 'h7FFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 129, 0}});
		checkRoundToInteger('{0, 127, 'h7FFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 128, 0}});
		checkRoundToInteger('{0, 126, 'h7FFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 127, 0}});
		checkRoundToInteger('{0, 125, 'h7FFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 127, 0}});
		checkRoundToInteger('{0, 89, 'h7FFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 127, 0}});
		checkRoundToInteger('{0, 0, 'h7FFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 127, 0}});
		checkRoundToInteger(FP32_PLUS_ZERO, RoundPlusInf, '{NO_EXCEPTION, FP32_PLUS_ZERO});


		checkRoundToInteger('{1, 145, 'h7FFFFF}, RoundPlusInf, '{EXC_INEXACT , '{1, 145, 'h7FFFE0}});
		checkRoundToInteger('{1, 145, 'h7FFFFF}, RoundMinusInf, '{EXC_INEXACT, '{1, 146, 0}});



		checkRoundToInteger('{0, 126, 0}, RoundNearestEven, '{EXC_INEXACT, FP32_PLUS_ZERO});
		checkRoundToInteger('{0, 126, 0}, RoundNearestAway, '{EXC_INEXACT, '{0, 127, 0}});
		checkRoundToInteger('{0, 126, 0}, RoundPlusInf, '{EXC_INEXACT, '{0, 127, 0}});
		checkRoundToInteger('{0, 126, 0}, RoundZero, '{EXC_INEXACT, FP32_PLUS_ZERO});
		checkRoundToInteger('{0, 126, 0}, RoundMinusInf, '{EXC_INEXACT, FP32_PLUS_ZERO});


		checkRoundToInteger('{0, 127, 'h400000}, RoundNearestEven, '{EXC_INEXACT, '{0, 128, 0}});
		checkRoundToInteger('{0, 127, 'h400000}, RoundNearestAway, '{EXC_INEXACT, '{0, 128, 0}});
		checkRoundToInteger('{0, 127, 'h400000}, RoundPlusInf, '{EXC_INEXACT, '{0, 128, 0}});
		checkRoundToInteger('{0, 127, 'h400000}, RoundZero, '{EXC_INEXACT, '{0, 127, 0}});
		checkRoundToInteger('{0, 127, 'h400000}, RoundMinusInf, '{EXC_INEXACT, '{0, 127, 0}});

	endfunction



	localparam FpResult32 cmpTrue = '{NO_EXCEPTION, FP32_PLUS_MIN_SUBN};
	localparam FpResult32 cmpFalse = '{NO_EXCEPTION, FP32_PLUS_ZERO};
	localparam FpResult32 cmpInvalid = '{'{invalid: 1, default: 0}, FP32_CANONICAL_QNAN};


	function automatic void checkCmp(input FpFormat32 a, input FpFormat32 b, input CmpPredicate pred, input logic signal, input FpResult32 expected);
		FpResult32 res = TMP_cmpF32(a, b, pred, signal);
		assert (res === expected) else begin
			$displayh("Compare %p, %p, (%p)", a, b, pred);
			$fatal(2, "Comparison failed:\n%p\n%p", res, expected);
		end
	endfunction


	function automatic void Test_Cmp0();
		FpFormat32 x = '{0, 160, 0},
				   y = '{0, 160, 'h000200},
				   z = '{0, 161, 0};

		checkCmp(FP32_MINUS_ZERO, FP32_PLUS_ZERO, CMP_LT, 1,  cmpFalse);
		checkCmp(FP32_MINUS_ZERO, FP32_PLUS_ZERO, CMP_GT, 1,  cmpFalse);
		checkCmp(FP32_MINUS_ZERO, FP32_PLUS_ZERO, CMP_EQ, 1,  cmpTrue);
		checkCmp(FP32_MINUS_ZERO, FP32_PLUS_ZERO, CMP_GE, 1,  cmpTrue);
		checkCmp(FP32_MINUS_ZERO, FP32_PLUS_ZERO, CMP_LE, 1,  cmpTrue);
		checkCmp(FP32_MINUS_ZERO, FP32_PLUS_ZERO, CMP_UN, 1,  cmpFalse);


		checkCmp(x, y, CMP_LT, 1,  cmpTrue);
		checkCmp(x, y, CMP_LE, 1,  cmpTrue);
		checkCmp(x, y, CMP_LU, 1,  cmpTrue);
		checkCmp(x, y, CMP_NE, 1,  cmpTrue);
		checkCmp(x, y, CMP_NG, 1,  cmpTrue);
		checkCmp(x, y, CMP_OR, 1,  cmpTrue);

		checkCmp(z, y, CMP_GT, 1,  cmpTrue);
		checkCmp(z, y, CMP_LE, 1,  cmpFalse);
		checkCmp(z, y, CMP_LU, 1,  cmpFalse);
		checkCmp(z, y, CMP_NE, 1,  cmpTrue);
		checkCmp(z, y, CMP_NG, 1,  cmpFalse);
		checkCmp(z, y, CMP_OR, 1,  cmpTrue);


		checkCmp(negateF32(x), negateF32(y), CMP_GT, 1,  cmpTrue);

		checkCmp(negateF32(z), y, CMP_LT, 1,  cmpTrue);
		
		checkCmp(negateF32(z), z, CMP_LT, 1,  cmpTrue);

		checkCmp(negateF32(x), z, CMP_LT, 1,  cmpTrue);


		checkCmp(z, y, CMP_LU, 1,  cmpFalse);
		checkCmp(z, y, CMP_NE, 1,  cmpTrue);
		checkCmp(z, y, CMP_NG, 1,  cmpFalse);
		checkCmp(z, y, CMP_OR, 1,  cmpTrue);


		checkCmp(FP32_MINUS_INF, x, CMP_LT, 1, cmpTrue);
		checkCmp(FP32_MINUS_INF, negateF32(x), CMP_LT, 1, cmpTrue);

		checkCmp(FP32_PLUS_INF, x, CMP_GT, 1, cmpTrue);
		checkCmp(FP32_PLUS_INF, negateF32(x), CMP_GT, 1, cmpTrue);

		checkCmp(FP32_MINUS_INF, FP32_MINUS_INF, CMP_EQ, 1, cmpTrue);
		checkCmp(FP32_PLUS_INF, FP32_PLUS_INF, CMP_EQ, 1, cmpTrue);
		checkCmp(FP32_MINUS_INF, FP32_PLUS_INF, CMP_LT, 1, cmpTrue);


		checkCmp(FP32_CANONICAL_QNAN, FP32_CANONICAL_QNAN, CMP_UN, 0, cmpTrue);
		checkCmp(FP32_CANONICAL_QNAN, FP32_MINUS_INF, CMP_UN, 0, cmpTrue);
		checkCmp(FP32_CANONICAL_QNAN, x, CMP_UN, 0, cmpTrue);
		checkCmp(FP32_CANONICAL_QNAN, FP32_PLUS_INF, CMP_UN, 0, cmpTrue);

		checkCmp(FP32_CANONICAL_QNAN, FP32_CANONICAL_QNAN, CMP_NE, 1, cmpInvalid);
		checkCmp(FP32_CANONICAL_QNAN, FP32_MINUS_INF, CMP_NE, 1, cmpInvalid);
		checkCmp(FP32_CANONICAL_QNAN, x, CMP_NE, 1, cmpInvalid);
		checkCmp(FP32_CANONICAL_QNAN, FP32_PLUS_INF, CMP_NE, 1, cmpInvalid);

		// SNaN causes Invalid even if not signalling variant
		checkCmp(FP32_CANONICAL_QNAN, FP32_SNAN, CMP_UN, 0, cmpInvalid);
		checkCmp(FP32_MINUS_INF, FP32_SNAN, CMP_UN, 0, cmpInvalid);
		checkCmp(FP32_SNAN, x, CMP_UN, 0, cmpInvalid);


	endfunction



	function automatic void checkI2F(input Dword x, input logic isSigned, input Rounding rm, FpResult32 expected);
		 FpResult32 actual = TMP_int64toFP32(x, isSigned, rm);
		 assert (actual === expected) else begin
		 	$displayh("%016X (%d) (%p)\n%p\n%p", x, isSigned, rm, actual, expected);
		 	$fatal(2, "Wromg conv");
		 end
	endfunction


	function automatic void Test_i2f();
		checkI2F(0, 0, RoundZero, '{NO_EXCEPTION, FP32_PLUS_ZERO});
		checkI2F(0, 0, RoundMinusInf, '{NO_EXCEPTION, FP32_MINUS_ZERO});

		checkI2F('h0000000000001000, 0, RoundZero, '{NO_EXCEPTION, '{0, 127+12, 0}});

		checkI2F('h0010000000000000, 0, RoundZero, '{NO_EXCEPTION, '{0, 127+52, 0}});

		checkI2F('h0010000001000000, 0, RoundZero, '{EXC_INEXACT, '{0, 127+52, 0}});

		checkI2F('h001FFFFFFF000000, 0, RoundZero, '{EXC_INEXACT, '{0, 127+52, 'h7FFFFF}});
		checkI2F('h001FFFFFFF000000, 0, RoundPlusInf, '{EXC_INEXACT, '{0, 127+53, 0}});
		checkI2F('h001FFFFFFF000000, 0, RoundNearestEven, '{EXC_INEXACT, '{0, 127+53, 0}});

		checkI2F(-'h001FFFFFFF000000, 1, RoundNearestEven, '{EXC_INEXACT, '{1, 127+53, 0}});

		checkI2F(+'h01FFFFFF, 1, RoundPlusInf, '{EXC_INEXACT, '{0, 127+25, 0}});
		checkI2F(-'h01FFFFFF, 1, RoundPlusInf, '{EXC_INEXACT, '{1, 127+24, 'h7FFFFF}});
	endfunction



	function automatic void checkF2I(input FpFormat32 x, input Rounding rm, input logic isSigned, input FpResult32 expected);
		FpResult32 actual = fp64toInt32(x, rm, isSigned);
		 assert (actual === expected) else begin
		 	$displayh("%p (%d) (%p)\n%p\n%p", x, isSigned, rm, actual, expected);
		 	$displayh("a %08X, e %08X", actual.value, expected.value);
		 	$fatal(2, "Wromg conv");
		 end
	endfunction


	function automatic void Test_f2i();
		checkF2I(FP32_MINUS_ZERO, RoundPlusInf, 0, '{NO_EXCEPTION, 0});
		checkF2I(FP32_PLUS_ZERO, RoundPlusInf, 0, '{NO_EXCEPTION, 0});

		checkF2I('{0, 127, 0}, RoundMinusInf, 0, '{NO_EXCEPTION, 1});
		checkF2I('{0, 127, 0}, RoundPlusInf, 0, '{NO_EXCEPTION, 1});

		checkF2I('{0, 127, 'h7FFFFF}, RoundPlusInf, 0, '{EXC_INEXACT, 2});
		checkF2I('{0, 127, 'h7FFFFF}, RoundMinusInf, 0, '{EXC_INEXACT, 1});

		checkF2I('{1, 126, 0}, RoundNearestEven, 1, '{EXC_INEXACT, 0});
		checkF2I('{1, 126, 0}, RoundMinusInf, 1, '{EXC_INEXACT, -1});

		checkF2I('{1, 126, 0}, RoundMinusInf, 0, '{'{invalid: 1, default: 0}, 0});

		checkF2I('{1, 0, 335}, RoundMinusInf, 1, '{EXC_INEXACT, -1});


		checkF2I('{0, 127 + 31, 'h7FFFFF}, RoundMinusInf, 0, '{NO_EXCEPTION, 'hFFFFFF00});
		checkF2I('{0, 127 + 31, 'h7FFFFF}, RoundMinusInf, 1, '{'{invalid: 1, default: 0}, 0});

		checkF2I('{0, 127 + 32, 0}, RoundMinusInf, 0, '{'{invalid: 1, default: 0}, 0});


		checkF2I(FP32_PLUS_INF, RoundZero, 0, '{'{invalid: 1, default: 0}, 0});
		checkF2I(FP32_SNAN, RoundZero, 0, '{'{invalid: 1, default: 0}, 0});
		checkF2I(FP32_CANONICAL_QNAN, RoundZero, 0, '{'{invalid: 1, default: 0}, 0});


	endfunction



endpackage
