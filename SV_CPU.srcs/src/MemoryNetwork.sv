
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import EmulationDefs::*;
import EmulationMemories::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;

import CacheDefs::*;


module MemoryNetwork();

    UopPacket uopE0[N_MEM_PORTS];
    UopPacket uopE1[N_MEM_PORTS];
    UopPacket uopE2[N_MEM_PORTS];
    UopPacket uopE3[N_MEM_PORTS];

    AccessDesc adE0[N_MEM_PORTS];
    AccessDesc adE1[N_MEM_PORTS];
    AccessDesc adE2[N_MEM_PORTS];
    AccessDesc adE3[N_MEM_PORTS];

    Translation trE0[N_MEM_PORTS];
    Translation trE1[N_MEM_PORTS];
    Translation trE2[N_MEM_PORTS];
    Translation trE3[N_MEM_PORTS];

        Translation trE0d[N_MEM_PORTS];


    DataCacheOutput cacheOutE1[N_MEM_PORTS];
    DataCacheOutput uncachedOutE1[N_MEM_PORTS];
    DataCacheOutput sysOutE1[N_MEM_PORTS];

    UopMemPacket sqOutE1[N_MEM_PORTS];
    UopMemPacket lqOutE1[N_MEM_PORTS];


    DataCacheOutput cacheOutE1d[N_MEM_PORTS];
    DataCacheOutput uncachedOutE1d[N_MEM_PORTS];
    DataCacheOutput sysOutE1d[N_MEM_PORTS];

    UopMemPacket sqOutE1d[N_MEM_PORTS];
    UopMemPacket lqOutE1d[N_MEM_PORTS];


    always @(negedge AbstractCore.clk) begin
        cacheOutE1d <= cacheOutE1;
        uncachedOutE1d <= uncachedOutE1;
        sysOutE1d <= sysOutE1;

        lqOutE1d <= lqOutE1;
    end



    assign uopE0 = '{0: theExecBlock.mem0.pE0_E, 1: theExecBlock.mem1.pE0_E, 2: theExecBlock.mem2.pE0_E, default: EMPTY_UOP_PACKET};
    assign uopE1 = '{0: theExecBlock.mem0.pE1_E, 1: theExecBlock.mem1.pE1_E, 2: theExecBlock.mem2.pE1_E, default: EMPTY_UOP_PACKET};
    assign uopE2 = '{0: theExecBlock.mem0.pE2_E, 1: theExecBlock.mem1.pE2_E, 2: theExecBlock.mem2.pE2_E, default: EMPTY_UOP_PACKET};
    assign uopE3 = '{0: theExecBlock.mem0.pE3_E, 1: theExecBlock.mem1.pE3_E, 2: theExecBlock.mem2.pE3_E, default: EMPTY_UOP_PACKET};

    assign adE0 = '{0: theExecBlock.mem0.accessDescE0, 1: theExecBlock.mem1.accessDescE0, 2: theExecBlock.mem2.accessDescE0, default: DEFAULT_ACCESS_DESC};
    assign adE1 = '{0: theExecBlock.mem0.accessDescE1, 1: theExecBlock.mem1.accessDescE1, 2: theExecBlock.mem2.accessDescE1, default: DEFAULT_ACCESS_DESC};
    assign adE2 = '{0: theExecBlock.mem0.accessDescE2, 1: theExecBlock.mem1.accessDescE2, 2: theExecBlock.mem2.accessDescE2, default: DEFAULT_ACCESS_DESC};
    assign adE3 = '{0: theExecBlock.mem0.accessDescE3, 1: theExecBlock.mem1.accessDescE3, 2: theExecBlock.mem2.accessDescE3, default: DEFAULT_ACCESS_DESC};

    assign trE0d = theExecBlock.dcacheTranslationsE0d;//'{0: dcacheTranslationsE0d[0], 1: dcacheTranslationsE0d[1], 2: dcacheTranslationsE0d[2], default: DEFAULT_TRANSLATION};
    assign trE0 = '{0: theExecBlock.mem0.trE0, 1: theExecBlock.mem1.trE0, 2: theExecBlock.mem2.trE0, default: DEFAULT_TRANSLATION};
    assign trE1 = '{0: theExecBlock.mem0.trE1, 1: theExecBlock.mem1.trE1, 2: theExecBlock.mem2.trE1, default: DEFAULT_TRANSLATION};
    assign trE2 = '{0: theExecBlock.mem0.trE2, 1: theExecBlock.mem1.trE2, 2: theExecBlock.mem2.trE2, default: DEFAULT_TRANSLATION};
    assign trE3 = '{0: theExecBlock.mem0.trE3, 1: theExecBlock.mem1.trE3, 2: theExecBlock.mem2.trE3, default: DEFAULT_TRANSLATION};

    assign cacheOutE1 = theExecBlock.dcacheOuts_E1;
    assign uncachedOutE1 = theExecBlock.uncachedOuts_E1;
    assign sysOutE1 = theExecBlock.sysOuts_E1;

    assign sqOutE1 = theSq.responseE1;
    assign lqOutE1 = theLq.responseE1;

    assign sqOutE1d = theSq.responseE1d_N;


endmodule
