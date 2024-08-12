
package ExecDefs;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    
    import AbstractSim::*;
    import Insmap::*;


    localparam int N_INT_PORTS = 4;
    localparam int N_MEM_PORTS = 4;
    localparam int N_VEC_PORTS = 4;

    typedef logic ReadyQueue[$];
    typedef logic ReadyQueue3[$][3];


    typedef InsId Poison[4];
    localparam Poison DEFAULT_POISON = '{default: -1};
    

    typedef struct {
        logic active;
        InsId id;
        Poison poison;
        Word result;
    } OpPacket;
    
    localparam OpPacket EMPTY_OP_PACKET = '{0, -1, DEFAULT_POISON, 'x};

    function automatic OpPacket setResult(input OpPacket p, input Word result);
        OpPacket res = p;            
        res.result = result;
        
        return res;
    endfunction


    typedef OpPacket ForwardingElement;

    localparam ForwardingElement EMPTY_FORWARDING_ELEMENT = EMPTY_OP_PACKET;
    localparam ForwardingElement EMPTY_IMAGE[-3:1] = '{default: EMPTY_FORWARDING_ELEMENT};
    
    typedef ForwardingElement IntByStage[-3:1][N_INT_PORTS];
    typedef ForwardingElement MemByStage[-3:1][N_MEM_PORTS];
    typedef ForwardingElement VecByStage[-3:1][N_VEC_PORTS];


    typedef struct {
        IntByStage ints;
        MemByStage mems;
        VecByStage vecs;
    } ForwardsByStage_0;



    typedef struct {
        InsId id;
        logic ready;
        logic readyArgs[3];
    } IqArgState;
    
    localparam IqArgState EMPTY_ARG_STATE = '{id: -1, ready: 'z, readyArgs: '{'z, 'z, 'z}};
    localparam IqArgState ZERO_ARG_STATE  = '{id: -1, ready: '0, readyArgs: '{'0, '0, '0}};


    typedef struct {
        Poison poisoned[3];
    } IqPoisonState;
    
    localparam IqPoisonState DEFAULT_POISON_STATE = '{poisoned: '{default: DEFAULT_POISON}};
    

    function automatic Poison poisonAppend(input Poison p, input InsId id);
        Poison res = p;
        int found[$] = p.find_first_index with (item == -1); 
        res[found[0]] = id;
        return res;
    endfunction;

    
    function automatic Poison mergePoisons(input IqPoisonState ps);
        Poison res = DEFAULT_POISON;
        int n = 0;
        
        foreach (ps.poisoned[a]) begin
            Poison pa = ps.poisoned[a];
            foreach (pa[i]) begin
                if (pa[i] == -1) continue;
                res[n++] = pa[i];
            end
        end
        
        return res;
    endfunction
    

    typedef struct {
        logic used;
        logic active;
        IqArgState state;
        IqPoisonState poisons;
            int issueCounter;
        InsId id;
    } IqEntry;

    localparam IqEntry EMPTY_ENTRY = '{used: 0, active: 0, state: EMPTY_ARG_STATE, poisons: DEFAULT_POISON_STATE, issueCounter: -1, id: -1};

    
    typedef enum {
        PG_NONE, PG_INT, PG_MEM, PG_VEC
    } PipeGroup;
    
    
    typedef struct {
        logic active;
        InsId producer;
        PipeGroup group;
        int port;
        int stage;
        Poison poison;
    } Wakeup;
    
    localparam Wakeup EMPTY_WAKEUP = '{0, -1, PG_NONE, -1, 2, DEFAULT_POISON};




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

    //////////////////////////////////
    // Arg handling - beginning of Exec0

    typedef ForwardingElement FEQ[$];


    function automatic logic matchProducer(input ForwardingElement fe, input InsId producer);
        return !(fe.id == -1) && fe.id === producer;
    endfunction

    function automatic FEQ findForwardInt(input InsId producer, input ForwardingElement feInt[N_INT_PORTS], input ForwardingElement feMem[N_MEM_PORTS]);
        FEQ res = feInt.find with (matchProducer(item, producer));
        if (res.size() == 0)
            res = feMem.find with (matchProducer(item, producer));

        return res;
    endfunction

    function automatic FEQ findForwardVec(input InsId producer, input ForwardingElement feVec[N_INT_PORTS], input ForwardingElement feMem[N_MEM_PORTS]);
        FEQ res = feVec.find with (matchProducer(item, producer));
        return res;
    endfunction

    function automatic void verifyForward(input InstructionInfo ii, input int source, input Word result);
        assert (ii.physDest === source) else $fatal(2, "Not correct match, should be %p:", ii.id);
        assert (ii.actualResult === result) else $fatal("Value differs! %d // %d", ii.actualResult, result);
    endfunction
    


    function automatic Word getArgValueInt(input InstructionMap imap, input RegisterTracker tracker,
                                           input InsId producer, input int source, input ForwardsByStage_0 fws, input logic ready);
        FEQ found1, found0;

        if (ready) return tracker.ints.regs[source];
        
        found1 = findForwardInt(producer, fws.ints[1], fws.mems[1]);
        if (found1.size() != 0) begin
            InstructionInfo ii = imap.get(producer);
            verifyForward(ii, source, found1[0].result);
        
            return ii.actualResult;
        end
        
        found0 = findForwardInt(producer, fws.ints[0], fws.mems[0]);
        if (found0.size() != 0) begin
            InstructionInfo ii = imap.get(producer);
            verifyForward(ii, source, found0[0].result);
        
            return ii.actualResult;
        end

        $fatal(2, "oh no");
    endfunction


    function automatic Word getArgValueVec(input InstructionMap imap, input RegisterTracker tracker,
                                           input InsId producer, input int source, input ForwardsByStage_0 fws, input logic ready);
        FEQ found1, found0;
                       
        if (ready) return tracker.floats.regs[source];

        found1 = findForwardVec(producer, fws.vecs[1], fws.mems[1]);
        if (found1.size() != 0) begin
            InstructionInfo ii = imap.get(producer);
            verifyForward(ii, source, found1[0].result);
        
            return ii.actualResult;
        end
        
        found0 = findForwardVec(producer, fws.vecs[0], fws.mems[0]);
        if (found0.size() != 0) begin
            InstructionInfo ii = imap.get(producer);
            verifyForward(ii, source, found0[0].result);
        
            return ii.actualResult;
        end

        $fatal(2, "oh no");
    endfunction



    // IQ logic

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

    ////////////////////////////////////////////////////


    // IQs
    function automatic Wakeup checkForwardSourceInt(input InstructionMap imap, input InsId producer, input int source, input ForwardingElement fea[N_INT_PORTS][-3:1]);
        Wakeup res = EMPTY_WAKEUP;
        if (producer == -1) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.id == producer);
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

    function automatic Wakeup checkForwardSourceMem(input InstructionMap imap, input InsId producer, input int source, input ForwardingElement fea[N_MEM_PORTS][-3:1]);
        Wakeup res = EMPTY_WAKEUP;
        if (producer == -1) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.id == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe");
            else if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

            res.active = 1;
            res.producer = producer;
            res.group = PG_MEM;
            res.port = p;
            res.stage = found[0];
                res.poison = poisonAppend(fea[p][found[0]].poison, producer);
            return res;
        end
        return res;
    endfunction;

    function automatic Wakeup checkForwardSourceVec(input InstructionMap imap, input InsId producer, input int source, input ForwardingElement fea[N_VEC_PORTS][-3:1]);
        Wakeup res = EMPTY_WAKEUP;
        if (producer == -1) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.id == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe");
            else if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

            res.active = 1;
            res.producer = producer;
            res.group = PG_VEC;
            res.port = p;
            res.stage = found[0];
            
            return res;
        end
        return res;
    endfunction;

endpackage
