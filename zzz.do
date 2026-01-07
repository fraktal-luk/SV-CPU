
profile on
profile off
#restart -force

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
{sim:/ArchDesc0/core/dataCache/dataArray/blocksWay0[0]}
