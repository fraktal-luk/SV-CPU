
package Queues;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    
    import AbstractSim::*;
    import Insmap::*;
    import ExecDefs::*;


            typedef int IntQueue[$];

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
        
            static function void setCommitted(ref Entry entry);
                entry.committed = 1;
            endfunction
            
            static function void setError(ref Entry entry);
                entry.error = 1;
            endfunction
            
            
            static function logic isCommitted(input Entry entry);
                return entry.committed; 
            endfunction

            static function logic isError(input Entry entry);
                return entry.error;
            endfunction

               static function automatic IntQueue TMP_scan(ref Entry entries[SQ_SIZE], input InsId id, input Mword adr);
                   IntQueue res = entries.find_index with (item.id != -1 && item.id < id && item.adrReady && wordOverlap(item.adr, adr));
                   return res;
               endfunction
               
            static function automatic OpPacket scanQueue(input Entry entries[SQ_SIZE], input InsId id, input Word adr);
                typedef StoreQueueHelper::Entry SqEntry;
                // TODO: don't include sys stores in adr matching 
                Entry found[$] = entries.find with ( item.id != -1 && item.id < id && item.adrReady && wordOverlap(item.adr, adr));
                
                  //  IntQueue found_N = //content_N.find with ( item.id != -1 && item.id < id && item.adrReady && wordOverlap(item.adr, adr));
                  //                       HELPER::TMP_scan(content_N, id, adr);
               
                if (found.size() == 0) return EMPTY_OP_PACKET;
                else if (found.size() == 1) begin 
                    if (wordInside(adr, found[0].adr)) return '{1, found[0].id, ES_OK, EMPTY_POISON, 'x, found[0].val};
                    else return '{1, found[0].id, ES_INVALID, EMPTY_POISON, 'x, 'x};
                end
                else begin
                    Entry sorted[$] = found[0:$];
                    sorted.sort with (item.id);
                    
                    if (wordInside(adr, sorted[$].adr)) return '{1, sorted[$].id, ES_OK, EMPTY_POISON, 'x, sorted[$].val};
                    return '{1, sorted[$].id, ES_INVALID, EMPTY_POISON, 'x, 'x};
                end
        
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
        
            static function void setCommitted(ref Entry entry);
            endfunction
            
            static function void setError(ref Entry entry);
                entry.error = 1;
            endfunction
            
            
            static function logic isCommitted(input Entry entry);
                return 0; 
            endfunction

            static function logic isError(input Entry entry);
                return entry.error;
            endfunction
            
               static function automatic IntQueue TMP_scan(ref Entry entries[LQ_SIZE], input InsId id, input Mword adr);
               
               endfunction
               
                static function automatic OpPacket scanQueue(input Entry entries[LQ_SIZE], input InsId id, input Word adr);
                    // TODO: don't include sys stores in adr matching 
                    int found[$] = entries.find_index with ( item.id != -1 && item.id > id && item.adrReady && wordOverlap(item.adr, adr));
                   
                    if (found.size() == 0) return EMPTY_OP_PACKET;
            
                    // else: we have a match and the matching loads are incorrect
                    foreach (found[i]) begin
                       // content_N[found[i]].valReady = 'x;
                           setError(entries[found[i]]);
                    end
                    
                    begin // 'active' indicates that some match has happened without furthr details
                        OpPacket res = EMPTY_OP_PACKET;
                        res.active = 1;            
                        return res;
                    end
            
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

            static function void setCommitted(ref Entry entry);
            endfunction
            
            static function void setError(ref Entry entry);
            endfunction
            
            
            static function logic isCommitted(input Entry entry);
                return 0; 
            endfunction

            static function logic isError(input Entry entry);
                return 0;
            endfunction
            
               static function automatic IntQueue TMP_scan(input Entry entries[BQ_SIZE], input InsId id, input Mword adr);
               
               endfunction
               
                static function automatic OpPacket scanQueue(input Entry entries[BQ_SIZE], input InsId id, input Word adr);

                    
                    begin // 'active' indicates that some match has happened without furthr details
                        OpPacket res = EMPTY_OP_PACKET;
                        //res.active = 1;            
                        return res;
                    end
            
                endfunction

                 
    endclass


endpackage