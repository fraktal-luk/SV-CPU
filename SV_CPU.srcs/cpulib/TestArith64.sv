
package TestArith64;
	import Base::*;
	import Arith::*;
	import Arith64::*;


	`define ASSERT_EQ(a, b) assert (a === b) else begin	\
		$displayh("Failed EQ: %p vs %p", a, b); \
		$fatal(2, "Assertion failed"); \
	end

	function automatic void run();
			$display("Tt 64!");

		testNext();

		TestAdd_1();

		Test_Rounding0();

		Test_Cmp0();

		Test_i2f();

		Test_f2i();


		Test_narrow();

	endfunction



	function automatic void testNext();
		FpFormat64 xNegNormal = '{1, 'h47, 'h0100100000000};
		FpFormat64 xNegNormalExpected = '{1, 'h47, 'h01000FFFFFFFF};

		FpFormat64 yNegNormal = '{1, 'h42, 'h0000000000000};
		FpFormat64 yNegNormalExpected = '{1, 'h41, 'hFFFFFFFFFFFFF};

		FpFormat64 xNegSubn = '{1, 0, 'h0030000000000};
		FpFormat64 xNegSubnExpected = '{1, 0, 'h002FFFFFFFFFF};



		FpFormat64 xPosNormal = '{0, 'hB3, 'h0044000000000};
		FpFormat64 xPosNormalExpected = '{0, 'hB3, 'h0044000000001};

		FpFormat64 yPosNormal = '{0, 'h05, 'hFFFFFFFFFFFFF};
		FpFormat64 yPosNormalExpected = '{0, 'h06, 'h0000000000000};

		FpFormat64 xPosSubn = '{0, 0, 'h0a10000000004};
		FpFormat64 xPosSubnExpected = '{0, 0, 'h0a10000000005};


		FpFormat64 expectedValues[FpFormat64] = '{
			FP64_MINUS_INF: FP64_MINUS_MAX_FINITE,
			xNegNormal: xNegNormalExpected,
			yNegNormal: yNegNormalExpected,
			FP64_MINUS_MIN_NORM: FP64_MINUS_MAX_SUBN,
			xNegSubn: xNegSubnExpected,
			FP64_MINUS_MIN_SUBN: FP64_MINUS_ZERO,
			FP64_MINUS_ZERO: FP64_PLUS_ZERO,

			FP64_PLUS_ZERO: FP64_PLUS_MIN_SUBN,
			xPosSubn: xPosSubnExpected,
			FP64_PLUS_MAX_SUBN: FP64_PLUS_MIN_NORM,
			xPosNormal: xPosNormalExpected,
			yPosNormal: yPosNormalExpected,
			FP64_PLUS_MAX_FINITE: FP64_PLUS_INF,
			FP64_PLUS_INF: FP64_PLUS_INF,

			FP64_CANONICAL_QNAN: FP64_CANONICAL_QNAN,
			negateF64(FP64_CANONICAL_QNAN): negateF64(FP64_CANONICAL_QNAN)
		};

		foreach (expectedValues[arg]) begin
			FpResult64 result = nextUpF64(arg);
			assert (result.exc === NO_EXCEPTION) else $fatal(2, "Exception found");
			`ASSERT_EQ(result.value, expectedValues[arg]);
		end

		// Signaling NaN
		begin
			FpResult64 result = nextUpF64(FP64_SNAN);
			assert (result.exc === '{invalid: 1, default: 0}) else $fatal(2, "Exception wrong");
			`ASSERT_EQ(result.value, FP64_CANONICAL_QNAN);	
		end

		// Signaling NaN with - sign
		begin
			FpResult64 result = nextUpF64(negateF64(FP64_SNAN));
			assert (result.exc === '{invalid: 1, default: 0}) else $fatal(2, "Exception wrong");
			`ASSERT_EQ(result.value, FP64_CANONICAL_QNAN);
		end

	endfunction



	typedef struct {
		FpFormat64 arg0;
		Rounding rm;
		ExceptionPack exc;
		FpFormat64 value;
	} Expectation1a;


	typedef struct {
		FpFormat64 arg0;
		FpFormat64 arg1;
		Rounding rm;
		ExceptionPack exc;
		FpFormat64 value;
	} Expectation2a;


	typedef struct {
		FpFormat64 arg0;
		FpFormat64 arg1;
		FpFormat64 arg2;
		Rounding rm;
		ExceptionPack exc;
		FpFormat64 value;
	} Expectation3a;


	function automatic void checkExpectation_Add(input Expectation2a e);
		FpResult64 result = TMP_addF64(e.arg0, e.arg1, e.rm);
		FpResult64 expected = '{e.exc, e.value};

		assert (result === expected) else begin	
			$displayh("%p (actual) vs %p (expected)", result, expected);
			$fatal(2, "Failed expectation");
		end
	endfunction


	function automatic void TestAdd_1();
		Expectation2a list[] = '{
			'{FP64_PLUS_ZERO, FP64_PLUS_ZERO, RoundZero, NO_EXCEPTION, 	FP64_PLUS_ZERO},
			'{FP64_PLUS_ZERO, FP64_PLUS_ZERO, RoundPlusInf, NO_EXCEPTION, 	FP64_PLUS_ZERO},


			'{FP64_PLUS_ZERO, FP64_MINUS_ZERO, RoundPlusInf, NO_EXCEPTION, 	 FP64_PLUS_ZERO},
			'{FP64_PLUS_ZERO, FP64_MINUS_ZERO, RoundZero,	 NO_EXCEPTION, 	 FP64_PLUS_ZERO},
			'{FP64_PLUS_ZERO, FP64_MINUS_ZERO, RoundMinusInf, NO_EXCEPTION, FP64_MINUS_ZERO},


			'{FP64_MINUS_ZERO, FP64_MINUS_ZERO, RoundZero, NO_EXCEPTION, 	FP64_MINUS_ZERO},
			'{FP64_MINUS_ZERO, FP64_MINUS_ZERO, RoundPlusInf, NO_EXCEPTION, 	FP64_MINUS_ZERO},

			'{FP64_PLUS_MIN_SUBN, FP64_PLUS_ZERO, RoundZero, NO_EXCEPTION, 	FP64_PLUS_MIN_SUBN},
			'{FP64_PLUS_MAX_SUBN, FP64_PLUS_ZERO, RoundZero, NO_EXCEPTION, 	FP64_PLUS_MAX_SUBN},

			'{FP64_PLUS_MIN_SUBN, FP64_MINUS_ZERO, RoundZero, NO_EXCEPTION, 	FP64_PLUS_MIN_SUBN},
			'{FP64_PLUS_MAX_SUBN, FP64_MINUS_ZERO, RoundZero, NO_EXCEPTION, 	FP64_PLUS_MAX_SUBN},


			'{FP64_PLUS_MIN_SUBN, FP64_PLUS_MAX_SUBN, RoundZero, NO_EXCEPTION, 	FP64_PLUS_MIN_NORM},
			'{FP64_PLUS_MIN_SUBN, FP64_PLUS_MAX_SUBN, RoundPlusInf, NO_EXCEPTION, 	FP64_PLUS_MIN_NORM},


			'{FP64_PLUS_MAX_FINITE, FP64_PLUS_ZERO, RoundPlusInf, NO_EXCEPTION, 	FP64_PLUS_MAX_FINITE},


			'{FP64_PLUS_MAX_FINITE, FP64_PLUS_MIN_SUBN, RoundZero, '{inexact: 1, default: 0}, 	FP64_PLUS_MAX_FINITE},
			'{FP64_PLUS_MAX_FINITE, FP64_PLUS_MIN_SUBN, RoundPlusInf, '{inexact: 1, overflow: 1, default: 0}, 	FP64_PLUS_INF},


			'{'{0, 20, 'hFFFFFFFFFFFFF}, '{0, 20, 'hFFFFFFFFFFFFF}, RoundZero, NO_EXCEPTION,  '{0, 21, 'hFFFFFFFFFFFFF}},
			'{'{0, 20, 'hFFFFFFFFFFFFF}, '{0, 21, 'hFFFFFFFFFFFFF}, RoundZero, '{inexact: 1, default: 0},  '{0, 22, 'h7FFFFFFFFFFFF}},

			'{'{0, 20, 'h0}, '{0, 19, 'hFFFFFFFFFFFFE}, RoundZero, '{inexact: 0, default: 0},  '{0, 20, 'hFFFFFFFFFFFFF}},
			'{'{0, 20, 'h0}, '{0, 19, 'hFFFFFFFFFFFFF}, RoundZero, '{inexact: 1, default: 0},  '{0, 20, 'hFFFFFFFFFFFFF}},
			'{'{0, 20, 'h0}, '{0, 19, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{inexact: 1, default: 0},  '{0, 21, 'h0}},


			'{'{0, 75, 'h0}, '{0, 15, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{inexact: 1, default: 0},  '{0, 75, 'h1}},
			'{'{0, 75, 'h0}, '{0, 15, 'hFFFFFFFFFFFFF}, RoundMinusInf, '{inexact: 1, default: 0},  '{0, 75, 'h0}},


			'{'{0, 75, 'h0}, '{0, 21, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{inexact: 1, default: 0},  '{0, 75, 'h1}},
			'{'{0, 75, 'h0}, '{0, 21, 'hFFFFFFFFFFFFF}, RoundMinusInf, '{inexact: 1, default: 0},  '{0, 75, 'h0}},


			'{'{0, 75, 'h0}, '{0, 22, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{inexact: 1, default: 0},  '{0, 75, 'h1}},
			'{'{0, 75, 'h0}, '{0, 22, 'hFFFFFFFFFFFFF}, RoundMinusInf, '{inexact: 1, default: 0},  '{0, 75, 'h0}},


			'{'{0, 75, 'h0}, '{0, 23, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{inexact: 1, default: 0},  '{0, 75, 'h2}},
			'{'{0, 75, 'h0}, '{0, 23, 'hFFFFFFFFFFFFF}, RoundMinusInf, '{inexact: 1, default: 0},  '{0, 75, 'h1}},


			'{'{0, 2046, 'hEF0FFFFFFFFFF}, '{0, 2042, 'h0F00000000000}, RoundPlusInf, '{inexact: 0, default: 0}, FP64_PLUS_MAX_FINITE},
			'{'{0, 2046, 'hEF0FFFFFFFFFF}, '{0, 2042, 'h0F01000000000}, RoundZero, '{inexact: 1, overflow: 1, default: 0}, FP64_PLUS_INF},
			'{'{0, 2046, 'hEF0FFFFFFFFFF}, '{0, 2042, 'h0F00000000001}, RoundZero, '{inexact: 1, overflow: 0, default: 0}, FP64_PLUS_MAX_FINITE},
			'{'{0, 2046, 'hEF0FFFFFFFFFF}, '{0, 2042, 'h0F00000000001}, RoundPlusInf, '{inexact: 1, overflow: 1, default: 0}, FP64_PLUS_INF},


			'{FP64_PLUS_MIN_SUBN, FP64_MINUS_MIN_SUBN, RoundZero, 	 NO_EXCEPTION, 	FP64_PLUS_ZERO},
			'{FP64_PLUS_MIN_SUBN, FP64_MINUS_MIN_SUBN, RoundMinusInf, NO_EXCEPTION, 	FP64_MINUS_ZERO},

			'{'{1, 20, 0}, '{0, 20, 0}, RoundZero, 	 NO_EXCEPTION, 	FP64_PLUS_ZERO},
			'{'{1, 20, 0}, '{0, 20, 0}, RoundMinusInf, NO_EXCEPTION, 	FP64_MINUS_ZERO},

			'{'{0, 150, 'hFFFFFFFFFFFFF}, FP64_MINUS_MIN_SUBN, RoundZero, 	 '{inexact: 1, default: 0}, 	'{0, 150, 'hFFFFFFFFFFFFE}},
			'{'{0, 150, 'hFFFFFFFFFFFFF}, FP64_MINUS_MIN_SUBN, RoundMinusInf, 	 '{inexact: 1, default: 0}, 	'{0, 150, 'hFFFFFFFFFFFFE}},
			'{'{0, 150, 'hFFFFFFFFFFFFF}, FP64_MINUS_MIN_SUBN, RoundPlusInf, 	 '{inexact: 1, default: 0}, 	'{0, 150, 'hFFFFFFFFFFFFF}},

			'{'{1, 150, 'hFFFFFFFFFFFFF}, FP64_PLUS_MIN_SUBN, RoundZero, 	 '{inexact: 1, default: 0}, 	'{1, 150, 'hFFFFFFFFFFFFE}},
			'{'{1, 150, 'hFFFFFFFFFFFFF}, FP64_PLUS_MIN_SUBN, RoundMinusInf, 	 '{inexact: 1, default: 0}, 	'{1, 150, 'hFFFFFFFFFFFFF}},
			'{'{1, 150, 'hFFFFFFFFFFFFF}, FP64_PLUS_MIN_SUBN, RoundPlusInf, 	 '{inexact: 1, default: 0}, 	'{1, 150, 'hFFFFFFFFFFFFE}},


			'{FP64_PLUS_INF, FP64_PLUS_INF, RoundPlusInf, NO_EXCEPTION, FP64_PLUS_INF},
			'{FP64_PLUS_INF, FP64_PLUS_INF, RoundZero, NO_EXCEPTION, FP64_PLUS_INF},
			'{FP64_PLUS_INF, FP64_PLUS_INF, RoundMinusInf, NO_EXCEPTION, FP64_PLUS_INF},


			'{FP64_MINUS_INF, FP64_MINUS_INF, RoundPlusInf, NO_EXCEPTION, FP64_MINUS_INF},
			'{FP64_MINUS_INF, FP64_MINUS_INF, RoundZero, NO_EXCEPTION, FP64_MINUS_INF},
			'{FP64_MINUS_INF, FP64_MINUS_INF, RoundMinusInf, NO_EXCEPTION, FP64_MINUS_INF},


			'{FP64_PLUS_INF, FP64_MINUS_INF, RoundPlusInf, '{invalid: 1, default: 0}, FP64_CANONICAL_QNAN},

			'{FP64_MINUS_INF, FP64_PLUS_MIN_SUBN, RoundZero, NO_EXCEPTION, FP64_MINUS_INF},
			'{FP64_MINUS_INF, '{0, 32, 'h00FFFFFFFFFFF}, RoundZero, NO_EXCEPTION, FP64_MINUS_INF},
			'{FP64_MINUS_INF, FP64_MINUS_MAX_FINITE, RoundMinusInf, NO_EXCEPTION, FP64_MINUS_INF},

			'{FP64_CANONICAL_QNAN, FP64_MINUS_MAX_FINITE, RoundMinusInf, NO_EXCEPTION, FP64_CANONICAL_QNAN},
			'{'{1, 20, 0}, FP64_CANONICAL_QNAN, RoundMinusInf, NO_EXCEPTION, 	FP64_CANONICAL_QNAN},


			'{FP64_CANONICAL_QNAN, FP64_CANONICAL_QNAN, RoundPlusInf, NO_EXCEPTION, FP64_CANONICAL_QNAN}
		};

		foreach (list[i])
			checkExpectation_Add(list[i]);

	endfunction



	function automatic void checkRoundToInteger(input FpFormat64 x, input Rounding rm, input FpResult64 expected);
		FpResult64 actual = TMP_roundToInteger64(x, rm);

		assert (actual === expected) else begin
			$displayh("Rounding %p, %p -> %p", x, rm, expected);
			$displayh("%p\n%p", actual, expected);
			$fatal(2, "Wrong rounding");
		end
	endfunction


	function automatic void Test_Rounding0();
		FpResult64 res0;
		FpFormat64 x = '{0, 1031, 'h06D6020000000};

		checkRoundToInteger(x, RoundPlusInf, '{EXC_INEXACT , '{0, 1031, 'h0700000000000}});

		checkRoundToInteger('{0, 1507, 'hFFFFFFFFFFFFF}, RoundMinusInf, '{NO_EXCEPTION, '{0, 1507, 'hFFFFFFFFFFFFF}});
		checkRoundToInteger('{0, 1507, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{NO_EXCEPTION, '{0, 1507, 'hFFFFFFFFFFFFF}});

		checkRoundToInteger('{0, 1023+18, 'hFFFFFF0000000}, RoundMinusInf, '{EXC_INEXACT , '{0, 1023+18, 'hFFFFC00000000}});
		checkRoundToInteger('{0, 1023+12, 'hFFF0000000000}, RoundMinusInf, '{NO_EXCEPTION, '{0, 1023+12, 'hFFF0000000000}});
		checkRoundToInteger('{0, 1023+12, 'hFFFFFFFFFFFFF}, RoundMinusInf, '{EXC_INEXACT, '{0, 1023+12, 'hFFF0000000000}});
		checkRoundToInteger('{0, 1023+3, 'hFFFFFFFFFFFFF}, RoundMinusInf, '{EXC_INEXACT, '{0, 1023+3, 'hE000000000000}});
		checkRoundToInteger('{0, 1023+1, 'hFFFFFFFFFFFFF}, RoundMinusInf, '{EXC_INEXACT, '{0, 1023+1, 'h8000000000000}});
		checkRoundToInteger('{0, 1023, 'hFFFFFFFFFFFFF}, RoundMinusInf, '{EXC_INEXACT, '{0, 1023, 'h0000000000000}});


		checkRoundToInteger('{0, 1022, 'hFFFFFFFFFFFFF}, RoundMinusInf, '{EXC_INEXACT,  FP64_PLUS_ZERO});
		checkRoundToInteger('{0, 1021, 'hFFFFFFFFFFFFF}, RoundMinusInf, '{EXC_INEXACT, FP64_PLUS_ZERO});
		checkRoundToInteger('{0, 890, 'hFFFFFFFFFFFFF}, RoundMinusInf, '{EXC_INEXACT, FP64_PLUS_ZERO});
		checkRoundToInteger('{0, 0, 'hFFFFFFFFFFFFF}, RoundMinusInf, '{EXC_INEXACT, FP64_PLUS_ZERO});
		checkRoundToInteger(FP64_PLUS_ZERO, RoundMinusInf, '{NO_EXCEPTION, FP64_PLUS_ZERO});


		checkRoundToInteger('{0, 1023 + 18, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 1023 + 19, 0}});
		checkRoundToInteger('{0, 1023 + 12, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 1023 + 13, 0}});
		checkRoundToInteger('{0, 1023 + 3, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 1023 + 4, 0}});
		checkRoundToInteger('{0, 1023 + 1, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 1023 + 2, 0}});
		checkRoundToInteger('{0, 1023 , 'hFFFFFFFFFFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 1023 + 1, 0}});
		checkRoundToInteger('{0, 1023 - 1, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 1023, 0}});
		checkRoundToInteger('{0, 1023 - 2, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 1023, 0}});
		checkRoundToInteger('{0, 89, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 1023, 0}});
		checkRoundToInteger('{0, 0, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{EXC_INEXACT, '{0, 1023, 0}});
		checkRoundToInteger(FP64_PLUS_ZERO, RoundPlusInf, '{NO_EXCEPTION, FP64_PLUS_ZERO});


		checkRoundToInteger('{1, 1023+18, 'hFFFFFFFFFFFFF}, RoundPlusInf, '{EXC_INEXACT , '{1, 1023+18, 'hFFFFC00000000}});
		checkRoundToInteger('{1, 1023+18, 'hFFFFFFFFFFFFF}, RoundMinusInf, '{EXC_INEXACT, '{1, 1023+19, 0}});


		checkRoundToInteger('{0, 1022, 0}, RoundNearestEven, '{EXC_INEXACT, FP64_PLUS_ZERO});
		checkRoundToInteger('{0, 1022, 0}, RoundNearestAway, '{EXC_INEXACT, '{0, 1023, 0}});
		checkRoundToInteger('{0, 1022, 0}, RoundPlusInf, '{EXC_INEXACT, '{0, 1023, 0}});
		checkRoundToInteger('{0, 1022, 0}, RoundZero, '{EXC_INEXACT, FP64_PLUS_ZERO});
		checkRoundToInteger('{0, 1022, 0}, RoundMinusInf, '{EXC_INEXACT, FP64_PLUS_ZERO});


		checkRoundToInteger('{0, 1023, 'h8000000000000}, RoundNearestEven, '{EXC_INEXACT, '{0, 1024, 0}});
		checkRoundToInteger('{0, 1023, 'h8000000000000}, RoundNearestAway, '{EXC_INEXACT, '{0, 1024, 0}});
		checkRoundToInteger('{0, 1023, 'h8000000000000}, RoundPlusInf, '{EXC_INEXACT, '{0, 1024, 0}});
		checkRoundToInteger('{0, 1023, 'h8000000000000}, RoundZero, '{EXC_INEXACT, '{0, 1023, 0}});
		checkRoundToInteger('{0, 1023, 'h8000000000000}, RoundMinusInf, '{EXC_INEXACT, '{0, 1023, 0}});

	endfunction



	localparam FpResult64 cmpTrue = '{NO_EXCEPTION, FP64_PLUS_MIN_SUBN};
	localparam FpResult64 cmpFalse = '{NO_EXCEPTION, FP64_PLUS_ZERO};
	localparam FpResult64 cmpInvalid = '{'{invalid: 1, default: 0}, FP64_CANONICAL_QNAN};


	function automatic void checkCmp(input FpFormat64 a, input FpFormat64 b, input CmpPredicate pred, input logic signal, input FpResult64 expected);
		FpResult64 res = TMP_cmpF64(a, b, pred, signal);
		assert (res === expected) else begin
			$displayh("Compare %p, %p, (%p)", a, b, pred);
			$fatal(2, "Comparison failed:\n%p\n%p", res, expected);
		end
	endfunction


	function automatic void Test_Cmp0();
		FpFormat64 x = '{0, 160, 0},
				   y = '{0, 160, 'h0002000000000},
				   z = '{0, 161, 0};

				   	$display(" comparison");

		checkCmp(FP64_MINUS_ZERO, FP64_PLUS_ZERO, CMP_LT, 1,  cmpFalse);
		checkCmp(FP64_MINUS_ZERO, FP64_PLUS_ZERO, CMP_GT, 1,  cmpFalse);
		checkCmp(FP64_MINUS_ZERO, FP64_PLUS_ZERO, CMP_EQ, 1,  cmpTrue);
		checkCmp(FP64_MINUS_ZERO, FP64_PLUS_ZERO, CMP_GE, 1,  cmpTrue);
		checkCmp(FP64_MINUS_ZERO, FP64_PLUS_ZERO, CMP_LE, 1,  cmpTrue);
		checkCmp(FP64_MINUS_ZERO, FP64_PLUS_ZERO, CMP_UN, 1,  cmpFalse);


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


		checkCmp(negateF64(x), negateF64(y), CMP_GT, 1,  cmpTrue);

		checkCmp(negateF64(z), y, CMP_LT, 1,  cmpTrue);
		
		checkCmp(negateF64(z), z, CMP_LT, 1,  cmpTrue);

		checkCmp(negateF64(x), z, CMP_LT, 1,  cmpTrue);


		checkCmp(z, y, CMP_LU, 1,  cmpFalse);
		checkCmp(z, y, CMP_NE, 1,  cmpTrue);
		checkCmp(z, y, CMP_NG, 1,  cmpFalse);
		checkCmp(z, y, CMP_OR, 1,  cmpTrue);


		checkCmp(FP64_MINUS_INF, x, CMP_LT, 1, cmpTrue);
		checkCmp(FP64_MINUS_INF, negateF64(x), CMP_LT, 1, cmpTrue);

		checkCmp(FP64_PLUS_INF, x, CMP_GT, 1, cmpTrue);
		checkCmp(FP64_PLUS_INF, negateF64(x), CMP_GT, 1, cmpTrue);

		checkCmp(FP64_MINUS_INF, FP64_MINUS_INF, CMP_EQ, 1, cmpTrue);
		checkCmp(FP64_PLUS_INF, FP64_PLUS_INF, CMP_EQ, 1, cmpTrue);
		checkCmp(FP64_MINUS_INF, FP64_PLUS_INF, CMP_LT, 1, cmpTrue);


		checkCmp(FP64_CANONICAL_QNAN, FP64_CANONICAL_QNAN, CMP_UN, 0, cmpTrue);
		checkCmp(FP64_CANONICAL_QNAN, FP64_MINUS_INF, CMP_UN, 0, cmpTrue);
		checkCmp(FP64_CANONICAL_QNAN, x, CMP_UN, 0, cmpTrue);
		checkCmp(FP64_CANONICAL_QNAN, FP64_PLUS_INF, CMP_UN, 0, cmpTrue);

		checkCmp(FP64_CANONICAL_QNAN, FP64_CANONICAL_QNAN, CMP_NE, 1, cmpInvalid);
		checkCmp(FP64_CANONICAL_QNAN, FP64_MINUS_INF, CMP_NE, 1, cmpInvalid);
		checkCmp(FP64_CANONICAL_QNAN, x, CMP_NE, 1, cmpInvalid);
		checkCmp(FP64_CANONICAL_QNAN, FP64_PLUS_INF, CMP_NE, 1, cmpInvalid);

		// SNaN causes Invalid even if not signalling variant
		checkCmp(FP64_CANONICAL_QNAN, FP64_SNAN, CMP_UN, 0, cmpInvalid);
		checkCmp(FP64_MINUS_INF, FP64_SNAN, CMP_UN, 0, cmpInvalid);
		checkCmp(FP64_SNAN, x, CMP_UN, 0, cmpInvalid);


	endfunction



	function automatic void checkI2F(input Dword x, input logic isSigned, input Rounding rm, FpResult64 expected);
		 FpResult64 actual = TMP_int64toFP64(x, isSigned, rm);
		 assert (actual === expected) else begin
		 	$displayh("%016X (%d) (%p)\n%p\n%p", x, isSigned, rm, actual, expected);
		 	$fatal(2, "Wromg conv");
		 end
	endfunction


	function automatic void Test_i2f();
		checkI2F(0, 0, RoundZero, '{NO_EXCEPTION, FP64_PLUS_ZERO});
		checkI2F(0, 0, RoundMinusInf, '{NO_EXCEPTION, FP64_MINUS_ZERO});

		checkI2F('h0000000000001000, 0, RoundZero, '{NO_EXCEPTION, '{0, 1023+12, 0}});

		checkI2F('h0010000000000000, 0, RoundZero, '{NO_EXCEPTION, '{0, 1023+52, 0}});

		checkI2F('h0100000000000001, 0, RoundZero, '{EXC_INEXACT, '{0, 1023+56, 0}});
		checkI2F('h0010000000000001, 0, RoundZero, '{NO_EXCEPTION, '{0, 1023+52, 'h0000000000001}});


		checkI2F('h01FFFFFFFFFFFFF0, 0, RoundZero, '{NO_EXCEPTION, '{0, 1023+56, 'hFFFFFFFFFFFFF}});

		checkI2F('h01FFFFFFFFFFFFF8, 0, RoundZero, '{EXC_INEXACT, '{0, 1023+56, 'hFFFFFFFFFFFFF}});
		checkI2F('h01FFFFFFFFFFFFF8, 0, RoundPlusInf, '{EXC_INEXACT, '{0, 1023+57, 0}});
		checkI2F('h01FFFFFFFFFFFFF8, 0, RoundNearestEven, '{EXC_INEXACT, '{0, 1023+57, 0}});

		checkI2F(-'h01FFFFFFFFFFFFF8, 1, RoundNearestEven, '{EXC_INEXACT, '{1, 1023+57, 0}});

		checkI2F(+'h03FFFFFFFFFFFFF8, 1, RoundPlusInf, '{EXC_INEXACT, '{0, 1023+58, 0}});
		checkI2F(-'h03FFFFFFFFFFFFF8, 1, RoundPlusInf, '{EXC_INEXACT, '{1, 1023+57, 'hFFFFFFFFFFFFF}});
	endfunction



	function automatic void checkF2I(input FpFormat64 x, input Rounding rm, input logic isSigned, input FpResult64 expected);
		FpResult64 actual = fp64toInt64(x, rm, isSigned);
		 assert (actual === expected) else begin
		 	$displayh("%p (%d) (%p)\n%p\n%p", x, isSigned, rm, actual, expected);
		 	$displayh("a %08X, e %08X", actual.value, expected.value);
		 	$fatal(2, "Wromg conv");
		 end
	endfunction


	function automatic void Test_f2i();
		checkF2I(FP64_MINUS_ZERO, RoundPlusInf, 0, '{NO_EXCEPTION, 0});
		checkF2I(FP64_PLUS_ZERO, RoundPlusInf, 0, '{NO_EXCEPTION, 0});

		checkF2I('{0, 1023, 0}, RoundMinusInf, 0, '{NO_EXCEPTION, 1});
		checkF2I('{0, 1023, 0}, RoundPlusInf, 0, '{NO_EXCEPTION, 1});

		checkF2I('{0, 1023, 'hFFFFFF0000000}, RoundPlusInf, 0, '{EXC_INEXACT, 2});
		checkF2I('{0, 1023, 'hFFFFFF0000000}, RoundMinusInf, 0, '{EXC_INEXACT, 1});

		checkF2I('{1, 1022, 0}, RoundNearestEven, 1, '{EXC_INEXACT, 0});
		checkF2I('{1, 1022, 0}, RoundMinusInf, 1, '{EXC_INEXACT, -1});

	 	checkF2I('{1, 1022, 0}, RoundMinusInf, 0, '{'{invalid: 1, default: 0}, 0});

	 	checkF2I('{1, 0, 335}, RoundMinusInf, 1, '{EXC_INEXACT, -1});


	 	checkF2I('{0, 1023 + 63, 'hFFFFFFFFFFFFF}, RoundMinusInf, 0, '{NO_EXCEPTION, 'hFFFFFFFFFFFFF800});
	 	checkF2I('{0, 1023 + 63, 'hFFFFFFFFFFFFF}, RoundMinusInf, 1, '{'{invalid: 1, default: 0}, 0});

	 	checkF2I('{0, 1023 + 64, 0}, RoundMinusInf, 0, '{'{invalid: 1, default: 0}, 0});

	 	checkF2I('{0, 1023 + 62, 'hFFFFFFFFFFFFF}, RoundMinusInf, 1, '{NO_EXCEPTION, 'h7FFFFFFFFFFFFC00});
	 	checkF2I('{0, 1023 + 63, 'h0000000000000}, RoundMinusInf, 1, '{'{invalid: 1, default: 0}, 0});
	 	checkF2I('{1, 1023 + 63, 'h0}, RoundMinusInf, 1, '{NO_EXCEPTION, 'h8000000000000000});


	 	checkF2I(FP64_PLUS_INF, RoundZero, 0, '{'{invalid: 1, default: 0}, 0});
	 	checkF2I(FP64_SNAN, RoundZero, 0, '{'{invalid: 1, default: 0}, 0});
	 	checkF2I(FP64_CANONICAL_QNAN, RoundZero, 0, '{'{invalid: 1, default: 0}, 0});

	endfunction





	function automatic void checkNarrow(input FpFormat64 x, input Rounding rm, input FpResult32 expected);
		FpResult32 actual = convertF64to32(x, rm);
		 assert (actual === expected) else begin
		 	$displayh("%p (%p)\n%p\n%p", x, rm, actual, expected);
		 	$displayh("a %08X, e %08X", actual.value, expected.value);
		 	$fatal(2, "Wromg narrowing");
		 end
	endfunction


	function automatic void Test_narrow();
			$display("test narrowing");
		checkNarrow('{0, 1023, 0}, RoundZero, '{NO_EXCEPTION, '{0, 127, 0}});
		checkNarrow('{0, 1023, 1}, RoundZero, '{EXC_INEXACT, '{0, 127, 0}});
		checkNarrow('{0, 1023, 1}, RoundPlusInf, '{EXC_INEXACT, '{0, 127, 1}});
		checkNarrow('{0, 1023, 'h0000080000000}, RoundPlusInf, '{NO_EXCEPTION, '{0, 127, 4}});
		checkNarrow('{0, 1023, 'h0000080000000}, RoundZero, '{NO_EXCEPTION, '{0, 127, 4}});
		checkNarrow('{0, 1023, 'h0000080000001}, RoundPlusInf, '{EXC_INEXACT, '{0, 127, 5}});
		checkNarrow('{0, 1023, 'h0000080000001}, RoundZero, '{EXC_INEXACT, '{0, 127, 4}});
		checkNarrow('{0, 1023, 'h0000020000000}, RoundPlusInf, '{NO_EXCEPTION, '{0, 127, 1}});
		checkNarrow('{0, 1023, 'h0000010000000}, RoundPlusInf, '{EXC_INEXACT, '{0, 127, 1}});
		checkNarrow('{0, 1023, 'h0000010000000}, RoundZero, '{EXC_INEXACT, '{0, 127, 0}});

		checkNarrow('{0, 1023, 'h0000000200000}, RoundPlusInf, '{EXC_INEXACT, '{0, 127, 1}});
		checkNarrow('{0, 1023, 'h0000000200000}, RoundZero, '{EXC_INEXACT, '{0, 127, 0}});

		//////////////////
		// High normal range of f32 
		checkNarrow('{0, 1023 + (254-127), 'h0000000000000}, RoundZero, '{NO_EXCEPTION, '{0, 254, 0}});
		checkNarrow('{0, 1023 + (254-127), 'hFFFFFE0000000}, RoundZero, '{NO_EXCEPTION, '{0, 254, 'h7FFFFF}});

		checkNarrow('{0, 1023 + (254-127), 'hFFFFFE0010000}, RoundZero, '{EXC_INEXACT, '{0, 254, 'h7FFFFF}});
		checkNarrow('{0, 1023 + (254-127), 'hFFFFFE0010000}, RoundPlusInf, '{'{inexact: 1, overflow: 1, default: 0}, FP32_PLUS_INF});
		
		///////////////
		// Low normal range of f32
		checkNarrow('{0, 1023 - 125, 'h0000000010000}, RoundZero, '{EXC_INEXACT, '{0, 2, 0}});
		checkNarrow('{0, 1023 - 125, 'h0000000010000}, RoundPlusInf, '{EXC_INEXACT, '{0, 2, 1}});
		checkNarrow('{0, 1023 - 125, 'hFFFFFE0000000}, RoundZero, '{NO_EXCEPTION, '{0, 2, 'h7FFFFF}});
		checkNarrow('{0, 1023 - 126, 'hFFFFFE0000000}, RoundZero, '{NO_EXCEPTION, '{0, 1, 'h7FFFFF}});
		checkNarrow('{0, 1023 - 126, 'hFFFFFE0010000}, RoundZero, '{EXC_INEXACT, '{0, 1, 'h7FFFFF}});
		checkNarrow('{0, 1023 - 126, 'hFFFFFE0010000}, RoundPlusInf, '{EXC_INEXACT, '{0, 2, 0}});



	endfunction


endpackage

