
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
sim:/ArchDesc0/core/mn/accessDescs_E0 \
sim:/ArchDesc0/core/mn/accessDescs_E2 \
sim:/ArchDesc0/core/mn/dcacheOuts_E1 \
sim:/ArchDesc0/core/mn/dcacheTranslations_E1 \
sim:/ArchDesc0/core/mn/dcacheTranslations_E2 \
sim:/ArchDesc0/core/mn/dcacheTranslations_EE0 \
sim:/ArchDesc0/core/mn/lqResponse_E1 \
sim:/ArchDesc0/core/mn/sqResponse_E1 \
sim:/ArchDesc0/core/mn/sysOuts_E1 \
sim:/ArchDesc0/core/mn/toLqE0 \
sim:/ArchDesc0/core/mn/toLqE1 \
sim:/ArchDesc0/core/mn/toLqE2 \
sim:/ArchDesc0/core/mn/uopE0 \
sim:/ArchDesc0/core/mn/uopE1 \
sim:/ArchDesc0/core/mn/uopE2 \
sim:/ArchDesc0/core/mn/adE0 \
sim:/ArchDesc0/core/mn/adE1 \
sim:/ArchDesc0/core/mn/adE2 \
sim:/ArchDesc0/core/mn/trPreE0 \
sim:/ArchDesc0/core/mn/trE0 \
sim:/ArchDesc0/core/mn/trE1 \
sim:/ArchDesc0/core/mn/trE2 \
sim:/ArchDesc0/core/mn/uncachedOuts_E1

