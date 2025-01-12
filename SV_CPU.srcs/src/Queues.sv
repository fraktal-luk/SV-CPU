
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
            logic refetch;
            logic adrReady;
            Mword adr;
            logic valReady;
            Mword val;
            logic committed;
            logic dontForward;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, 'x, 'x, 'x, 'x, 'x, 'x /*,  'x, 'x*/};
    
        
//        static function automatic logic applies(input AbstractInstruction ins);
//            return isStoreIns(ins);
//        endfunction

        static function automatic logic appliesU(input UopName uname);
            return isStoreUop(uname);
        endfunction
        
        static function automatic Entry newEntry(input InstructionMap imap, input InsId id);
            Entry res = EMPTY_QENTRY;
            res.mid = id;
            res.error = 0;
            res.refetch = 0;
            res.adrReady = 0;
            res.valReady = 0;
            res.committed = 0;
            res.dontForward = (imap.get(id).mainUop == UOP_mem_sts);
            return res;
        endfunction
        
        
            static function void updateAddress(input InstructionMap imap, ref Entry entry, input UopPacket p, input EventInfo brInfo);
            
            endfunction
            
            static function void updateData(input InstructionMap imap, ref Entry entry, input UopPacket p, input EventInfo brInfo);
            
            endfunction            
            
        
        static function void updateEntry(input InstructionMap imap, ref Entry entry, input UopPacket p, input EventInfo brInfo);
            if (imap.getU(p.TMP_oid).name inside {UOP_mem_sti, UOP_mem_stf, UOP_mem_sts}) begin
                entry.adrReady = 1;
                entry.adr = p.result;
            end
            else begin
                assert (imap.getU(p.TMP_oid).name inside {UOP_data_int, UOP_data_fp}) else $fatal(2, "Wrong uop for store data");
            
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


            static function void setRefetch(ref Entry entry);
                entry.refetch = 1;
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

            static function Mword getLink(input Entry entry);
                return 'x;
            endfunction


        static function automatic UopPacket scanQueue(ref Entry entries[SQ_SIZE], input InsId id, input Mword adr);
            Entry found[$] = entries.find with ( item.mid != -1 && item.mid < id && item.adrReady && !item.dontForward && wordOverlap(item.adr, adr));
            Entry fwEntry;
            
            // Youngest older overlapping store:
            // Covers and has data -> OK
            // Covers, not has data -> to RQ, wait ??
            // Not covers -> incomplete forward, refetch

            if (found.size() == 0) return EMPTY_UOP_PACKET;
            else if (found.size() == 1) begin
                fwEntry = found[0];
            end
            else begin
                Entry sorted[$] = found[0:$];
                sorted.sort with (item.mid);
                fwEntry = sorted[$];
            end

            if (!wordInside(adr, fwEntry.adr))
                return '{1, FIRST_U(fwEntry.mid), ES_CANT_FORWARD,   EMPTY_POISON, 'x};
            else if (!fwEntry.valReady)
                return '{1, FIRST_U(fwEntry.mid), ES_SQ_MISS,   EMPTY_POISON, 'x};
            else
                return '{1, FIRST_U(fwEntry.mid), ES_OK,        EMPTY_POISON, fwEntry.val};

        endfunction


        static function automatic void verifyOnCommit(input InstructionMap imap, input Entry entry);
            
        endfunction

    endclass


    class LoadQueueHelper;
        typedef struct {
            InsId mid;
            logic error;
            logic refetch;
            logic adrReady;
            Mword adr;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, 'x, 'x};

//        static function automatic logic applies(input AbstractInstruction ins);
//            return isLoadIns(ins);
//        endfunction

        static function automatic logic appliesU(input UopName uname);
            return isLoadUop(uname);
        endfunction
            
        static function automatic Entry newEntry(input InstructionMap imap, input InsId id);
            Entry res = EMPTY_QENTRY;
            res.mid = id;
            res.adrReady = 0;
            res.error = 0;
            res.refetch = 0;
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
 
            static function void setRefetch(ref Entry entry);
                entry.refetch = 1;
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

            static function Mword getLink(input Entry entry);
                return 'x;
            endfunction

        static function automatic UopPacket scanQueue(ref Entry entries[LQ_SIZE], input InsId id, input Mword adr);
            int found[$] = entries.find_index with ( item.mid != -1 && item.mid > id && item.adrReady && wordOverlap(item.adr, adr));
            
//                if (id > 3230) begin
//                    $error("store %d compared. %d", id, found.size());
//                end
            
            if (found.size() == 0) return EMPTY_UOP_PACKET;
    
            // else: we have a match and the matching loads are incorrect
            foreach (found[i]) begin
                //setError(entries[found[i]]);
                setRefetch(entries[found[i]]);
            end
            
            begin // 'active' indicates that some match has happened without furthr details
                UopPacket res = EMPTY_UOP_PACKET;
                
                int oldestFound[$] = found.min with (item);
                
                res.active = 1; 
                res.TMP_oid = FIRST_U(entries[oldestFound[0]].mid);
                           
                return res;
            end
    
        endfunction


        static function automatic void verifyOnCommit(input InstructionMap imap, input Entry entry);
            
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
            //Mword realTarget;
                Mword immTarget;
                Mword regTarget;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, 'x, 'x, 'x, 'x, /*'x,*/ 'x, 'x};

//        static function automatic logic applies(input AbstractInstruction ins);
//            return isBranchIns(ins);
//        endfunction

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
            
            // If branch immediate, calculate target for taken
            if (ui.name inside {UOP_bc_a, UOP_bc_l, UOP_bc_z, UOP_bc_nz})
                res.immTarget = ii.basicData.adr + ui.argsE[1];
            
            // If imm, real target is known
//            if (isBranchImmIns(abs))
//                res.realTarget = ii.basicData.adr + ui.argsA[1];
            
            return res;
        endfunction
        
        
        static function void updateEntry(input InstructionMap imap, ref Entry entry, input UopPacket p, input EventInfo brInfo);            
            UopName name = imap.getU(p.TMP_oid).name;
            Mword trgArg = imap.getU(p.TMP_oid).argsA[1];
            
            entry.taken = p.result;
            
            entry.condReady = 1;
            entry.trgReady = 1;
            
            //entry.realTarget = brInfo.target;
            
            if (name inside {UOP_br_z, UOP_br_nz})
                entry.regTarget = trgArg;
     
        endfunction

            static function void setCommitted(ref Entry entry);
            endfunction
            
            static function void setError(ref Entry entry);
            endfunction

            static function void setRefetch(ref Entry entry);
                //entry.error = 1;
            endfunction
          
            
            static function logic isCommitted(input Entry entry);
                return 0; 
            endfunction

            static function logic isError(input Entry entry);
                return 0;
            endfunction

            static function Mword getAdr(input Entry entry);
                return entry.immTarget; 
            endfunction

            static function Mword getVal(input Entry entry);
                return 'x;//entry.val;
            endfunction

            static function Mword getLink(input Entry entry);
                return entry.linkAdr;
            endfunction


        static function automatic UopPacket scanQueue(ref Entry entries[BQ_SIZE], input InsId id, input Mword adr);
            Entry found[$] = entries.find with ( item.mid != -1 && item.mid == id);
            
            if (found.size() == 0) return EMPTY_UOP_PACKET;

            begin // 'active' indicates that some match has happened without furthr details
                UopPacket res = EMPTY_UOP_PACKET;
                
                //res.
                
                return res;
            end
    
        endfunction

        static function automatic void verifyOnCommit(input InstructionMap imap, input Entry entry);
            UopName uname = imap.getU(FIRST_U(entry.mid)).name;
            Mword target = imap.get(entry.mid).basicData.target;
            Mword actualTarget = 'x;
                        
            if (entry.taken) begin
                if (uname inside {UOP_br_z, UOP_br_nz})
                    actualTarget = entry.regTarget;
                else
                    actualTarget = entry.immTarget;
            end
            else begin
                actualTarget = entry.linkAdr;
            end
            
            assert (actualTarget === target) else $error("Branch %p committed not matching: %d // %d", uname, actualTarget, target);
            
        endfunction
             
    endclass


endpackage
