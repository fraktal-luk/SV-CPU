
package Queues;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    
    import AbstractSim::*;
    import Insmap::*;
    import CacheDefs::*;
    import ExecDefs::*;
    
    import UopList::*;


    class QueueHelper;
        typedef struct {
            logic a;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{'x};

    endclass


    typedef struct {
        InsId mid;
        
        logic valReady;
        Mword val;

        AccessDesc accessDesc;
        Translation translation;

        logic committed;
        logic error;
        logic refetch;
    } SqEntry;

        
    typedef SqEntry LqEntry;


    typedef struct {
        InsId mid;
        logic predictedTaken;
        logic taken;
        logic condReady;
        logic trgReady;
        Mword linkAdr;
        Mword predictedTarget;
        Mword immTarget;
        Mword regTarget;
    } BqEntry;     


    class StoreQueueHelper;
        typedef SqEntry Entry;
        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, DEFAULT_ACCESS_DESC, DEFAULT_TRANSLATION, 'x, 'x, 'x};
    endclass


    class LoadQueueHelper;
        typedef LqEntry Entry;
        localparam Entry EMPTY_QENTRY = StoreQueueHelper::EMPTY_QENTRY;
    endclass
    
    
    class BranchQueueHelper;
        typedef BqEntry Entry;
        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, 'x, 'x, 'x, 'x, 'x, 'x};     
    endclass


endpackage
