
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


    class StoreQueueHelper;
        typedef struct {
            InsId mid;
            logic error;
            logic refetch;
            logic adrReady;
            Mword adr;
            logic valReady;
            Mword val;
                AccessSize size;
            logic uncached;
            logic committed;
            logic dontForward;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, 'x, 'x, 'x, 'x, SIZE_NONE, 'x, 'x, 'x};
    

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
            res.size = getTransactionSize(imap.get(id).mainUop);
            res.uncached = 0;
            res.committed = 0;
            res.dontForward = (imap.get(id).mainUop == UOP_mem_sts);
            return res;
        endfunction
        
        
            static function void updateAddress(input InstructionMap imap, ref Entry entry, input UopPacket p, input EventInfo brInfo);
            
            endfunction
            
            static function void updateData(input InstructionMap imap, ref Entry entry, input UopPacket p, input EventInfo brInfo);
            
            endfunction            
            
        
        static function void updateEntry(input InstructionMap imap, ref Entry entry, input UopPacket p, input EventInfo brInfo);
            if (p.status == ES_UNCACHED_1) begin
                entry.uncached = 1;
            end
            else if (imap.getU(p.TMP_oid).name inside {UOP_mem_sti,  UOP_mem_stib, UOP_mem_stf, UOP_mem_sts}) begin
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


        static function automatic UopPacket scanQueue(input InstructionMap imap, ref Entry entries[SQ_SIZE], input InsId id, input Mword adr);
            AccessSize loadSize = getTransactionSize(imap.get(id).mainUop);
            Entry found[$] = entries.find with ( item.mid != -1 && item.mid < id && item.adrReady && !item.dontForward && memOverlap(item.adr, item.size, adr, loadSize));
            Entry fwEntry;

            if (found.size() == 0) return EMPTY_UOP_PACKET;
            else begin // Youngest older overlapping store:
                Entry vmax[$] = found.max with (item.mid);
                fwEntry = vmax[0];
            end

            if ((loadSize != fwEntry.size) || !memInside(adr, (loadSize), fwEntry.adr, (fwEntry.size)))  // don't allow FW of different size because shifting would be needed
                return '{1, FIRST_U(fwEntry.mid), ES_CANT_FORWARD,   EMPTY_POISON, 'x};
            else if (!fwEntry.valReady)         // Covers, not has data -> to RQ
                return '{1, FIRST_U(fwEntry.mid), ES_SQ_MISS,   EMPTY_POISON, 'x};
            else                                // Covers and has data -> OK
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
                AccessSize size;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, 'x, 'x, SIZE_NONE};

        static function automatic logic appliesU(input UopName uname);
            return isLoadUop(uname);
        endfunction
            
        static function automatic Entry newEntry(input InstructionMap imap, input InsId id);
            Entry res = EMPTY_QENTRY;
            res.mid = id;
            res.adrReady = 0;
            res.error = 0;
            res.refetch = 0;
            res.size = getTransactionSize(imap.get(id).mainUop);

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
                return 'x;
            endfunction

            static function Mword getVal(input Entry entry);
                return 'x;
            endfunction

            static function Mword getLink(input Entry entry);
                return 'x;
            endfunction


        static function automatic UopPacket scanQueue(input InstructionMap imap, ref Entry entries[LQ_SIZE], input InsId id, input Mword adr);
            UopPacket res = EMPTY_UOP_PACKET;
            AccessSize trSize = getTransactionSize(imap.get(id).mainUop);
            
            // CAREFUL: we search for all matching entries
            int found[$] = entries.find_index with (item.mid > id && item.adrReady && memOverlap(item.adr, (item.size), adr, (trSize)));
                Entry found_e[$] = entries.find with (item.mid > id && item.adrReady && memOverlap(item.adr, (item.size), adr, (trSize)));
            
            if (found.size() == 0) return res;
    
            foreach (found[i]) setRefetch(entries[found[i]]); // We have a match so matching loads are incorrect
            
            begin // 'active' indicates that some match has happened without further details
                int oldestFound[$] = found.min with (entries[item].mid);
                res.TMP_oid = FIRST_U(entries[oldestFound[0]].mid);
                res.active = 1;
                    
                    // TODO: temporary DB print. Make testcases where it happens
                    if (found.size() > 1) $error("%p\n%p\n> %d", found, found_e, oldestFound);
            end
            
            return res;
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
            Mword immTarget;
            Mword regTarget;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, 'x, 'x, 'x, 'x, 'x, 'x, 'x, 'x};

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

            return res;
        endfunction
        
        
        static function void updateEntry(input InstructionMap imap, ref Entry entry, input UopPacket p, input EventInfo brInfo);            
            UopName name = imap.getU(p.TMP_oid).name;
            Mword trgArg = imap.getU(p.TMP_oid).argsA[1];
            
            entry.taken = p.result;
            
            entry.condReady = 1;
            entry.trgReady = 1;
            
            if (name inside {UOP_br_z, UOP_br_nz})
                entry.regTarget = trgArg;
     
        endfunction

            static function void setCommitted(ref Entry entry);
            endfunction
            
            static function void setError(ref Entry entry);
            endfunction

            static function void setRefetch(ref Entry entry);
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
                return 'x;
            endfunction

            static function Mword getLink(input Entry entry);
                return entry.linkAdr;
            endfunction


        static function automatic UopPacket scanQueue(input InstructionMap imap, ref Entry entries[BQ_SIZE], input InsId id, input Mword adr);        
            return EMPTY_UOP_PACKET;
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
