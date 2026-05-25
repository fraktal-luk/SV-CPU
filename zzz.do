
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
sim:/ArchDesc0/core/eventUnit/interruptEvt \
sim:/ArchDesc0/core/eventUnit/resetEvt \
sim:/ArchDesc0/core/eventUnit/backendState


add wave -position insertpoint  \
sim:/ArchDesc0/core/theRob/lateEventOngoing \
sim:/ArchDesc0/core/theRob/isEmpty

add wave -position insertpoint  \
sim:/ArchDesc0/core/theRob/altRob/pCommit \
sim:/ArchDesc0/core/theRob/altRob/pScan \
sim:/ArchDesc0/core/theRob/altRob/pScanPrev \
sim:/ArchDesc0/core/theRob/altRob/pEnd \
sim:/ArchDesc0/core/theRob/altRob/ch0 \
sim:/ArchDesc0/core/theRob/altRob/ch1 \
sim:/ArchDesc0/core/theRob/altRob/ch2 \
sim:/ArchDesc0/core/theRob/altRob/ch3 \
sim:/ArchDesc0/core/theRob/altRob/ch4

add wave -position insertpoint  \
sim:/ArchDesc0/core/theRob/altRob/lastRec
add wave -position insertpoint  \
sim:/ArchDesc0/core/theRob/altRob/array


add wave -position insertpoint  \
sim:/ArchDesc0/core/theRob/drainPointer \
sim:/ArchDesc0/core/theRob/endPointer \
sim:/ArchDesc0/core/theRob/ind_Start \
sim:/ArchDesc0/core/theRob/indB \
sim:/ArchDesc0/core/theRob/indCommitted

add wave -position insertpoint  \
sim:/ArchDesc0/core/theRob/altRob/recCommit \
sim:/ArchDesc0/core/theRob/altRob/recEnd \
sim:/ArchDesc0/core/theRob/altRob/recScan \
sim:/ArchDesc0/core/theRob/altRob/recScanPrev

add wave -position insertpoint  \
sim:/ArchDesc0/core/theRob/altRob/eventFound \
sim:/ArchDesc0/core/theRob/altRob/lastRec \
sim:/ArchDesc0/core/theRob/altRob/lastScannedId \
sim:/ArchDesc0/core/theRob/altRob/lastScannedIdEvt \
sim:/ArchDesc0/core/theRob/altRob/lastScannedIdVar \
sim:/ArchDesc0/core/theRob/altRob/lateEventInfo \
sim:/ArchDesc0/core/theRob/altRob/trg \
sim:/ArchDesc0/core/theRob/altRob/trgEvt

add wave -position insertpoint  \
sim:/ArchDesc0/core/theRob/altRob/pCommit \
sim:/ArchDesc0/core/theRob/indCommitted_int \
sim:/ArchDesc0/core/theRob/indStart_int \
sim:/ArchDesc0/core/theRob/indB_int \
sim:/ArchDesc0/core/theRob/altRob/pScan

add wave -position insertpoint  \
sim:/ArchDesc0/core/theRob/arrayHeadRow
add wave -position insertpoint  \
sim:/ArchDesc0/core/theRob/outRow
add wave -position insertpoint  \
sim:/ArchDesc0/core/theRob/lastScanned

add wave -position insertpoint  \
sim:/ArchDesc0/core/theRob/arrayHeadRow \
sim:/ArchDesc0/core/theRob/outRow \
sim:/ArchDesc0/core/theRob/lastScanned \
sim:/ArchDesc0/core/theRob/lastOut \
sim:/ArchDesc0/core/theRob/altRob/pDrain \
sim:/ArchDesc0/core/theRob/altRob/pCommit \
sim:/ArchDesc0/core/theRob/altRob/pRead \
sim:/ArchDesc0/core/theRob/altRob/pReadPrev \
sim:/ArchDesc0/core/theRob/altRob/lastCommittedId \
sim:/ArchDesc0/core/theRob/altRob/lastReadId \
sim:/ArchDesc0/core/theRob/altRob/lastScannedId \
sim:/ArchDesc0/core/theRob/altRob/currentRow \
sim:/ArchDesc0/core/theRob/altRob/prevRow \
sim:/ArchDesc0/core/theRob/size \
sim:/ArchDesc0/core/theRob/allow \
sim:/ArchDesc0/core/theRob/isEmpty \
sim:/ArchDesc0/core/theRob/altRob/size \
sim:/ArchDesc0/core/theRob/altRob/allow \
sim:/ArchDesc0/core/theRob/altRob/isEmpty

