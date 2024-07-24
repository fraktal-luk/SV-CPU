
package Insmap;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    import AbstractSim::*;
    

    class InstructionMap;
        
        typedef enum {
            ___,
        
            GenAddress,
            
            FlushFront,
            
            PutFQ,
            
            Rename,
            
            RobEnter, RobFlush, RobExit,
        
            BqEnter, BqFlush, BqExit,
            
            SqEnter, SqFlush, SqExit,            
            LqEnter, LqFlush, LqExit,
            
            MemFwProduce, MemFwConsume,
            
            
            WqEnter, WqExit, // committed write queue
            
            FlushOOO,
            
            FlushExec,
            // TODO: flush in every region? (ROB, subpipes, queues etc.)
            
            IqEnter,
            IqWakeup0,
            IqWakeup1,
            IqWakeupComplete,
            IqCancelWakeup0,
            IqCancelWakeup1,
            IqIssue,
            IqPullback,
            IqFlush,
            IqExit,
    
              ReadArg, // TODO: by source type
    
              ExecRedirect,            
    
            ReadMem,
            ReadSysReg,
            ReadSQ,
            
            WriteMemAddress,
            WriteMemValue,
            
            // TODO: MQ related: Miss (by type? or types handled separately by mem tracking?), writ to MQ, activate, issue
            
            
            WriteResult,
            Complete,
            
            Retire,
            
            Drain
        } Milestone;
    
    
        typedef struct {
            Milestone kind;
            int cycle;
        } MilestoneTag;
    
        class InsRecord;
            MilestoneTag tags[$];
        endclass
    
        InsId indexList[$];
    
        InstructionInfo content[InsId];
        InsRecord records[int];
    
    
        InsId retiredArr[$];
        InsId retiredArrPre[$];
    
        InsId killedArr[$];
        InsId killedArrPre[$];
    
    
        string retiredArrStr;
        string killedArrStr;
    
        InsId lastRetired = -1;
        InsId lastRetiredPre = -1;
        InsId lastRetiredPrePre = -1;
    
        InsId lastKilled = -1;
        InsId lastKilledPre = -1;
        InsId lastKilledPrePre = -1;
    
        string lastRetiredStr;
        string lastRetiredStrPre;
        string lastRetiredStrPrePre;
    
        string lastKilledStr;
        string lastKilledStrPre;
        string lastKilledStrPrePre;
    
    
        localparam int RECORD_ARRAY_SIZE = 24;
    
        MilestoneTag lastRecordArr[RECORD_ARRAY_SIZE];
        MilestoneTag lastRecordArrPre[RECORD_ARRAY_SIZE];
        MilestoneTag lastRecordArrPrePre[RECORD_ARRAY_SIZE];
    
        MilestoneTag lastKilledRecordArr[RECORD_ARRAY_SIZE];
        MilestoneTag lastKilledRecordArrPre[RECORD_ARRAY_SIZE];
        MilestoneTag lastKilledRecordArrPrePre[RECORD_ARRAY_SIZE];
    
    
        function automatic void endCycle();
            retiredArrPre = retiredArr;
            killedArrPre = killedArr;
        
            foreach (retiredArr[i]) checkOk(retiredArr[i]);
            foreach (killedArr[i]) checkOk(killedArr[i]);
    
            retiredArr.delete();
            killedArr.delete();
            
            retiredArrStr = "";
            killedArrStr = "";
            
        
            lastRetiredPrePre = lastRetiredPre;
            lastRetiredPre = lastRetired;
    
            lastKilledPrePre = lastKilledPre;
            lastKilledPre = lastKilled;
    
    
            setRecordArr(lastRecordArr, lastRetired);
            setRecordArr(lastRecordArrPre, lastRetiredPre);
            setRecordArr(lastRecordArrPrePre, lastRetiredPrePre);
      
            setRecordArr(lastKilledRecordArr, lastKilled);
            setRecordArr(lastKilledRecordArrPre, lastKilledPre);
            setRecordArr(lastKilledRecordArrPrePre, lastKilledPrePre);
    
        endfunction
        
        
        function automatic InstructionInfo get(input InsId id);
            assert (content.exists(id)) else $fatal(2, "wrong id %d", id);
            return content[id];
        endfunction
    
        function automatic int size();
            return content.size();
        endfunction
        
    
        function automatic void add(input OpSlot op);
            assert (op.active) else $error("Inactive op added to base");
            content[op.id] = initInsInfo(op);
        endfunction
    
        // CAREFUL: temporarily here: decode and store to avoid repeated decoding later 
        function automatic void setEncoding(input OpSlot op);
            assert (op.active) else $error("encoding set for inactive op");
            content[op.id].bits = op.bits;
            content[op.id].dec = decodeAbstract(op.bits);
        endfunction
    
        function automatic void setTarget(input InsId id, input Word trg);
            content[id].target = trg;
        endfunction
    
        function automatic void setResult(input InsId id, input Word res);
            content[id].result = res;
        endfunction
    
        function automatic void setActualResult(input InsId id, input Word res);
            content[id].actualResult = res;
        endfunction
    
        function automatic void setDeps(input InsId id, input InsDependencies deps);
            content[id].deps = deps;
        endfunction
        
        function automatic void setInds(input InsId id, input IndexSet indexSet);
            content[id].inds = indexSet;
        endfunction
    
        function automatic void setSlot(input InsId id, input int slot);
            content[id].slot = slot;
        endfunction
    
        function automatic void setPhysDest(input InsId id, input int dest);
            content[id].physDest = dest;
        endfunction
      
        function automatic void setArgValues(input InsId id, input Word vals[3]);
            content[id].argValues = vals;
        endfunction
    
        function automatic void setArgError(input InsId id);
            content[id].argError = 1;
        endfunction
    
       
        function automatic void setRetired(input InsId id);
            assert (id != -1) else $fatal(2, "retired -1");
    
            retiredArr.push_back(id);
            $swrite(retiredArrStr, "%p", retiredArr);
            
            lastRetired = id;
            lastRetiredStr = disasm(get(id).bits);
        endfunction
        
        function automatic void setKilled(input InsId id, input logic front = 0);
            assert (id != -1) else $fatal(2, "killed -1");
        
                if (front) return;
        
            killedArr.push_back(id);
            $swrite(killedArrStr, "%p", killedArr);
    
            if (id <= lastKilled) return;
            lastKilled = id;
            if (content.exists(id))
                lastKilledStr = disasm(get(id).bits);
            else begin
                lastKilledStr = "???";
                $fatal(2, "Killed not added: %d", id);
            end
        endfunction
    
    
        function automatic void setRecordArr(ref MilestoneTag arr[RECORD_ARRAY_SIZE], input InsId id);
            MilestoneTag def = '{___, -1};
            InsRecord empty = new();
            InsRecord rec = id == -1 ? empty : records[id];
            arr = '{default: def};
            
            foreach(rec.tags[i]) arr[i] = rec.tags[i];
        endfunction
    
         
        function automatic void registerIndex(input InsId id);
            indexList.push_back(id);
            records[id] = new();
        endfunction
    
    
        function automatic void cleanDescs();       
            while (indexList[0] < lastRetired - 10) begin
                content.delete(indexList[0]);
                records.delete(indexList[0]);
                void'(indexList.pop_front());
            end
        endfunction
        
        function automatic void putMilestone(input InsId id, input Milestone kind, input int cycle);
            if (id == -1) return;
            records[id].tags.push_back('{kind, cycle});
        endfunction
    
        // 3 main categories:
        // a. Killed in Front
        // b. Killed in OOO
        // c. Retired
        typedef enum { EC_KilledFront, EC_KilledOOO, EC_Retired } ExecClass;
    
        function automatic ExecClass determineClass(input MilestoneTag tags[$]);
            MilestoneTag retirement[$] = tags.find with (item.kind == Retire);
            MilestoneTag frontKill[$] = tags.find with (item.kind == FlushFront);
            
            assert (tags[0].kind == GenAddress) else $fatal(2, "Op not starting with GenAdress");
            
            if (frontKill.size() > 0) return EC_KilledFront;
            if (retirement.size() > 0) return EC_Retired;
            return EC_KilledOOO;            
        endfunction
    
        function automatic logic checkKilledFront(input InsId id, input MilestoneTag tags[$]);
            MilestoneTag tag = tags.pop_front();
            assert (tag.kind == GenAddress) else $error("ddkld");
            tag = tags.pop_front();
            assert (tag.kind == FlushFront) else $error(" ttt:   %p", tag);
            
            assert (tags.size() == 0) else $error("   why not empty: %p", tags);
            
            return 1;
        endfunction
    
        function automatic logic checkKilledOOO(input InsId id, input MilestoneTag tags[$]);
            AbstractInstruction dec = get(id).dec;
      
            MilestoneTag tag = tags.pop_front();
            assert (tag.kind == GenAddress) else $error("  k////");
            tag = tags.pop_front();
            assert (tag.kind == Rename) else $error(" where rename? k:   %p", tag);
            
            // Has it entered the ROB or killed right after Rename?
            if (!has(tags, RobEnter)) begin
                tag = tags.pop_front();
                assert (tag.kind == FlushOOO) else begin
                    $error("ROB not entered but not FlushOOO!");
                    return 0;
                end
                
                assert (tags.size() == 0) else $error(" strange %d: %p", id, tags);
                return 1;
            end
                        
            assert (checkKilledIq(tags)) else $error("wrong k iq");
    
            if (isStoreIns(dec)) assert (checkKilledStore(tags)) else $error("wrong kStore op");
            if (isLoadIns(dec)) assert (checkKilledLoad(tags)) else $error("wrong kload op");
            if (isBranchIns(dec)) assert (checkKilledBranch(tags)) else $error("wrong kbranch op: %d / %p", id, tags);
            
            return 1;        
        endfunction
    
        function automatic logic checkRetired(input InsId id, input MilestoneTag tags[$]);
            AbstractInstruction dec = get(id).dec;
        
            MilestoneTag tag = tags.pop_front();
            assert (tag.kind == GenAddress) else $error("  ////");
            tag = tags.pop_front();
            assert (tag.kind == Rename) else $error(" where rename?:   %p", tag);
            
            
            assert (has(tags, Retire)) else $error("No Retire");
    
            assert (!has(tags, FlushFront)) else $error("eeee");
            assert (!has(tags, FlushOOO)) else $error("22eeee");
            assert (!has(tags, FlushExec)) else $error("333eeee");
            
            assert (has(tags, RobEnter)) else $error("4444eeee");
            assert (!has(tags, RobFlush)) else $error("5544eeee");
            assert (has(tags, RobExit)) else $error("6664eeee");
            
            assert (checkRetiredIq(tags)) else $error("wrong iq");
            
            if (isStoreIns(dec)) assert (checkRetiredStore(tags)) else $error("wrong Store op");
            if (isLoadIns(dec)) assert (checkRetiredLoad(tags)) else $error("wrong load op");
            if (isBranchIns(dec)) assert (checkRetiredBranch(tags)) else $error("wrong branch op: %d / %p", id, tags);
            
            return 1;
        endfunction
    
        static function automatic logic checkRetiredStore(input MilestoneTag tags[$]);
            assert (has(tags, SqEnter)) else return 0;
            assert (!has(tags, SqFlush)) else return 0;
            assert (has(tags, SqExit)) else return 0;
            
            return 1;
        endfunction
    
        static function automatic logic checkRetiredLoad(input MilestoneTag tags[$]);
            assert (has(tags, LqEnter)) else return 0;
            assert (!has(tags, LqFlush)) else return 0;
            assert (has(tags, LqExit)) else return 0;
            
            return 1;
        endfunction
    
        static function automatic logic checkRetiredBranch(input MilestoneTag tags[$]);
            assert (has(tags, BqEnter)) else return 0;
            assert (!has(tags, BqFlush)) else return 0;
            assert (has(tags, BqExit)) else return 0;
            
            return 1;
        endfunction
    
        static function automatic logic checkRetiredIq(input MilestoneTag tags[$]);
            assert (has(tags, IqEnter)) else return 0;
            assert (!has(tags, IqFlush)) else return 0;
            assert (has(tags, IqExit)) else return 0;
            
            return 1;
        endfunction
    
        static function automatic logic checkKilledStore(input MilestoneTag tags[$]);
            assert (has(tags, SqEnter)) else return 0;
            assert (has(tags, SqFlush) ^ has(tags, SqExit)) else return 0;
            
            return 1;
        endfunction
    
        static function automatic logic checkKilledLoad(input MilestoneTag tags[$]);
            assert (has(tags, LqEnter)) else return 0;
            assert (has(tags, LqFlush) ^ has(tags, LqExit)) else return 0;
            
            return 1;
        endfunction
    
        static function automatic logic checkKilledBranch(input MilestoneTag tags[$]);
            assert (has(tags, BqEnter)) else return 0;
            assert (has(tags, BqFlush) ^ has(tags, BqExit)) else return 0;
            
            return 1;
        endfunction
    
        static function automatic logic checkKilledIq(input MilestoneTag tags[$]);
            assert (has(tags, IqEnter)) else return 0;
            assert (has(tags, IqFlush) ^ has(tags, IqExit)) else return 0;
            
            return 1;
        endfunction
    
        static function automatic logic has(input MilestoneTag q[$], input Milestone m);
            MilestoneTag found[$] = q.find_first with (item.kind == m);
            return found.size() > 0;
        endfunction
    
    
        function automatic logic checkOk(input InsId id);
            MilestoneTag tags[$] = records[id].tags;
            ExecClass eclass = determineClass(tags);
            
            if (eclass == EC_KilledFront) return checkKilledFront(id, tags);
            else if (eclass == EC_KilledOOO) return checkKilledOOO(id, tags);
            else return checkRetired(id, tags);            
        endfunction
    
    endclass


endpackage



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
                                                 //input ForwardingElement feVec[N_VEC_PORTS], input ForwardingElement feInt[N_INT_PORTS], input ForwardingElement feMem[N_MEM_PORTS],
                                                 
                                                 input int stage);
        logic3 res;
        foreach (deps.types[i])
            case (deps.types[i])
                SRC_ZERO:  res[i] = 0;
                SRC_CONST: res[i] = 0;
                SRC_INT:   res[i] = checkForwardInt(imap, deps.producers[i], deps.sources[i], //theExecBlock.intImagesTr[stage], theExecBlock.memImagesTr[stage]);
                                                                                                fws.ints[stage], fws.mems[stage]);
                SRC_FLOAT: res[i] = checkForwardVec(imap, deps.producers[i], deps.sources[i], //theExecBlock.floatImagesTr[stage]);
                                                                                                fws.vecs[stage]);
            endcase      
        return res;
    endfunction

    function automatic Word3 getForwardedValues(input InstructionMap imap,
                                                input ForwardsByStage_0 fws,
                                                input InsDependencies deps, 
                                                //input ForwardingElement feVec[N_VEC_PORTS], input ForwardingElement feInt[N_INT_PORTS], input ForwardingElement feMem[N_MEM_PORTS],
                                                
                                                input int stage);
        Word3 res;
        foreach (deps.types[i])
            case (deps.types[i])
                SRC_ZERO:  res[i] = 0;
                SRC_CONST: res[i] = 0;
                SRC_INT:   res[i] = getForwardValueInt(imap, deps.producers[i], deps.sources[i], //theExecBlock.intImagesTr[stage], theExecBlock.memImagesTr[stage]);
                                                                                                   fws.ints[stage], fws.mems[stage]);
                SRC_FLOAT: res[i] = getForwardValueVec(imap, deps.producers[i], deps.sources[i], //theExecBlock.floatImagesTr[stage]);
                                                                                                   fws.vecs[stage]);
            endcase      
        return res;
    endfunction


    function automatic logic3 checkForwardsReadyAll(input InstructionMap imap,
                                                 input ForwardsByStage_0 fws,
                                                 input InsDependencies deps,
                                                 //input ForwardingElement feVec[N_VEC_PORTS], input ForwardingElement feInt[N_INT_PORTS], input ForwardingElement feMem[N_MEM_PORTS],
                                                 
                                                 input int stages[]);
        logic3 res = '{0, 0, 0};
        foreach (deps.types[i])
            foreach (stages[s])
                case (deps.types[i])
                    SRC_ZERO:  res[i] |= 0;
                    SRC_CONST: res[i] |= 0;
                    SRC_INT:   res[i] |= checkForwardInt(imap, deps.producers[i], deps.sources[i], //theExecBlock.intImagesTr[stage], theExecBlock.memImagesTr[stage]);
                                                                                                    fws.ints[stages[s]], fws.mems[stages[s]]);
                    SRC_FLOAT: res[i] |= checkForwardVec(imap, deps.producers[i], deps.sources[i], //theExecBlock.floatImagesTr[stage]);
                                                                                                    fws.vecs[stages[s]]);
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
        ReadyQueue3 res;// = '{default: dummy3};
        
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

    typedef struct {
        logic used;
        logic active;
        IqArgState state;
            int issueCounter;
        InsId id;
    } IqEntry;


    localparam IqEntry EMPTY_ENTRY = '{used: 0, active: 0, state: EMPTY_ARG_STATE, issueCounter: -1, id: -1};


endpackage
