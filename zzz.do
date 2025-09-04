
profile on
profile off
#restart -force

add wave -position insertpoint  \
sim:/ArchDesc0/core/lateEventInfo

add wave -position insertpoint  \
sim:/ArchDesc0/core/lastRetired

add wave -position insertpoint  \
sim:/ArchDesc0/core/theExecBlock/firstEventId \
sim:/ArchDesc0/core/theExecBlock/staticEventSlot \
sim:/ArchDesc0/core/theExecBlock/memEventPacket \
sim:/ArchDesc0/core/theExecBlock/memRefetchPacket
