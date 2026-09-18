
import Base::*;
import Arith::*;


module Cpulib (
);

	initial begin

		TestArith32::run();

		TestArith64::run();
		
	end

endmodule