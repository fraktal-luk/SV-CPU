
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

            AccessSize size;

            logic adrReady;
            Mword adr;
            logic phyAdrReady;
            Dword phyAdr;
            
            logic valReady;
            Mword val;
            
                logic uncached;  // TODO:  include in page desc
            
            logic committed;
            logic error;
            logic refetch;
            
                logic dontForward; // TODO: replace
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, SIZE_NONE, 'x, 'x, 'x, 'x, 'x, 'x, 'x, 'x, 'x, 'x, 'x};
        
        
        static function automatic Entry newEntry(input InstructionMap imap, input InsId id);
            return  '{
                mid: id,
                adrReady: 0,
                adr: 'x,
                phyAdrReady: 0,
                phyAdr: 'x,
                valReady: 0,
                val: 'x,
                size: getTransactionSize(imap.get(id).mainUop),
                uncached: 0,
                committed: 0,
                error: 0,
                refetch: 0,
                dontForward: (imap.get(id).mainUop == UOP_mem_sts)
            };
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

    endclass



    class LoadQueueHelper;
        typedef struct {
            InsId mid;
            
                AccessSize size;

            logic adrReady;
            Mword adr;
            logic phyAdrReady;
            Dword phyAdr;
            
                logic error;
                logic refetch;
        } Entry;

        localparam Entry EMPTY_QENTRY = '{-1, SIZE_NONE, 'x, 'x, 'x, 'x, 'x, 'x};
            
        static function automatic Entry newEntry(input InstructionMap imap, input InsId id);
            Entry res = '{
                mid: id,
                size: getTransactionSize(imap.get(id).mainUop),
                adrReady: 0,
                adr: 'x,
                phyAdrReady: 0,
                phyAdr: 'x,
                error: 0,
                refetch: 0
            };
            return res;
        endfunction


        static function automatic UopPacket scanQueue(input InstructionMap imap, ref Entry entries[LQ_SIZE], input InsId id, input Mword adr);
            UopPacket res = EMPTY_UOP_PACKET;
            AccessSize trSize = getTransactionSize(imap.get(id).mainUop);
            
            // CAREFUL: we search for all matching entries
            int found[$] = entries.find_index with (item.mid > id && item.adrReady && memOverlap(item.adr, (item.size), adr, (trSize)));
                Entry found_e[$] = entries.find with (item.mid > id && item.adrReady && memOverlap(item.adr, (item.size), adr, (trSize)));
            
            if (found.size() == 0) return res;
    
            foreach (found[i]) entries[found[i]].refetch = 1;
        
            begin // 'active' indicates that some match has happened without further details
                int oldestFound[$] = found.min with (entries[item].mid);
                res.TMP_oid = FIRST_U(entries[oldestFound[0]].mid);
                res.active = 1;
                    
                    // TODO: temporary DB print. Make testcases where it happens
                    if (found.size() > 1) $error("%p\n%p\n> %d", found, found_e, oldestFound);
            end
            
            return res;
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
             
    endclass


endpackage
