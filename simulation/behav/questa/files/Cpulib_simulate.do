
vsim -lib cpulib Cpulib_opt

set NumericStdNoWarnings 1
set StdArithNoWarnings 1

do {Cpulib_wave.do}

view wave
view structure
view signals


run 50 ms
