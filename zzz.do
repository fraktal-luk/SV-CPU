
profile on
profile off
#restart -force


add wave -position insertpoint  \
sim:/ArchDesc0/mainEmul

add wave -position insertpoint  \
sim:/ArchDesc0/emulTestName \
sim:/ArchDesc0/simTestName


add wave -position insertpoint  \
sim:/ArchDesc0/core/lastRetired \
sim:/ArchDesc0/core/lateEventInfo \
sim:/ArchDesc0/core/lateEventInfoWaiting \
sim:/ArchDesc0/core/lateEventInfoWaitingInt \
sim:/ArchDesc0/core/lateEventInfoWaitingReset


add wave -position insertpoint  \
sim:/ArchDesc0/core/theFrontend/cachedFetcherState

add wave -position insertpoint  \
sim:/ArchDesc0/core/theFrontend/fetchAllowCa \
sim:/ArchDesc0/core/theFrontend/fetchEnable \
sim:/ArchDesc0/core/theFrontend/branchEventInfo \
sim:/ArchDesc0/core/theFrontend/lateEventInfo \
sim:/ArchDesc0/core/theFrontend/waitEvt \
sim:/ArchDesc0/core/theFrontend/frontRedCa \
sim:/ArchDesc0/core/theFrontend/frontRedOnMiss

add wave -position insertpoint  \
sim:/ArchDesc0/core/theFrontend/predStateF0 \
sim:/ArchDesc0/core/theFrontend/predStateF2 \
sim:/ArchDesc0/core/theFrontend/stageFetch2 \
sim:/ArchDesc0/core/theFrontend/stageFetch2_N \
sim:/ArchDesc0/core/theFrontend/chk \
sim:/ArchDesc0/core/theFrontend/chk_2


add wave -position insertpoint  \
sim:/ArchDesc0/core/committedPredState \
sim:/ArchDesc0/core/committedPredStatePrev
