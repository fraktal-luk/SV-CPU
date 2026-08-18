
vlib questa_lib/work
vlib questa_lib/msim
vlib questa_lib/msim/cpulib

vmap cpulib questa_lib/msim/cpulib

vlog  -incr -mfcu -sv -work cpulib  \
"../../../../SV_CPU.srcs/src/Base.sv" \
"../../../../SV_CPU.srcs/cpulib/Arith.sv" \
"../../../../SV_CPU.srcs/cpulib/TestArith32.sv" \
"../../../../SV_CPU.srcs/cpulib/Cpulib.sv" \

quit -force

