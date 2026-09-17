

package IqLogic;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;

    import AbstractSim::*;
    import CoreConfig::*;

    import Insmap::*;

    import UopList::*;

    import ExecDefs::*;


    typedef struct {
        logic ready;
        logic readyArgs[3];
        logic cancelledArgs[3];
    } IqArgState;
    
    localparam IqArgState EMPTY_ARG_STATE = '{ready: 'z, readyArgs: '{'z, 'z, 'z}, cancelledArgs: '{'z, 'z, 'z}};
    localparam IqArgState ZERO_ARG_STATE  = '{ready: '0, readyArgs: '{'0, '0, '0}, cancelledArgs: '{0, 0, 0}};


        // Poison
        typedef struct {
            Poison poisoned[3];
        } IqPoisonState;
    
    localparam IqPoisonState DEFAULT_POISON_STATE = '{poisoned: '{default: EMPTY_POISON}};

    typedef enum {
        IqEmpty, IqSuspended, IqLocked, IqActive, IqIssued 
    } SlotStatus;

    typedef struct {
        logic used;
        UidT uid;
        logic active_;
        SlotStatus status;
        IqArgState state;
        InsId barrier;
        IqPoisonState poisons;
        int issueCounter;
    } IqEntry;

    localparam IqEntry EMPTY_ENTRY = '{used: 0, active_: 0,
                                status: IqEmpty,
                                state: EMPTY_ARG_STATE, barrier: -1, poisons: DEFAULT_POISON_STATE, issueCounter: -1, uid: UIDT_NONE};

    typedef struct {
        UidT uid;
        logic used;
        logic active;
        logic3 registers;
        logic3 bypasses;
        logic3 combined;
        logic3 prevReady;
        Poison poisons[3];
        Poison prevPoisons[3];
        logic all;
    } ReadinessInfo;


    typedef Wakeup Wakeup3[3];
    typedef Wakeup WakeupMatrixD[][3];

    typedef struct {
        UopId regular[RENAME_WIDTH];
        UopId multiply[RENAME_WIDTH];
        UopId branch[RENAME_WIDTH];
        UopId idivider[RENAME_WIDTH];
        UopId float[RENAME_WIDTH];
        UopId fdivider[RENAME_WIDTH];
        UopId mem[RENAME_WIDTH];
        UopId storeData[RENAME_WIDTH];
    } RoutedUops;

    localparam RoutedUops DEFAULT_ROUTED_UOPS_N = '{
        regular: '{default: UID_NONE},
        multiply: '{default: UID_NONE},
        branch: '{default: UID_NONE},
        idivider: '{default: UID_NONE},
        float: '{default: UID_NONE},
        fdivider: '{default: UID_NONE},
        mem: '{default: UID_NONE},
        storeData: '{default: UID_NONE}
    };


endpackage
