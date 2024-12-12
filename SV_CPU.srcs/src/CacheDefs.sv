

package CacheDefs;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    
    import AbstractSim::*;
    import Insmap::*;


    typedef Word FetchGroup_N[FETCH_WIDTH];

    typedef enum {
        CR_INVALID, // Address illegal
            CR_NOT_MAPPED, // page table walk finds no mapping entry
        CR_TLB_MISS,
        CR_TAG_MISS,
        CR_HIT,
        CR_MULTIPLE
    } CacheReadStatus;
    
    typedef struct {
        logic allowed;
    } InstructionLineDesc;
    
    

    typedef struct {
        logic active;
        CacheReadStatus status;
        InstructionLineDesc desc;        
        FetchGroup_N words;
    } InstructionCacheOutput;
    
    localparam InstructionCacheOutput EMPTY_INS_CACHE_OUTPUT = '{
        0,
        CR_INVALID,
        '{0},
        '{default: 'x}
    };
    


endpackage
