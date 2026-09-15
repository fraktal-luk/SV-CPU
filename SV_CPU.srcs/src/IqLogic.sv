

package IqLogic;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;

    import AbstractSim::*;
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

endpackage
