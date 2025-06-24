
profile on
profile off
#restart -force

add wave -position insertpoint  \
sim:/ArchDesc0/core/theFrontend/chk \
sim:/ArchDesc0/core/theFrontend/chk_2 \
sim:/ArchDesc0/core/theFrontend/chk_3 \
sim:/ArchDesc0/core/theFrontend/chk_4

add wave -position insertpoint  \
sim:/ArchDesc0/core/theFrontend/instructionCache/readOut \
sim:/ArchDesc0/core/theFrontend/instructionCache/readOutUnc \
sim:/ArchDesc0/core/theFrontend/instructionCache/readOutSig \
sim:/ArchDesc0/core/theFrontend/instructionCache/readOutCached \
sim:/ArchDesc0/core/theFrontend/instructionCache/readOutUncached

add wave -position insertpoint  \
sim:/ArchDesc0/core/theFrontend/instructionCache/readEn \
sim:/ArchDesc0/core/theFrontend/instructionCache/readAddress \
sim:/ArchDesc0/core/theFrontend/instructionCache/readEnUnc \
sim:/ArchDesc0/core/theFrontend/instructionCache/readAddressUnc
