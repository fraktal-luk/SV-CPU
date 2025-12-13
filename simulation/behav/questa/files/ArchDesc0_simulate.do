
vsim -lib xil_defaultlib ArchDesc0_opt

set NumericStdNoWarnings 1
set StdArithNoWarnings 1

do {ArchDesc0_wave.do}

view wave
view structure
view signals

do {../../../../zzz.do}

run 50 ms
