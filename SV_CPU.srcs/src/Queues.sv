
package Queues;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    
    import AbstractSim::*;
    import Insmap::*;



    class QueueHelper;
        typedef struct {
            logic a;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{'x};

        static function automatic print();
            //$display("a haha");
        endfunction
        
    endclass


    class StoreQueueHelper;
        typedef struct {
            InsId id;
            logic x;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, 'x};   
    
        static function automatic print();
            //$display("SQ!!!");
        endfunction
        
        static function automatic logic applies(input AbstractInstruction ins);
            return isStoreIns(ins);
        endfunction

        static function automatic Entry newEntry(input OpSlot op);
            Entry res = EMPTY_QENTRY;
            res.id = op.id;
            return res;
        endfunction
    endclass


    class LoadQueueHelper;
        typedef struct {
            InsId id;
            Word first;
            logic second;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, '0, 'x};

        static function automatic print();
            //$display("LQ!!!");
        endfunction

        static function automatic logic applies(input AbstractInstruction ins);
            return isLoadIns(ins);
        endfunction

        static function automatic Entry newEntry(input OpSlot op);
            Entry res = EMPTY_QENTRY;
            res.id = op.id;
            return res;
        endfunction   
    endclass
    
    
    class BranchQueueHelper;
        typedef struct {
            InsId id;
            Word x;
            Word y;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'z};

        static function automatic print();
            //$display("BQ!!!");
        endfunction

        static function automatic logic applies(input AbstractInstruction ins);
            return isBranchIns(ins);
        endfunction

        static function automatic Entry newEntry(input OpSlot op);
            Entry res = EMPTY_QENTRY;
            res.id = op.id;
            return res;
        endfunction      
    endclass


endpackage