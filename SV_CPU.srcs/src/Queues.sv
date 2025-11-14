
package Queues;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    import EmulationDefs::*;
    
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

        localparam InstructionMap::Milestone QUEUE_ENTER = InstructionMap::SqEnter;
        localparam InstructionMap::Milestone QUEUE_FLUSH = InstructionMap::SqFlush;
        localparam InstructionMap::Milestone QUEUE_EXIT =  InstructionMap::SqExit;
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

        localparam InstructionMap::Milestone QUEUE_ENTER = InstructionMap::SqEnter;
        localparam InstructionMap::Milestone QUEUE_FLUSH = InstructionMap::SqFlush;
        localparam InstructionMap::Milestone QUEUE_EXIT =  InstructionMap::SqExit;
    endclass


    class LoadQueueHelper;
        typedef LqEntry Entry;
        localparam Entry EMPTY_QENTRY = StoreQueueHelper::EMPTY_QENTRY;
        
        localparam InstructionMap::Milestone QUEUE_ENTER = InstructionMap::LqEnter;
        localparam InstructionMap::Milestone QUEUE_FLUSH = InstructionMap::LqFlush;
        localparam InstructionMap::Milestone QUEUE_EXIT =  InstructionMap::LqExit;
    endclass
    
    
    class BranchQueueHelper;
        typedef BqEntry Entry;
        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, 'x, 'x, 'x, 'x, 'x, 'x};

        localparam InstructionMap::Milestone QUEUE_ENTER = InstructionMap::BqEnter;
        localparam InstructionMap::Milestone QUEUE_FLUSH = InstructionMap::BqFlush;
        localparam InstructionMap::Milestone QUEUE_EXIT =  InstructionMap::BqExit;
    endclass


    function automatic MemWriteInfo makeWriteInfo(input SqEntry sqe);
        return '{sqe.mid != -1 && sqe.valReady && !sqe.accessDesc.sys && !sqe.error && !sqe.refetch,
                sqe.accessDesc.vadr, sqe.translation.padr, sqe.val, sqe.accessDesc.size, sqe.accessDesc.uncachedStore};
    endfunction

    function automatic MemWriteInfo makeSysWriteInfo(input SqEntry sqe);
        return '{sqe.mid != -1 && sqe.valReady && sqe.accessDesc.sys && !sqe.error && !sqe.refetch,
                sqe.accessDesc.vadr, 'x, sqe.val, sqe.accessDesc.size, 'x};
    endfunction

endpackage
