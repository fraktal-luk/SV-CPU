
import Base::*;
import Arith::*;


module Cpulib (
);

	initial begin
		// automatic Dword a = 'h1000000000000000; 
		// automatic Dword b = 'h1100000000000000; 

		// automatic Dword c = 'hffffffffffffffff; 
		// automatic Dword d = 'hffffffffffffffff; 

		// automatic Dword z = 0; 
		// automatic Dword u = 'h0000000100000000; 
		// automatic Dword v = 'h00000000ffffffff; 

		// $display("Start lib test!");	

		// $display("%x", multiplyU64L(a, b));
		// $display("%x", multiplyU64L(c, d));

		// $display("%x", multiplyS64L(c, d));

		// $display("Div:");

		// $display("%x", divideU64(u, v));
		// $display("%x", divideU64(u, z));

		TestArith32::run();
	end

endmodule