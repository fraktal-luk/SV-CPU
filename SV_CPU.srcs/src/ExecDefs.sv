
package ExecDefs;

    import Base::*;
    import InsDefs::*;
    import UopList::*;
    import Asm::*;
    import Emulation::*;

    import AbstractSim::*;
    import Insmap::*;

    import CoreConfig::*;
    import CacheDefs::*;

    import Arith::*;





            typedef enum {
                ES_BEGIN,

                ES_OK,

                ES_UNALIGNED,            
                ES_UNCACHED_1, ES_UNCACHED_2,
                ES_BARRIER_1,
                ES_AQ_REL_1,

                ES_SQ_MISS, ES_DATA_MISS, ES_TLB_MISS,
                ES_CANT_FORWARD,
                
                ES_INSTANT_REPLAY,
                ES_LOWER_DONE,

                ES_ILLEGAL, ES_INVALID, ES_NONEXISTENT,

                ES_REFETCH, // cause refetch

                ES_FP_INVALID, ES_FP_DIV0, ES_FP_OVERFLOW, ES_FP_UNDERFLOW, ES_FP_INEXACT,
                ES_FP_OV_INEXACT, ES_FP_UND_INEXACT
            } ExecStatus;



    function automatic logic needsReplay(input ExecStatus status);
        return status inside {ES_SQ_MISS, ES_UNCACHED_1, ES_UNCACHED_2,  ES_DATA_MISS,  ES_TLB_MISS, ES_BARRIER_1, ES_AQ_REL_1, ES_LOWER_DONE, ES_INSTANT_REPLAY};
    endfunction


            typedef enum { // (implem)
                MC_NONE,
                MC_NORMAL,
                MC_BARRIER,
                MC_UNCACHED,
                MC_AQ_REL,
                MC_SYS,

                MC_UPPER_B // block cross replay
                //MC_UPPER_P  // page cross replay
            } MemClass;



            typedef enum {
                BS_NONE,
                BS_NORMAL, // accepts renamed ops
                BS_WAIT,   // event to handle is present, don't accept new ops
                BS_HANDLING // event processing ongoing
            } BackendState;


    ////////////////////////////////////////////////////////////////////
    ///// START poison

        // Poison
        typedef UidT Poison[N_MEM_PORTS * (1 - -3 + 1)];
        localparam Poison EMPTY_POISON = '{default: UIDT_NONE};


        typedef logic IdMap[UidT];
        

        function automatic IdMap poison2map(input Poison p);
            IdMap res;
            foreach (p[i])
                if (p[i] != UIDT_NONE) res[p[i]] = 1;
            return res;
        endfunction
    
        // convert IdQueue to Poison
        function automatic Poison map2poison(input IdMap map);
            Poison res = EMPTY_POISON;
            int n = 0;
            
            map.delete(UIDT_NONE);
            
            foreach (map[id])
                res[n++] = id;
            
            return res;
        endfunction 

            
        function automatic Poison mergePoisons(input Poison ap[3]);
            IdMap m0 = poison2map(ap[0]);
            IdMap m1 = poison2map(ap[1]);
            IdMap m2 = poison2map(ap[2]);
            
            foreach (m1[uid]) m0[uid] = 1;
            foreach (m2[uid]) m0[uid] = 1;
            
            // put into 1 poison
            return map2poison(m0);
        endfunction

    ///// END poison
    



    typedef struct {
        logic active;
        UidT TMP_oid;
        MemClass memClass;
        ExecStatus status;
        Poison poison;
        Mword result;
    } UopPacket;    
    
    localparam UopPacket EMPTY_UOP_PACKET = '{0, UIDT_NONE, MC_NONE, ES_OK, EMPTY_POISON, 'x};

        typedef UopPacket UopMemPacket;
    
        function automatic UopPacket TMP_mp(input UopMemPacket p);
            return p;
        endfunction

        function automatic UopMemPacket TMP_toMemPacket(input UopPacket p);
            return p;
        endfunction


        function automatic UopPacket memToComplete(input UopPacket p);
            if (needsReplay(p.status)) return EMPTY_UOP_PACKET;
            else return p;
        endfunction

        function automatic UopPacket memToReplay(input UopPacket p);
            if (needsReplay(p.status)) return p;
            else return EMPTY_UOP_PACKET;
        endfunction





    typedef UopPacket ForwardingElement;

    localparam ForwardingElement EMPTY_FORWARDING_ELEMENT = EMPTY_UOP_PACKET;
    localparam ForwardingElement EMPTY_IMAGE[-3:1] = '{default: EMPTY_FORWARDING_ELEMENT};


        function automatic IdMap getPresentMemM(input ForwardingElement fea[N_MEM_PORTS][-3:1]);
            IdMap res;
            
            foreach (fea[p]) begin
                ForwardingElement subpipe[-3:1] = fea[p];
                foreach (subpipe[s]) begin
                    if (subpipe[s].TMP_oid != UIDT_NONE) res[subpipe[s].TMP_oid] = 1;
                end
            end
    
            return res;
        endfunction
        

        function automatic Poison updatePoison(input Poison p, input ForwardingElement fea[N_MEM_PORTS][-3:1]);
            IdMap present = getPresentMemM(fea);
            IdMap old = poison2map(p);
            
            // Remove those not present
            foreach (old[uid])
                if (!present.exists(uid)) old.delete(uid);
            
            return map2poison(old);
        endfunction
    
    
        // poison operations:
        // add producer - done when generating wakeup from mem ops
        // merge args - on issue
        // add poison - for argument on its wakeup
        
        function automatic Poison addProducer(input Poison p, input UidT uid, input ForwardingElement fea[N_MEM_PORTS][-3:1]);
            Poison u = updatePoison(p, fea);
            IdMap map = poison2map(u);
            // add id
            map[uid] = 1;
            
            return map2poison(map);
        endfunction



        function automatic logic checkMemDep(input Poison p, input ForwardingElement fe);
            if (fe.TMP_oid != UIDT_NONE) begin
                UidT inds[$] = p.find_first with (item == fe.TMP_oid);
                return inds.size() > 0;
            end
            return 0;
        endfunction


    /////////////////////////////////////////////////////////////////////////////////
    // Args, forwarding
    ////////////////////////////////////////////////////////////////////////////////


        // Handling forwarding network
        
        typedef ForwardingElement IntByStage[-3:1][N_INT_PORTS];
        typedef ForwardingElement MemByStage[-3:1][N_MEM_PORTS];
        typedef ForwardingElement VecByStage[-3:1][N_VEC_PORTS];


        typedef struct {
            IntByStage ints;
            MemByStage mems;
            VecByStage vecs;
        } ForwardsByStage_0;


        function automatic IntByStage trsInt(input ForwardingElement imgs[N_INT_PORTS][-3:1]);
            IntByStage res;
            
            foreach (imgs[p]) begin
                ForwardingElement img[-3:1] = imgs[p];
                foreach (img[s])
                    res[s][p] = img[s];
            end
            
            return res;
        endfunction

        function automatic MemByStage trsMem(input ForwardingElement imgs[N_MEM_PORTS][-3:1]);
            MemByStage res;
            
            foreach (imgs[p]) begin
                ForwardingElement img[-3:1] = imgs[p];
                foreach (img[s])
                    res[s][p] = img[s];
            end
            
            return res;
        endfunction

        function automatic VecByStage trsVec(input ForwardingElement imgs[N_VEC_PORTS][-3:1]);
            VecByStage res;
            
            foreach (imgs[p]) begin
                ForwardingElement img[-3:1] = imgs[p];
                foreach (img[s])
                    res[s][p] = img[s];
            end
            
            return res;
        endfunction


        typedef ForwardingElement FEQ[$];




        typedef enum {
            PG_NONE, PG_INT, PG_MEM, PG_VEC
        } PipeGroup;


        typedef struct {
            logic active;
            UidT producer;
            PipeGroup group;
            int port;
            int stage;
            Poison poison;
        } Wakeup;
        
        localparam Wakeup EMPTY_WAKEUP = '{0, UIDT_NONE, PG_NONE, -1, 2, EMPTY_POISON};




    function automatic logic3 checkArgsReady(input InsDependencies deps, input logic intReadyV[N_REGS_INT], input logic floatReadyV[N_REGS_FLOAT]);
        logic3 res = '{0, 0, 0};
        foreach (deps.types[i])
            case (deps.types[i])
                SRC_ZERO:  res[i] = 1;
                SRC_CONST: res[i] = 1;
                SRC_INT:   res[i] = intReadyV[deps.sources[i]];
                SRC_FLOAT: res[i] = floatReadyV[deps.sources[i]];
            endcase
        return res;
    endfunction



    function automatic logic matchProducer(input ForwardingElement fe, input UidT producer);
        return (fe.TMP_oid != UIDT_NONE) && fe.TMP_oid === producer;
    endfunction




    // IQs
    function automatic Wakeup checkForwardSourceInt(input UidT producer, input ForwardingElement fea[N_INT_PORTS][-3:1]);
        Wakeup res = EMPTY_WAKEUP;
        if (producer == UIDT_NONE) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.TMP_oid == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe %d (%d):\n%p", p, found, fea[p]);
            
            if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

            res.active = 1;
            res.producer = producer;
            res.group = PG_INT;
            res.port = p;
            res.stage = found[0];
            res.poison = fea[p][found[0]].poison;
            return res;
        end
        return res;
    endfunction;

    function automatic Wakeup checkForwardSourceVec(input UidT producer, input ForwardingElement fea[N_VEC_PORTS][-3:1]);
        Wakeup res = EMPTY_WAKEUP;
        if (producer == UIDT_NONE) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.TMP_oid == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe");
            
            if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

            res.active = 1;
            res.producer = producer;
            res.group = PG_VEC;
            res.port = p;
            res.stage = found[0];
            res.poison = fea[p][found[0]].poison;
            return res;
        end
        return res;
    endfunction;


    function automatic Wakeup checkForwardSourceMem(input UidT producer, input ForwardingElement fea[N_MEM_PORTS][-3:1]);
        Wakeup res = EMPTY_WAKEUP;
        if (producer == UIDT_NONE) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.TMP_oid == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe");
            
            if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

            res.active = 1;

            // Don't wake up if this is a failed op
            if (fea[p][found[0]].status != ES_OK && found[0] >= 0) res.active = 0;
            
            res.producer = producer;
            res.group = PG_MEM;
            res.port = p;
            res.stage = found[0];
            res.poison = addProducer(fea[p][found[0]].poison, producer, fea);
            return res;
        end
        return res;
    endfunction;



    /////////////////////////////////////////////////////////////////////////////////////////////////
    // Exec calculations
    ////////////////////////////////////////////////////////////////////////////////////////////////


    function automatic Mword calcEffectiveAddress(Mword3 args);
        return args[0] + args[1];
    endfunction


    function automatic logic resolveBranchDirection(input UopName uname, input Mword condArg);        
        assert (!$isunknown(condArg)) else $fatal(2, "Branch condition not well formed\n%p, %p", uname, condArg);
        
        case (uname)
            UOP_bc_z, UOP_br_z:  return condArg === 0;
            UOP_bc_nz, UOP_br_nz: return condArg !== 0;
            UOP_bc_a, UOP_bc_l: return 1;  
            default: $fatal(2, "Wrong branch uop");
        endcase            
    endfunction

endpackage
