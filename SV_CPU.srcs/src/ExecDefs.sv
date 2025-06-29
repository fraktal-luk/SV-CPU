
package ExecDefs;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    
    import AbstractSim::*;
    import Insmap::*;

    import CacheDefs::*;
    

    // General uarch defs
    localparam int N_INT_PORTS = 4;
    localparam int N_MEM_PORTS = 4;
    localparam int N_VEC_PORTS = 4;



    typedef enum {
        ES_OK,
        ES_UNALIGNED,
            ES_UNCACHED_1,
            ES_UNCACHED_2,
        ES_SQ_MISS,
            ES_DATA_MISS,
            ES_TLB_MISS,
        ES_REFETCH, // cause refetch
        ES_CANT_FORWARD,
        ES_ILLEGAL
    } ExecStatus;

    function automatic logic needsReplay(input ExecStatus status);
        return status inside {ES_SQ_MISS,   ES_UNCACHED_1, ES_UNCACHED_2,  ES_DATA_MISS,  ES_TLB_MISS};
    endfunction



    // Poison
    typedef UidT Poison[N_MEM_PORTS * (1 - -3 + 1)];
    localparam Poison EMPTY_POISON = '{default: UIDT_NONE};


    // For routing to IQs
    typedef struct {
        logic active;
        UopId uid;
    } TMP_Uop;

    localparam TMP_Uop TMP_UOP_NONE = '{0, UID_NONE};



    typedef struct {
        logic active;
        UidT TMP_oid;
        ExecStatus status;
        Poison poison;
        Mword result;
    } UopPacket;    
    
    localparam UopPacket EMPTY_UOP_PACKET = '{0, UIDT_NONE, ES_OK, EMPTY_POISON, 'x};


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


    typedef struct {
        TMP_Uop regular[RENAME_WIDTH];
        TMP_Uop branch[RENAME_WIDTH];
        TMP_Uop float[RENAME_WIDTH];
        TMP_Uop mem[RENAME_WIDTH];
        TMP_Uop storeData[RENAME_WIDTH];
    } RoutedUops;

    localparam RoutedUops DEFAULT_ROUTED_UOPS = '{
        regular: '{default: TMP_UOP_NONE},
        branch: '{default: TMP_UOP_NONE},
        float: '{default: TMP_UOP_NONE},
        mem: '{default: TMP_UOP_NONE},
        storeData: '{default: TMP_UOP_NONE}
    };


    typedef UopPacket ForwardingElement;

    localparam ForwardingElement EMPTY_FORWARDING_ELEMENT = EMPTY_UOP_PACKET;
    localparam ForwardingElement EMPTY_IMAGE[-3:1] = '{default: EMPTY_FORWARDING_ELEMENT};

    
    
    ///// START poison
           
        typedef logic IdMap[UidT];
        
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

    
    
    
    // IQ structures

    typedef struct {
        logic ready;
        logic readyArgs[3];
        logic cancelledArgs[3];
    } IqArgState;
    
    localparam IqArgState EMPTY_ARG_STATE = '{ready: 'z, readyArgs: '{'z, 'z, 'z}, cancelledArgs: '{'z, 'z, 'z}};
    localparam IqArgState ZERO_ARG_STATE  = '{ready: '0, readyArgs: '{'0, '0, '0}, cancelledArgs: '{0, 0, 0}};

    
    // Poison
    typedef struct {
        Poison poisoned[3];
    } IqPoisonState;
    
    localparam IqPoisonState DEFAULT_POISON_STATE = '{poisoned: '{default: EMPTY_POISON}};


    typedef struct {
        logic used;
        logic active;
        IqArgState state;
        IqPoisonState poisons;
            int issueCounter;
        UidT uid;
    } IqEntry;

    localparam IqEntry EMPTY_ENTRY = '{used: 0, active: 0, state: EMPTY_ARG_STATE, poisons: DEFAULT_POISON_STATE, issueCounter: -1, uid: UIDT_NONE};

    
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


    //////////////////////////////////////////
    // IQ and Exec0
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

    function automatic FEQ findForwardInt(input UidT producer, input ForwardingElement feInt[N_INT_PORTS], input ForwardingElement feMem[N_MEM_PORTS]);
        FEQ res = feInt.find with (matchProducer(item, producer));
        if (res.size() == 0)
            res = feMem.find with (matchProducer(item, producer));
        return res;
    endfunction

    function automatic FEQ findForwardVec(input UidT producer, input ForwardingElement feVec[N_INT_PORTS], input ForwardingElement feMem[N_MEM_PORTS]);
        FEQ res = feVec.find with (matchProducer(item, producer));
        return res;
    endfunction

    function automatic void verifyForward(input InstructionInfo ii, input UopInfo ui, input int source, input Mword result);
        assert (ui.physDest === source) else $fatal(2, "Not correct match, should be %p:", ii.id);
        assert (ui.resultA === result) else $fatal(2, "Value differs! %d // %d;\n %p\n%s", ui.resultA, result, ii, disasm(ii.basicData.bits));
    endfunction


    function automatic Mword getArgValueInt(input InstructionMap imap, input RegisterTracker tracker,
                                            input UidT producer, input int source, input ForwardsByStage_0 fws, input logic ready);
        FEQ found1, found0;

        if (ready) return tracker.ints.regs[source];
        
        found1 = findForwardInt(producer, fws.ints[1], fws.mems[1]);
        if (found1.size() != 0) begin
            InstructionInfo ii = imap.get(U2M(producer));
            UopInfo ui = imap.getU(producer);
            verifyForward(ii, ui, source, found1[0].result);
            return found1[0].result;
        end
        
        found0 = findForwardInt(producer, fws.ints[0], fws.mems[0]);
        if (found0.size() != 0) begin
            InstructionInfo ii = imap.get(U2M(producer));
            UopInfo ui = imap.getU(producer);
            verifyForward(ii, ui, source, found0[0].result);
            return found0[0].result;
        end

        $fatal(2, "oh no\n%p, %d", producer, source);
    endfunction


    function automatic Mword getArgValueVec(input InstructionMap imap, input RegisterTracker tracker,
                                           input UidT producer, input int source, input ForwardsByStage_0 fws, input logic ready);
        FEQ found1, found0;
                       
        if (ready) return tracker.floats.regs[source];

        found1 = findForwardVec(producer, fws.vecs[1], fws.mems[1]);
        if (found1.size() != 0) begin
            InstructionInfo ii = imap.get(U2M(producer));
            UopInfo ui = imap.getU(producer);
            verifyForward(ii, ui, source, found1[0].result);
            return found1[0].result;
        end
        
        found0 = findForwardVec(producer, fws.vecs[0], fws.mems[0]);
        if (found0.size() != 0) begin
            InstructionInfo ii = imap.get(U2M(producer));
            UopInfo ui = imap.getU(producer);
            verifyForward(ii, ui, source, found0[0].result);
            return found0[0].result;
        end

        $fatal(2, "oh no");
    endfunction



    // IQ logic

    typedef logic ReadyQueue[$];
    typedef logic ReadyQueue3[$][3];
    

    function automatic ReadyQueue3 unifyReadyAndForwardsQ(input ReadyQueue3 ready, input ReadyQueue3 forwarded);
        ReadyQueue3 res;
        
        foreach (ready[i]) begin
            logic slot[3] = ready[i];
            res.push_back(slot);
            foreach (slot[a]) begin
                if ($isunknown(ready[i][a])) res[i][a] = 'z;
                else begin
                    res[i][a] = ready[i][a] | forwarded[i][a];
                end
            end
        end
        
        return res;    
    endfunction

    function automatic ReadyQueue makeReadyQueue(input ReadyQueue3 argV);
        ReadyQueue res;
        foreach (argV[i]) 
            res.push_back( $isunknown(argV[i]) ? 'z : argV[i].and() );
        return res;
    endfunction

    // IQs
    function automatic Wakeup checkForwardSourceInt(input InstructionMap imap, input UidT producer, input int source, input ForwardingElement fea[N_INT_PORTS][-3:1]);
        Wakeup res = EMPTY_WAKEUP;
        if (producer == UIDT_NONE) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.TMP_oid == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe");
            else if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

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

    function automatic Wakeup checkForwardSourceMem(input InstructionMap imap, input UidT producer, input int source, input ForwardingElement fea[N_MEM_PORTS][-3:1]);
        Wakeup res = EMPTY_WAKEUP;
        if (producer == UIDT_NONE) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.TMP_oid == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe");
            else if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

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

    function automatic Wakeup checkForwardSourceVec(input InstructionMap imap, input UidT producer, input int source, input ForwardingElement fea[N_VEC_PORTS][-3:1]);
        Wakeup res = EMPTY_WAKEUP;
        if (producer == UIDT_NONE) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.TMP_oid == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe");
            else if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

            res.active = 1;
            res.producer = producer;
            res.group = PG_VEC;
            res.port = p;
            res.stage = found[0];
                res.poison = EMPTY_POISON; //TMP!
            return res;
        end
        return res;
    endfunction;


    function automatic logic checkMemDep(input Poison p, input ForwardingElement fe);
        if (fe.TMP_oid != UIDT_NONE) begin
            UidT inds[$] = p.find with (item == fe.TMP_oid);
            return inds.size() != 0;
        end
        return 0;
    endfunction


    function automatic Mword calcEffectiveAddress(Mword3 args);
        return args[0] + args[1];
    endfunction



endpackage
