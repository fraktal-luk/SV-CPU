

package CoreConfig;


    localparam int FETCH_QUEUE_SIZE = 16;
    localparam int BC_QUEUE_SIZE = 128;

    localparam int N_REGS_INT = 128;
    localparam int N_REGS_FLOAT = 128;

    localparam int ISSUE_QUEUE_SIZE = 24;

    localparam int ROB_SIZE = 128;
    localparam int ROB_WIDTH = 4;

    localparam int LQ_SIZE = 40;
    localparam int SQ_SIZE = 40;
    localparam int BQ_SIZE = 32;

    localparam int FETCH_WIDTH = 4;
    localparam int RENAME_WIDTH = 4;
    
    localparam int DISPATCH_WIDTH = RENAME_WIDTH;

    localparam int N_RENAME_STAGES = 2; // Number of stages between FQ and OOO buffers

    // General uarch defs
    localparam int N_INT_PORTS = 6;
    localparam int N_MEM_PORTS = 4;
    localparam int N_VEC_PORTS = 4;

    localparam int FW_FIRST = -2 + 0;
    localparam int FW_LAST = 1;


    localparam int N_WAYS_INS = 6;
    localparam int N_WAYS_DATA = 6;


    // Impl specific
    localparam int BLOCK_SIZE = 64;
    localparam int BLOCK_OFFSET_BITS = $clog2(BLOCK_SIZE);
    localparam int WAY_SIZE = 4096; // FUTURE: specific for each cache?
    localparam int BLOCKS_PER_WAY = WAY_SIZE/BLOCK_SIZE;    


    localparam int DATA_ARRAY_FILL_DELAY = 14;
    localparam int DATA_TLB_FILL_DELAY = 11;

    localparam int INS_ARRAY_FILL_DELAY = 14;
    localparam int INS_TLB_FILL_DELAY = 11;


endpackage
