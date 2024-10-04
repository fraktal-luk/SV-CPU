
package Queues;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    
    import AbstractSim::*;
    import Insmap::*;
    import ExecDefs::*;


    class QueueHelper;
        typedef struct {
            logic a;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{'x};

        
    endclass


    class StoreQueueHelper;
        typedef struct {
            InsId id;
            logic error;
            logic adrReady;
            Mword adr;
            logic valReady;
            Mword val;
            logic committed;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, 'x, 'x, 'x, 'x};
    
        
        static function automatic logic applies(input AbstractInstruction ins);
            return isStoreIns(ins);
        endfunction

        static function automatic Entry newEntry(input OpSlot op);
            Entry res = EMPTY_QENTRY;
            res.id = op.id;
            res.error = 0;
            res.adrReady = 0;
            res.valReady = 0;
            res.committed = 0;
            return res;
        endfunction
        
        static function void updateEntry(ref Entry entry, input OpPacket p, input EventInfo brInfo);
            entry.adrReady = 1;
            entry.adr = p.result;            
        endfunction
    endclass


    class LoadQueueHelper;
        typedef struct {
            InsId id;
            logic error;
            logic adrReady;
            Mword adr;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, 'x};

        static function automatic logic applies(input AbstractInstruction ins);
            return isLoadIns(ins);
        endfunction

        static function automatic Entry newEntry(input OpSlot op);
            Entry res = EMPTY_QENTRY;
            res.id = op.id;
            res.adrReady = 0;
            res.error = 0;
            return res;
        endfunction
        
        static function void updateEntry(ref Entry entry, input OpPacket p, input EventInfo brInfo);
            entry.adrReady = 1;
            entry.adr = p.result;
        endfunction  
    endclass
    
    
    class BranchQueueHelper;
        typedef struct {
            InsId id;
            logic predictedTaken;
            logic taken;
            Mword linkAdr;
            Mword target;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, 'x, 'x};

        static function automatic logic applies(input AbstractInstruction ins);
            return isBranchIns(ins);
        endfunction

        static function automatic Entry newEntry(input OpSlot op);
            Entry res = EMPTY_QENTRY;
            res.id = op.id;
            return res;
        endfunction
        
        static function void updateEntry(ref Entry entry, input OpPacket p, input EventInfo brInfo);
            entry.taken = brInfo.op.active;
            entry.target = brInfo.target;
        endfunction
          
    endclass


endpackage