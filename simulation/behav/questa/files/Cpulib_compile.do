
vlib questa_lib/work
vlib questa_lib/msim
vlib questa_lib/msim/cpuliblib

vmap cpulib questa_lib/msim/cpulib

vlog  -incr -mfcu -sv -work cpulib  \
"../../../../SV_CPU.srcs/cpulib/Cpulib.sv


quit -force

