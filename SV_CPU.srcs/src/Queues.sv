
package Queues;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    
    import AbstractSim::*;
    import Insmap::*;
    import ExecDefs::*;
    
    import UopList::*;


        typedef int IntQueue[$];

    class QueueHelper;
        typedef struct {
            logic a;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{'x};

    endclass


    class StoreQueueHelper;
        typedef struct {
            InsId mid;
            logic error;
            logic adrReady;
            Mword adr;
            logic valReady;
            Mword val;
            logic committed;
            //    Mword dataVal;
            //    logic dataValReady;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, 'x, 'x, 'x, 'x /*,  'x, 'x*/};
    
        
        static function automatic logic applies(input AbstractInstruction ins);
            return isStoreIns(ins);
        endfunction

            static function automatic logic appliesU(input UopName uname);
                return isStoreUop(uname);
            endfunction
        
        static function automatic Entry newEntry(input InstructionMap imap, input InsId id);
            Entry res = EMPTY_QENTRY;
            res.mid = id;
            res.error = 0;
            res.adrReady = 0;
            res.valReady = 0;
            res.committed = 0;
            //    res.dataValReady = 0;
            return res;
        endfunction
        
        
            static function void updateAddress(input InstructionMap imap, ref Entry entry, input UopPacket p, input EventInfo brInfo);
            
            endfunction
            
            static function void updateData(input InstructionMap imap, ref Entry entry, input UopPacket p, input EventInfo brInfo);
            
            endfunction            
            
        
        static function void updateEntry(input InstructionMap imap, ref Entry entry, input UopPacket p, input EventInfo brInfo);
            // TODO: check if store adr uop
            if (imap.getU(p.TMP_oid).name inside {UOP_mem_sti, UOP_mem_stf, UOP_mem_sts}) begin
                entry.adrReady = 1;
                entry.adr = p.result;
                
                //entry.valReady = 1;
                //entry.val = imap.getU(p.TMP_oid).argsA[2];
            end
            // TODO: assert store data uop
            else begin
                entry.valReady = 1;
                entry.val = p.result;
            end
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

            static function Mword getAdr(input Entry entry);
                return entry.adr; 
            endfunction

            static function Mword getVal(input Entry entry);
                return entry.val;
            endfunction
 
            static function automatic UopPacket scanQueue(input Entry entries[SQ_SIZE], input InsId id, input Mword adr);
                //typedef StoreQueueHelper::Entry SqEntry;
                // TODO: don't include sys stores in adr matching 
                Entry found[$] = entries.find with ( item.mid != -1 && item.mid < id && item.adrReady && wordOverlap(item.adr, adr));

                if (found.size() == 0) return EMPTY_UOP_PACKET;
                else if (found.size() == 1) begin 
                    if (wordInside(adr, found[0].adr)) return '{1, FIRST_U(found[0].mid), ES_OK, EMPTY_POISON, found[0].val};
                    else return '{1, FIRST_U(found[0].mid), ES_INVALID, EMPTY_POISON, 'x};
                end
                else begin
                    Entry sorted[$] = found[0:$];
                    sorted.sort with (item.mid);
                    
                    if (wordInside(adr, sorted[$].adr)) return '{1, FIRST_U(sorted[$].mid), ES_OK, EMPTY_POISON, sorted[$].val};
                    else return '{1, FIRST_U(sorted[$].mid), ES_INVALID, EMPTY_POISON, 'x};
                end
        
            endfunction 
    endclass


    class LoadQueueHelper;
        typedef struct {
            InsId mid;
            logic error;
            logic adrReady;
            Mword adr;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, 'x};

        static function automatic logic applies(input AbstractInstruction ins);
            return isLoadIns(ins);
        endfunction

            static function automatic logic appliesU(input UopName uname);
                return isLoadUop(uname);
            endfunction
            
        static function automatic Entry newEntry(input InstructionMap imap, input InsId id);
            Entry res = EMPTY_QENTRY;
            res.mid = id;
            res.adrReady = 0;
            res.error = 0;
            return res;
        endfunction
        
        static function void updateEntry(input InstructionMap imap, ref Entry entry, input UopPacket p, input EventInfo brInfo);
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

            static function Mword getAdr(input Entry entry);
                return 'x;//entry.adr; 
            endfunction

            static function Mword getVal(input Entry entry);
                return 'x;//entry.val;
            endfunction

                static function automatic UopPacket scanQueue(input Entry entries[LQ_SIZE], input InsId id, input Mword adr);
                    Entry found[$] = entries.find with ( item.mid != -1 && item.mid > id && item.adrReady && wordOverlap(item.adr, adr));
                    
                    if (found.size() == 0) return EMPTY_UOP_PACKET;
            
                    // else: we have a match and the matching loads are incorrect
                    foreach (found[i]) begin
                        setError(found[i]);
                    end
                    
                    begin // 'active' indicates that some match has happened without furthr details
                        UopPacket res = EMPTY_UOP_PACKET;
                        
                        Entry oldestFound[$] = found.min with (item.mid);
                        
                        res.active = 1; 
                        res.TMP_oid = FIRST_U(oldestFound[0].mid);
                                   
                        return res;
                    end
            
                endfunction
    endclass
    
    
    class BranchQueueHelper;
        typedef struct {
            InsId mid;
            logic predictedTaken;
            logic taken;
            logic condReady;
            logic trgReady;
            Mword linkAdr;
            Mword predictedTarget;
            Mword realTarget;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, 'x, 'x, 'x, 'x, 'x};

        static function automatic logic applies(input AbstractInstruction ins);
            return isBranchIns(ins);
        endfunction

            static function automatic logic appliesU(input UopName uname);
                return isBranchUop(uname);
            endfunction
            
        static function automatic Entry newEntry(input InstructionMap imap, input InsId id);
            Entry res = EMPTY_QENTRY;
            InstructionInfo ii = imap.get(id);
            UopInfo ui = imap.getU(FIRST_U(id));
            AbstractInstruction abs = ii.basicData.dec;
            
            res.mid = id;
            
                res.predictedTaken = 0;

                res.condReady = 0;
                res.trgReady = isBranchImmIns(abs);
                
                res.linkAdr = ii.basicData.adr + 4;
                
                // If imm, real target is known
                if (isBranchImmIns(abs))
                    res.realTarget = ii.basicData.adr + ui.argsA[1];
                
            return res;
        endfunction
        
        
        static function void updateEntry(input InstructionMap imap, ref Entry entry, input UopPacket p, input EventInfo brInfo);            
            entry.taken = brInfo.active;
            
            entry.condReady = 1;
            entry.trgReady = 1;
            
            entry.realTarget = brInfo.target;
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

            static function Mword getAdr(input Entry entry);
                return 'x;//entry.adr; 
            endfunction

            static function Mword getVal(input Entry entry);
                return 'x;//entry.val;
            endfunction


            static function automatic UopPacket scanQueue(input Entry entries[BQ_SIZE], input InsId id, input Mword adr);

                begin // 'active' indicates that some match has happened without furthr details
                    UopPacket res = EMPTY_UOP_PACKET;
                    return res;
                end
        
            endfunction

                 
    endclass


endpackage