
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

add wave -position insertpoint sim:/ArchDesc0/core/theExecBlock/replayQueue/*
add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/replayQueue/entries

add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/replayQueue/inputUops \
sim:/ArchDesc0/core/theExecBlock/replayQueue/inputUopsE2

add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/memImages


add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/lateEventInfo
add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/branchEventInfo


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
sim:/ArchDesc0/core/theExecBlock/replayQueue/issued0 \
sim:/ArchDesc0/core/theExecBlock/replayQueue/issued1 \
sim:/ArchDesc0/core/theExecBlock/replayQueue/outPacket

add wave -position insertpoint  \
sim:/ArchDesc0/core/eventUnit/front \
sim:/ArchDesc0/core/eventUnit/frontH \
sim:/ArchDesc0/core/eventUnit/general \
sim:/ArchDesc0/core/eventUnit/generalH
add wave -position insertpoint  \
sim:/ArchDesc0/core/stageRename1 \
sim:/ArchDesc0/core/stageRename1_N




#add wave -position insertpoint sim:/ArchDesc0/core/eventUnit/*

add wave -position insertpoint  \
sim:/ArchDesc0/core/lastRetired \
sim:/ArchDesc0/core/lateEventInfo \
sim:/ArchDesc0/core/lateEventInfoWaiting \
sim:/ArchDesc0/core/lateEventInfoWaitingInt \
sim:/ArchDesc0/core/lateEventInfoWaitingReset

add wave -position insertpoint  \
sim:/ArchDesc0/core/eventUnit/general \
sim:/ArchDesc0/core/eventUnit/intCounter \
sim:/ArchDesc0/core/eventUnit/interruptEvt \
sim:/ArchDesc0/core/eventUnit/resetEvt

add wave -position insertpoint  \
sim:/ArchDesc0/core/theRob/lateEventOngoing \
sim:/ArchDesc0/core/theRob/isEmpty


add wave -position insertpoint  \
sim:/ArchDesc0/core/theFrontend/cachedFetcherState \
sim:/ArchDesc0/core/theFrontend/stageIP \
sim:/ArchDesc0/core/theFrontend/frontRedCa \
sim:/ArchDesc0/core/theFrontend/frontRedOnMiss

add wave -position insertpoint  \
sim:/ArchDesc0/core/theFrontend/chk \
sim:/ArchDesc0/core/theFrontend/chk_2 \
sim:/ArchDesc0/core/theFrontend/chk_3 \
sim:/ArchDesc0/core/theFrontend/chk_4

