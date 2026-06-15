
profile on
profile off
#restart -force


add wave -position insertpoint  \
sim:/ArchDesc0/mainEmul

add wave -position insertpoint  \
sim:/ArchDesc0/emulTestName \
sim:/ArchDesc0/simTestName

add wave -position insertpoint  \
sim:/ArchDesc0/core/dataCache/cacheReadOut \
sim:/ArchDesc0/core/dataCache/cacheResults
add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/memImages


add wave -position insertpoint  \
sim:/ArchDesc0/core/lastRetired \
sim:/ArchDesc0/core/lateEventInfo \
sim:/ArchDesc0/core/lateEventInfoWaiting \
sim:/ArchDesc0/core/lateEventInfoWaitingInt \
sim:/ArchDesc0/core/lateEventInfoWaitingReset

add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/mem0/pE0_E \
sim:/ArchDesc0/core/theExecBlock/mem0/pE1_E \
sim:/ArchDesc0/core/theExecBlock/mem0/pE2_E
add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/mem0/accessDescE0 \
sim:/ArchDesc0/core/theExecBlock/mem0/accessDescE1 \
sim:/ArchDesc0/core/theExecBlock/mem0/accessDescE2
add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/mem2/pE0_E \
sim:/ArchDesc0/core/theExecBlock/mem2/pE1_E \
sim:/ArchDesc0/core/theExecBlock/mem2/pE2_E
add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/mem2/accessDescE0 \
sim:/ArchDesc0/core/theExecBlock/mem2/accessDescE1 \
sim:/ArchDesc0/core/theExecBlock/mem2/accessDescE2

add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/dcacheOuts_E1


add wave -position insertpoint  \
sim:/ArchDesc0/core/mn/uopE0 \
sim:/ArchDesc0/core/mn/uopE1 \
sim:/ArchDesc0/core/mn/uopE2 \
sim:/ArchDesc0/core/mn/adE0 \
sim:/ArchDesc0/core/mn/adE1 \
sim:/ArchDesc0/core/mn/adE2 \
sim:/ArchDesc0/core/mn/trE0 \
sim:/ArchDesc0/core/mn/trE0d \
sim:/ArchDesc0/core/mn/trE1 \
sim:/ArchDesc0/core/mn/trE2 \

add wave -position insertpoint  \
sim:/ArchDesc0/core/theSq/content
add wave -position insertpoint  \
sim:/ArchDesc0/core/theSq/responseE1
add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/memImages

add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/ch0 \
sim:/ArchDesc0/core/theExecBlock/ch1 \
sim:/ArchDesc0/core/theExecBlock/ch2 \
sim:/ArchDesc0/core/theExecBlock/ch3
add wave -position insertpoint  \
sim:/ArchDesc0/core/mn/sqOutE1 \
sim:/ArchDesc0/core/mn/sqOutE1d
add wave -position insertpoint  \
sim:/ArchDesc0/core/theSq/responseE1 \
sim:/ArchDesc0/core/theSq/responseE1d_N
