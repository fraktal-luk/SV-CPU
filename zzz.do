
profile on
profile off
#restart -force

add wave -position insertpoint  \
sim:/ArchDesc0/core/lateEventInfo \
sim:/ArchDesc0/core/branchEventInfo

add wave -position insertpoint  \
sim:/ArchDesc0/core/lastRetired

add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/firstEventId \
sim:/ArchDesc0/core/theExecBlock/firstEventId_N \
sim:/ArchDesc0/core/theExecBlock/staticEventSlot \
sim:/ArchDesc0/core/theExecBlock/memEventPacket \
sim:/ArchDesc0/core/theExecBlock/memRefetchPacket

add wave -position insertpoint  \
sim:/ArchDesc0/core/theLq/submod/oldestRefetchEntry \
sim:/ArchDesc0/core/theLq/submod/oldestRefetchEntryP0 \
sim:/ArchDesc0/core/theLq/submod/oldestRefetchEntryP1

