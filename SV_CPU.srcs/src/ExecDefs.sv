
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

    typedef logic ReadyVec[ISSUE_QUEUE_SIZE];
    typedef logic ReadyVec3[ISSUE_QUEUE_SIZE][3];

    typedef logic ReadyQueue[$];
    typedef logic ReadyQueue3[$][3];


    typedef struct {
        InsId id;
    } ForwardingElement;

    localparam ForwardingElement EMPTY_FORWARDING_ELEMENT = '{id: -1}; 


    // NOT USED so far
    typedef struct {
        ForwardingElement pipesInt[N_INT_PORTS];
        
        ForwardingElement subpipe0[-3:1];
        
        InsId regular1;
        InsId branch0;
        InsId mem0;
        
        InsId float0;
        InsId float1;
    } Forwarding_0;

    localparam ForwardingElement EMPTY_IMAGE[-3:1] = '{default: EMPTY_FORWARDING_ELEMENT};
    
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



        function automatic logic matchProducer(input ForwardingElement fe, input InsId producer);
            return !(fe.id == -1) && fe.id === producer;
        endfunction
    
        function automatic Word useForwardedValue(input InstructionMap imap, input ForwardingElement fe, input int source, input InsId producer);
            InstructionInfo ii = imap.get(fe.id);
            assert (ii.physDest === source) else $fatal(2, "Not correct match, should be %p:", producer);
            return ii.actualResult;
        endfunction
    
        function automatic logic useForwardingMatch(input InstructionMap imap, input ForwardingElement fe, input int source, input InsId producer);
            InstructionInfo ii = imap.get(fe.id);
            assert (ii.physDest === source) else $fatal(2, "Not correct match, should be %p:", producer);
            return 1;
        endfunction
    
    
        function automatic Word getForwardValueVec(input InstructionMap imap, input InsId producer, input int source, input ForwardingElement feVec[N_VEC_PORTS]);
            foreach (feVec[p]) begin
                if (matchProducer(feVec[p], producer)) return useForwardedValue(imap, feVec[p], source, producer);
            end
            return 'x;
        endfunction;
    
        function automatic Word getForwardValueInt(input InstructionMap imap, input InsId producer, input int source, input ForwardingElement feInt[N_INT_PORTS], input ForwardingElement feMem[N_MEM_PORTS]);
            foreach (feInt[p]) begin
                if (matchProducer(feInt[p], producer)) return useForwardedValue(imap, feInt[p], source, producer);
            end
            
            foreach (feMem[p]) begin
                if (matchProducer(feMem[p], producer)) return useForwardedValue(imap, feMem[p], source, producer);
            end
    
            return 'x;
        endfunction;
    
    
        function automatic logic checkForwardVec(input InstructionMap imap, input InsId producer, input int source, input ForwardingElement feVec[N_VEC_PORTS]);
            foreach (feVec[p]) begin
                if (matchProducer(feVec[p], producer)) return useForwardingMatch(imap, feVec[p], source, producer);
            end
            return 0;
        endfunction;
    
        function automatic logic checkForwardInt(input InstructionMap imap, input InsId producer, input int source, input ForwardingElement feInt[N_INT_PORTS], input ForwardingElement feMem[N_MEM_PORTS]);
            foreach (feInt[p]) begin
                if (matchProducer(feInt[p], producer)) return useForwardingMatch(imap, feInt[p], source, producer);
            end
            
            foreach (feMem[p]) begin
                if (matchProducer(feMem[p], producer)) return useForwardingMatch(imap, feMem[p], source, producer);
            end
    
            return 0;
        endfunction;



        


    // Exec/(Issue) - arg handling
    function automatic logic3 checkArgsReady(input InsDependencies deps, input logic intReadyV[N_REGS_INT], input logic floatReadyV[N_REGS_FLOAT]);
        logic3 res;
        
        foreach (deps.types[i])
            case (deps.types[i])
                SRC_ZERO:  res[i] = 1;
                SRC_CONST: res[i] = 1;
                SRC_INT:   res[i] = intReadyV[deps.sources[i]];
                SRC_FLOAT: res[i] = floatReadyV[deps.sources[i]];
            endcase      
        return res;
    endfunction

    function automatic logic3 checkForwardsReady(input InstructionMap imap,
                                                 input ForwardsByStage_0 fws,
                                                 input InsDependencies deps,                                                 
                                                 input int stage);
        logic3 res;
        foreach (deps.types[i])
            case (deps.types[i])
                SRC_ZERO:  res[i] = 0;
                SRC_CONST: res[i] = 0;
                SRC_INT:   res[i] = checkForwardInt(imap, deps.producers[i], deps.sources[i], fws.ints[stage], fws.mems[stage]);
                SRC_FLOAT: res[i] = checkForwardVec(imap, deps.producers[i], deps.sources[i], fws.vecs[stage]);
            endcase      
        return res;
    endfunction

    function automatic Word3 getForwardedValues(input InstructionMap imap,
                                                input ForwardsByStage_0 fws,
                                                input InsDependencies deps,                                                 
                                                input int stage);
        Word3 res;
        foreach (deps.types[i])
            case (deps.types[i])
                SRC_ZERO:  res[i] = 0;
                SRC_CONST: res[i] = 0;
                SRC_INT:   res[i] = getForwardValueInt(imap, deps.producers[i], deps.sources[i], fws.ints[stage], fws.mems[stage]);
                SRC_FLOAT: res[i] = getForwardValueVec(imap, deps.producers[i], deps.sources[i], fws.vecs[stage]);
            endcase      
        return res;
    endfunction


    function automatic logic3 checkForwardsReadyAll(input InstructionMap imap,
                                                 input ForwardsByStage_0 fws,
                                                 input InsDependencies deps,                                                 
                                                 input int stages[]);
        logic3 res = '{0, 0, 0};
        foreach (deps.types[i])
            foreach (stages[s])
                case (deps.types[i])
                    SRC_ZERO:  res[i] |= 0;
                    SRC_CONST: res[i] |= 0;
                    SRC_INT:   res[i] |= checkForwardInt(imap, deps.producers[i], deps.sources[i], fws.ints[stages[s]], fws.mems[stages[s]]);
                    SRC_FLOAT: res[i] |= checkForwardVec(imap, deps.producers[i], deps.sources[i], fws.vecs[stages[s]]);
                endcase      
        return res;
    endfunction


//////////////////////////////////
    localparam logic dummy3[3] = '{'z, 'z, 'z};

    localparam ReadyVec3 FORWARDING_VEC_ALL_Z = '{default: dummy3};
    localparam ReadyVec3 FORWARDING_ALL_Z[-3:1] = '{default: FORWARDING_VEC_ALL_Z};



    function automatic ReadyVec3 gatherReadyOrForwards(input ReadyVec3 ready, input ReadyVec3 forwards[-3:1]);
        ReadyVec3 res = '{default: dummy3};
        
        foreach (res[i]) begin
            logic slot[3] = res[i];
            foreach (slot[a]) begin
                if ($isunknown(ready[i][a])) res[i][a] = 'z;
                else begin
                    res[i][a] = ready[i][a];
                    for (int s = -3 + 1; s <= 1; s++) res[i][a] |= forwards[s][i][a]; // CAREFUL: not using -3 here
                end
            end
        end
        
        return res;    
    endfunction


    function automatic ReadyVec makeReadyVec(input ReadyVec3 argV);
        ReadyVec res = '{default: 'z};
        foreach (res[i]) 
            res[i] = $isunknown(argV[i]) ? 'z : argV[i].and();
        return res;
    endfunction

    function automatic ReadyQueue3 gatherReadyOrForwardsQ(input ReadyQueue3 ready, input ReadyQueue3 forwards[-3:1]);
        ReadyQueue3 res;
        
        foreach (ready[i]) begin
            logic slot[3] = ready[i];
            res.push_back(slot);
            foreach (slot[a]) begin
                if ($isunknown(ready[i][a])) res[i][a] = 'z;
                else begin
                    res[i][a] = ready[i][a];
                    for (int s = -3 + 1; s <= 1; s++) res[i][a] |= forwards[s][i][a]; // CAREFUL: not using -3 here
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


    typedef struct {
        InsId id;
        
        logic ready;
        logic readyArgs[3];
        logic readyF;
        logic readyArgsF[3];
        
    } IqArgState;
    
    localparam IqArgState EMPTY_ARG_STATE = '{id: -1, ready: 'z, readyArgs: '{'z, 'z, 'z}, readyF: 'z, readyArgsF: '{'z, 'z, 'z}};
    localparam IqArgState ZERO_ARG_STATE  = '{id: -1, ready: '0, readyArgs: '{'0, '0, '0}, readyF: '0, readyArgsF: '{'0, '0, '0}};

    
    typedef InsId Poison[4];
    localparam Poison DEFAULT_POISON = '{default: -1};
    
    typedef struct {
        Poison poisoned[3];
    } IqPoisonState;
    
    localparam IqPoisonState DEFAULT_POISON_STATE = '{poisoned: '{default: DEFAULT_POISON}};
    

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
    
    typedef struct {
        logic active;
    
        InsId id;
        
        Poison poison;
    } OpPacket;
    
    localparam OpPacket EMPTY_OP_PACKET = '{0, -1, DEFAULT_POISON};


        function automatic Wakeup checkForwardSourceInt(input InstructionMap imap, input InsId producer, input int source, input ForwardingElement fea[N_INT_PORTS][-3:1]);
            Wakeup res = EMPTY_WAKEUP;
            if (producer == -1) return res;
            foreach (fea[p]) begin
                int found[$] = fea[p].find_index with (item.id == producer);
                if (found.size() == 0) continue;
                else if (found.size() > 1) $error("Repeated op id in same subpipe");
                res.active = 1;
                res.producer = producer;
                res.group = PG_INT;
                res.port = p;
                res.stage = found[0];
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
                res.active = 1;
                res.producer = producer;
                res.group = PG_MEM;
                res.port = p;
                res.stage = found[0];
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
