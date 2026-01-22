
vlib questa_lib/work
vlib questa_lib/msim
vlib questa_lib/msim/xil_defaultlib

vmap xil_defaultlib questa_lib/msim/xil_defaultlib

vlog  -incr -mfcu -sv -work xil_defaultlib  \
"../../../../SV_CPU.srcs/src/InsDefs.sv" \
"../../../../SV_CPU.srcs/src/Asm.sv" \
"../../../../SV_CPU.srcs/src/ControlRegisters.sv" \
"../../../../SV_CPU.srcs/src/EmulationDefs.sv" \
"../../../../SV_CPU.srcs/src/EmulationMemories.sv" \
"../../../../SV_CPU.srcs/src/Emulation.sv" \
"../../../../SV_CPU.srcs/src/UopList.sv" \
"../../../../SV_CPU.srcs/src/AbstractSim.sv" \
"../../../../SV_CPU.srcs/src/InstructionMap.sv" \
"../../../../SV_CPU.srcs/src/CacheDefs.sv" \
"../../../../SV_CPU.srcs/src/ExecDefs.sv" \
"../../../../SV_CPU.srcs/src/ControlHandling.sv" \
"../../../../SV_CPU.srcs/src/Queues.sv" \
"../../../../SV_CPU.srcs/src/Testing.sv" \
"../../../../SV_CPU.srcs/src/AbstractCore.sv" \
"../../../../SV_CPU.srcs/src/DataL1.sv" \
"../../../../SV_CPU.srcs/src/DataMemModules.sv" \
"../../../../SV_CPU.srcs/src/EmulTest.sv" \
"../../../../SV_CPU.srcs/src/ExecBlock.sv" \
"../../../../SV_CPU.srcs/src/Frontend.sv" \
"../../../../SV_CPU.srcs/src/InstructionL1.sv" \
"../../../../SV_CPU.srcs/src/IssueQueues.sv" \
"../../../../SV_CPU.srcs/src/MemBuffers.sv" \
"../../../../SV_CPU.srcs/src/MemSubpipe.sv" \
"../../../../SV_CPU.srcs/src/Modules.sv" \
"../../../../SV_CPU.srcs/src/ReorderBuffer.sv" \
"../../../../SV_CPU.srcs/src/ReplayQueue.sv" \
"../../../../SV_CPU.srcs/src/SystemRegisterUnit.sv" \
"../../../../SV_CPU.srcs/src/ArchDesc0.sv" \
"../../../../SV_CPU.srcs/src/UncachedDataUnit.sv" \
"../../../../SV_CPU.srcs/src/UncachedFetchUnit.sv"


# compile glbl module
vlog -work xil_defaultlib "glbl.v"

quit -force

