
package Insmap;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    import AbstractSim::*;
    


    typedef struct {
        InsId id;
        Word adr;
        Word bits;
        Word target;
        AbstractInstruction dec;
        Word result;
        Word actualResult;
        IndexSet inds;
        int slot; // UNUSED?
        InsDependencies deps;
        int physDest;
        
        Word argValues[3];
        logic argError;
        
        logic exception;
        logic refetch;
        
    } InstructionInfo;


    class InstructionMap;
   
        typedef enum {
            ___,
        
            GenAddress,
            FlushFront,
                PutFQ,
            
            Rename,
            RobEnter, RobComplete, RobFlush, RobExit,
            BqEnter, BqFlush, BqExit,
            SqEnter, SqFlush, SqExit,            
            LqEnter, LqFlush, LqExit,
            
            MemFwProduce, MemFwConsume,
            
            FlushOOO,
            
            FlushExec,
                FlushPoison,
            
            IqEnter,
            IqWakeup0, IqWakeup1, IqWakeup2,
            IqWakeupComplete,
            IqCancelWakeup0, IqCancelWakeup1, IqCancelWakeup2,
            IqIssue,
            IqPullback,
            IqFlush,
            IqExit,
    
            RqEnter, RqFlush, RqIssue, RqExit,
    
              ReadArg, // TODO: by source type
    
              ExecRedirect,            
    
            ReadMem,
            ReadSysReg,
            ReadSQ,
            
            WriteMemAddress,
            WriteMemValue,
            
            // TODO: MQ related: Miss (by type? or types handled separately by mem tracking?), writ to MQ, activate, issue
                MemConfirmed,
                MemMissed,
            
            WriteResult,
            
            FlushCommit,
            
            Retire,
                RetireException,
                RetireRefetch,
            
            WqEnter, WqExit // committed write queue
        } Milestone;
    
    
        typedef struct {
            Milestone kind;
            int cycle;
        } MilestoneTag;
    
        class InsRecord;
            MilestoneTag tags[$];
        endclass
    
        InsId indexList[$];

        InsId specList[$];
        InsId latestCommittedList[$];
        InsId doneList[$];

        InstructionInfo content[InsId];
        InsRecord records[int];
        
        int specListSize;
        int doneListSize;
        
        string specListStr;
        string latestCommittedListStr;
        string doneListStr;
    
        InsId lastRetired = -1;
        InsId lastKilled = -1;
        InsId lastRemoved = -1;

        string lastRetiredStr;
        string lastKilledStr;

        localparam int RECORD_ARRAY_SIZE = 24;
    
        MilestoneTag lastRecordArr[RECORD_ARRAY_SIZE];
        MilestoneTag lastKilledRecordArr[RECORD_ARRAY_SIZE];

            InsId reissuedId = -1;    
    
        // ins info
        static function automatic InstructionInfo initInsInfo(input OpSlot op);
            InstructionInfo res;
            res.id = op.id;
            res.adr = op.adr;
            res.bits = op.bits;
    
            res.physDest = -1;
    
            res.argError = 0;

            res.exception = 0;
            res.refetch = 0;
    
            return res;
        endfunction

        // insinfo
        function automatic void registerIndex(input InsId id);
            indexList.push_back(id);
            records[id] = new();
        endfunction

        // ins info
        function automatic InstructionInfo get(input InsId id);
            assert (content.exists(id)) else $fatal(2, "wrong id %d", id);
            return content[id];
        endfunction
    
        // ins info
        function automatic int size();
            return content.size();
        endfunction
        
        
        /////// insinfo
        function automatic void add(input OpSlot op);
            assert (op.active) else $error("Inactive op added to base");
            content[op.id] = initInsInfo(op);
               specList.push_back(op.id);
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
        
        function automatic void setException(input InsId id);
            content[id].exception = 1;
        endfunction
        
        function automatic void setRefetch(input InsId id);
            content[id].refetch = 1;
        endfunction
        ////////////
    
        // milestones
        function automatic void putMilestone(input InsId id, input Milestone kind, input int cycle);
            if (id == -1) return;
            records[id].tags.push_back('{kind, cycle});
        endfunction

    
        // milestones (helper)
        function automatic void setRecordArr(ref MilestoneTag arr[RECORD_ARRAY_SIZE], input InsId id);
            MilestoneTag def = '{___, -1};
            InsRecord empty = new();
            InsRecord rec = id == -1 ? empty : records[id];
            arr = '{default: def};
            
            foreach(rec.tags[i]) arr[i] = rec.tags[i];
        endfunction


        function automatic void commitCheck(); 
            confirmDone();
        endfunction

        function automatic void confirmDone();
            logic SHOW_STRINGS = 0;
        
            int removed = -1;
        
            foreach (latestCommittedList[i])
                checkOk(latestCommittedList[i]);

            latestCommittedList = '{};

            if (doneList.size() > 100) begin
                while (doneList.size() > 100)
                    removed = doneList.pop_front();

                // $display(" ......... %d,,  %d ", specList.size(), indexList.size());

                while (indexList.size() > 0 && indexList[0] <= removed) begin
                    int tmpIndex = indexList.pop_front();
                    content.delete(tmpIndex);
                    records.delete(tmpIndex);
                end
            end

            while (specList.size() > 0 && specList[0] <= lastRetired) begin
                InsId specHead = specList.pop_front();
                doneList.push_back(specHead);
                latestCommittedList.push_back(specHead);
            end

            specListSize = specList.size();
            doneListSize = doneList.size();

            if (SHOW_STRINGS) begin
                $swrite(specListStr, "%p", specList);
                $swrite(latestCommittedListStr, "%p", latestCommittedList);
                $swrite(doneListStr, "%p", doneList);
            end
        endfunction 


        // all
        function automatic void setRetired(input InsId id);
            assert (id != -1) else $fatal(2, "retired -1");

            lastRetired = id;
            lastRetiredStr = disasm(get(id).bits);
        endfunction

        // all
        function automatic void endCycle();
            setRecordArr(lastRecordArr, lastRetired);
            setRecordArr(lastKilledRecordArr, lastKilled);
        endfunction

        // CHECKS

        // Different area: checking

        // 3 main categories:
        // a. Killed in Front
        // b. Killed in OOO
        // c. Retired
        typedef enum { EC_KilledFront, EC_KilledOOO, EC_KilledCommit, EC_Retired } ExecClass;

        function automatic ExecClass determineClass(input MilestoneTag tags[$]);
            MilestoneTag retirement[$] = tags.find with (item.kind == Retire);
            MilestoneTag frontKill[$] = tags.find with (item.kind == FlushFront);
            MilestoneTag commitKill[$] = tags.find with (item.kind == FlushCommit);

            assert (tags[0].kind == GenAddress) else $fatal(2, "Op not starting with GenAdress");

            if (frontKill.size() > 0) return EC_KilledFront;
            if (commitKill.size() > 0) return EC_KilledCommit;
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

        function automatic logic checkKilledCommit(input InsId id, input MilestoneTag tags[$]);
            AbstractInstruction dec = get(id).dec;
      
            MilestoneTag tag = tags.pop_front();
            assert (tag.kind == GenAddress) else $error("  k////");
            tag = tags.pop_front();
            assert (tag.kind == Rename) else $error(" where rename? k:   %p", tag);
            
//            // Has it entered the ROB or killed right after Rename?
//            if (!has(tags, RobEnter)) begin
//                tag = tags.pop_front();
//                assert (tag.kind == FlushOOO) else begin
//                    $error("ROB not entered but not FlushOOO!");
//                    return 0;
//                end
                
//                assert (tags.size() == 0) else $error(" strange %d: %p", id, tags);
//                return 1;
//            end
                        
            //assert (checkKilledIq(tags)) else $error("wrong k iq");
    
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
            assert (has(tags, RobComplete)) else $error("4444eeee");
            assert (!has(tags, RobFlush)) else $error("5544eeee");
            assert (has(tags, RobExit)) else $error("6664eeee");
            
            assert (checkRetiredIq(tags)) else $error("wrong iq");
            
            if (isStoreIns(dec)) assert (checkRetiredStore(tags)) else $error("wrong Store op");
            if (isLoadIns(dec)) assert (checkRetiredLoad(tags)) else $error("wrong load op");
            if (isBranchIns(dec)) assert (checkRetiredBranch(tags)) else $error("wrong branch op: %d / %p", id, tags);
            
                // HACK: if has been pulled back, remember it
                begin
                    if (has(tags, IqPullback)) storeReissued(id, tags);
                end

            return 1;
        endfunction
    
                function automatic void storeReissued(input InsId id, input MilestoneTag tags[$]);
                    //    $error("Tags [%d] are:\n%p", id, tags);
                    if (reissuedId != -1) return;
                    
                    begin
                        MilestoneTag issueTags[$] = tags.find with (item.kind == IqIssue);
                        MilestoneTag exitTags[$] = tags.find with (item.kind == IqExit);
                        MilestoneTag pullbackTags[$] = tags.find with (item.kind == IqPullback);
                        
                       // $error("Tags [%d] are:\n%p", id, tags);
                        
                            issueTags.sort with (item.cycle);
                            pullbackTags.sort with(item.cycle);
                            
                            assert (exitTags.size() == 1) else $fatal(2, "!!!!!");
                            assert (issueTags[$].cycle < exitTags[0].cycle) else $fatal(2, "!!!!!");
                            assert (pullbackTags[$].cycle < issueTags[$].cycle) else $fatal(2, "!!!!!");
                            
                           // $error("confimrd reissue");
                            
                        reissuedId = id;
                    end
                    
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
            else if (eclass == EC_KilledCommit) return checkKilledCommit(id, tags);
            else if (eclass == EC_KilledOOO) return checkKilledOOO(id, tags);
            else return checkRetired(id, tags);            
        endfunction
        


            function automatic void assertReissue();
                  //  $display(" reissued is %d ", reissuedId);
                assert (reissuedId != -1) else $fatal(2, "Not found reissued!");
            endfunction
        
    endclass


endpackage
