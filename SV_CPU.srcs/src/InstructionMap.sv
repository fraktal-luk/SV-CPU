
package Insmap;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;
    
    import UopList::*;

    import AbstractSim::*;

    
    typedef int Unum;
        

    typedef struct {
        Mword adr;
        Word bits;
        Mword target;
        AbstractInstruction dec;
    } InsBasicData;
    
    
        typedef struct {
            UopName name;
            int sources[3];
            int dest;
        } UopDef;    
    
    
        // What should be in base
        typedef struct {
            UopId id;
            
            logic status; // TODO: enum
            
            UopName name;
            int physDest;
            
            InsDependencies deps;
            
            Mword argsE[3]; // Args from emulation
            Mword argsA[3]; // Actual args read from regs and bypass
            Mword resultE;  // Result according to emulation
            Mword resultA;  // Actual result
            
            logic argError;    // DB
            logic resultError; // DB
            
            logic exception;   // Execution event from actual uarch
        } UopInfo;
    


    typedef struct {
        InsId id;            
        InsBasicData basicData;

        UopName mainUop; // For 1 uop Mops is equal to the uop

        Unum firstUop;
        int nUops;

        IndexSet inds;
        int slot; // UNUSED?

        logic exception;
        logic refetch;
    } InstructionInfo;


        typedef struct {
            InsId mid;
            InsId fid; // Fetch id - links to adr, bits, etc
            int nUops;
            InsId firstUop; // Not needed if using '{m, s} type of index of uops
        } MopDescriptor;




    function automatic InstructionInfo initInsInfo(
                                                    input InsId id,
                                                    input Mword adr,
                                                    input Word bits
                                                    );
        InstructionInfo res;
        res.id = id;
        
        res.basicData.adr = adr;
        res.basicData.bits = bits;
        res.basicData.dec = decodeAbstract(bits);

        res.exception = 0;
        res.refetch = 0;

        return res;
    endfunction
    
    

    class InstructionBase;
        InstructionInfo minfos[InsId];
        UopInfo uinfos[Unum];
        InsId mids[$];
        Unum uids[$];

            InsId lastId = -1;
            
        InsId lastM = -1;
        Unum lastU = -1;
                
        InsId retired = -1;
        InsId retiredPrev = -1;

        InsId retiredM = -1;
        InsId retiredPrevM = -1;
       
        string dbStr;


        function automatic void addM(input InsId id, input InstructionInfo ii);
            UopInfo uinfo;
            Unum lastPrevU = lastU;
            
                int nUops = 1;
            
                lastId = id;
                
            lastM++;
            
                assert (lastId == lastM) else $fatal(2, "wring idss");

            mids.push_back(lastM);

            minfos[id] = ii;
              minfos[id].firstUop = lastPrevU + 1; 
              minfos[id].nUops = nUops; 
              
              
            // TODO: per each uop
            for (int u = 0; u < nUops; u++) begin
                lastU++;
                    
                    assert (lastU == lastM + u) else $error(" U // M ");
            
                uids.push_back(lastU);
                
                uinfos[lastU].physDest = -1;
                uinfos[lastU].argError = 0;
            end
        endfunction

        function automatic void setRenamed(input InsId id,
                                            input Mword result,
                                            input Mword target,
                                            input InsDependencies deps,
                                            input int physDest,
                                            input Mword argValues[3],
                                            input IndexSet renameInds,
                                            input int slot
                                            );
            Unum uBase = minfos[id].firstUop;
            int nU = minfos[id].nUops;
                                            
            minfos[id].inds = renameInds;
            minfos[id].slot = slot;
            
            minfos[id].basicData.target = target;
            
            
            for (int u = 0; u < nU; u++) begin
                uinfos[uBase + u].id = '{id, u};
                //infos[id].name = ...; // TODO
                
                uinfos[uBase + u].physDest = physDest;
                uinfos[uBase + u].deps = deps;
                uinfos[uBase + u].argsE = argValues;
                uinfos[uBase + u].resultE = result;
            end
        endfunction


//            function automatic InsId m2i(input InsId mid);
//                int found[$] = mids.find_first_index with (item == mid);
//                assert (found.size() > 0) else $fatal(2, "unknown mid");
//                return ids[found[0]];
//            endfunction
    
//            function automatic InsId i2m(input InsId id);
//                int found[$] = ids.find_first_index with (item == id);
//                assert (found.size() > 0) else $fatal(2, "unknown id");
//                return mids[found[0]];
//            endfunction



        function automatic void retireUpToM(input InsId id);
            retired = id;
                retiredM = id;
        endfunction


        function automatic IdQueue removeUpToM(input InsId id /*, input Unum unum*/);
            IdQueue res;
            
            while (mids.size() > 0 && mids[0] <= id) begin
                InsId frontId = mids[0];
                void'(mids.pop_front());
                
                //for (int u = 0; u < nU; u++)
                   // void'(uids.pop_front()); // TODO: num of uops
                
                res.push_back(frontId);
            end
            
            return res;
        endfunction

//            function automatic void removeUpToU(input Unum unum);
//                IdQueue res;
                
//                while (uids.size() > 0 && uids[0] <= unum) begin
//                    Unum frontUnum = uids[0];
//                    void'(uids.pop_front());
//                end
                
//            endfunction
       
        
        function automatic void checkOp(input InsId id);

        endfunction 
        

            function automatic string TMP_getStr();
                string res;
                InsId first = -1;
                InsId last = -1;
                
                int size = mids.size();
                
                if (mids.size() > 0) begin
                    first = mids[0];
                    last = mids[$];
                end
                
                $swrite(res, "[%d]: [%d, ... %d]", mids.size(), first, last);
                
                return res;
            endfunction
            
            function automatic void setDbStr();
                dbStr = TMP_getStr();
            endfunction
    endclass
    

    class InstructionMap;
   
        InstructionBase insBase = new();        
        string dbStr;
   
        typedef enum {
            ___,
        
            
            // Front
                GenAddress,
                FlushFront,
//                PutFQ,
            
            
            // Mops
            Rename,
            RobEnter, RobComplete, RobFlush, RobExit,
            BqEnter, BqFlush, BqExit,
            SqEnter, SqFlush, SqExit,            
            LqEnter, LqFlush, LqExit,

            FlushOOO,
            
            FlushCommit,
            
            Retire,
            RetireException,
            RetireRefetch,
            
            WqEnter, 
                
                WqExit, // committed write queue

                MemFwProduce,
                
            // Uops
            MemFwConsume, // U
            
            FlushExec, // U
            FlushPoison, // U
            
            IqEnter,
            IqWakeup0, IqWakeup1, IqWakeup2,
            IqWakeupComplete,
            IqCancelWakeup0, IqCancelWakeup1, IqCancelWakeup2,
            IqIssue,
            IqPullback,
            IqFlush,
            IqExit,
    
            RqEnter, RqFlush, RqIssue, RqExit,
    
              ReadArg, // FUTURE: by source type
    
              ExecRedirect,            
            //
                
                // UNUSED
                ReadMem,
                ReadSysReg,
                ReadSQ,
            
            WriteMemAddress, // U
            WriteMemValue,   // U
            
            // FUTURE: MQ related: Miss (by type? or types handled separately by mem tracking?), writ to MQ, activate, issue
                MemConfirmed,
                MemMissed,
            
            WriteResult // U

        } Milestone;
    
    
        typedef struct {
            Milestone kind;
            int cycle;
        } MilestoneTag;
    
        class MopRecord;
            MilestoneTag tags[$:20];
        endclass

        typedef MopRecord UopRecord;
        
        MopRecord records[InsId];
        UopRecord recordsU[InsId];

        InsId lastRetired = -1;

        string lastRetiredStr;

        localparam int RECORD_ARRAY_SIZE = 20;
    
            MilestoneTag lastRecordArr[RECORD_ARRAY_SIZE];

            InsId reissuedId = -1;    
    
            int renamedM = 0;
            
            int committedM = 0;
                        
            
            function automatic void alloc();

            endfunction

            function automatic void dealloc();

            endfunction


        // insinfo
        function automatic void registerIndex(input InsId id);

        endfunction

        // ins info
        function automatic InstructionInfo get(input InsId id);
            assert (insBase.minfos.exists(id)) else $fatal(2, "wrong id %d", id);
            return insBase.minfos[id];
        endfunction

        function automatic UopInfo getU(input UidT uid);
            Unum uIndex = insBase.minfos[U2M(uid)].firstUop + uid.s;

            assert (insBase.uinfos.exists(U2M(uid))) else $fatal(2, "wrong id %p", uid);
            
                assert (uIndex == U2M(uid)) else $error("mismatchedd");
            
            return insBase.uinfos[ uIndex ];
        endfunction

        // ins info
        function automatic int size();
            return insBase.minfos.size();
        endfunction
        

//            function automatic InsId m2i(input InsId mid);
//                return insBase.m2i(mid);
//            endfunction
    
//            function automatic InsId i2m(input InsId id);
//                return insBase.i2m(id);
//            endfunction


        /////// insinfo
        
        // DEPREC
        function automatic void add(input InsId id, input Mword adr, input Word bits
        );

        endfunction

        // DEPREC
        function automatic void setEncoding(input InsId id, input Word bits);

        endfunction
    

        function automatic void addM(input InsId id, input Mword adr, input Word bits);
            insBase.addM(id, initInsInfo(id, adr, bits));
            records[id] = new();
            recordsU[id] = new();
        endfunction

       
        function automatic void setRenamed(input InsId id,
                                            input Mword result,
                                            input Mword target,
                                            input InsDependencies deps,
                                            input int physDest,
                                            input Mword argValues[3],
                                            input IndexSet renameInds,
                                            input int slot
                                            );
            insBase.setRenamed(id, result, target, deps, physDest, argValues, renameInds, slot);
        endfunction

        function automatic void setUopName(input InsId id, input UopName name);
            insBase.minfos[id].mainUop = name;
            
            insBase.uinfos[id].name = name;
        endfunction

        function automatic void setActualResult(input UidT uid, input Mword res);
            insBase.uinfos[  U2M(uid)].resultA = res;
        endfunction

        function automatic void setActualArgs(input UidT uid, input Mword args[3]);
            insBase.uinfos[ U2M(uid)].argsA = args;
        endfunction

        function automatic void setArgError(input UidT uid, input logic value);
            insBase.uinfos[ U2M(uid)].argError = value;
        endfunction
        
        
        function automatic void setException(input InsId id);
            insBase.minfos[id].exception = 1;
        endfunction
        
        function automatic void setRefetch(input InsId id);
            insBase.minfos[id].refetch = 1;
        endfunction
        ////////////



        // milestones
        
        // DEPREC - may be reused in future
        function automatic void putMilestoneF(input InsId id, input Milestone kind, input int cycle);
        endfunction
        
        // For Mops
        function automatic void putMilestoneM(input InsId id, input Milestone kind, input int cycle);
            if (id == -1) return;
            records[id].tags.push_back('{kind, cycle});   
        endfunction
        
        // For uops
        function automatic void putMilestone(input UidT uid, input Milestone kind, input int cycle);
            if (uid == UIDT_NONE) return;
            recordsU[U2M(uid)].tags.push_back('{kind, cycle});
        endfunction
        
        // For committed
        function automatic void putMilestoneC(input InsId id, input Milestone kind, input int cycle);
            if (id == -1) return;
        endfunction

        // milestones (helper)
            function automatic void setRecordArr(ref MilestoneTag arr[RECORD_ARRAY_SIZE], input InsId id);
                MilestoneTag def = '{___, -1};
                MopRecord empty = new();
                MopRecord rec = id == -1 ? empty : records[id];
                arr = '{default: def};
                
                foreach(rec.tags[i]) arr[i] = rec.tags[i];
            endfunction



        function automatic void commitCheck();
            while (insBase.mids.size() > 0 && insBase.mids[0] <= insBase.retiredPrev) begin
                InsId removedId = insBase.mids.pop_front();
            
                Unum firstUop = insBase.minfos[removedId].firstUop;
                int nU = insBase.minfos[removedId].nUops;
            
                void'(checkOk(removedId));
                records.delete(removedId);

                insBase.minfos.delete(removedId);

                for (int u = 0; u < nU; u++) begin
                    recordsU.delete(firstUop + u);
                //end
                //for (int u = 0; u < nU; u++)
                    insBase.uinfos.delete(firstUop + u);
                    
                //for (int u = 0; u < nU; u++) begin
                    assert (insBase.uids[0] == firstUop + u) else $error("not match");
                    void'(insBase.uids.pop_front());
                end
            end
            
            insBase.retiredPrev = insBase.retired;
            insBase.retiredPrevM = insBase.retiredM;
        endfunction 


        // all
        function automatic void setRetired(input InsId id);
            assert (id != -1) else $fatal(2, "retired -1");

            lastRetired = id;
            lastRetiredStr = disasm(get(id).basicData.bits);
            
            insBase.retireUpToM(id);
        endfunction


        // all
        function automatic void endCycle();

        endfunction

        // CHECKS

        // Different area: checking

        // 3(*) main categories:
        // DEPREC: a. Killed in Front
        // b. Killed in OOO
        // c. Retired
        typedef enum { EC_KilledFront, EC_KilledOOO, EC_KilledCommit, EC_Retired } ExecClass;

        function automatic ExecClass determineClass(input MilestoneTag tags[$]);
            MilestoneTag retirement[$] = tags.find with (item.kind inside {Retire, RetireRefetch, RetireException});
            MilestoneTag commitKill[$] = tags.find with (item.kind == FlushCommit);

            if (commitKill.size() > 0) return EC_KilledCommit;
            if (retirement.size() > 0) return EC_Retired;
            return EC_KilledOOO;            
        endfunction
        

        function automatic logic checkKilledOOO(input InsId id, input MilestoneTag tags[$], input MilestoneTag tagsU[$]);
            AbstractInstruction dec = get(id).basicData.dec;

            MilestoneTag tag = tags.pop_front();
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

            if (isStoreIns(dec)) assert (checkKilledStore(tags)) else $error("wrong kStore op");
            if (isLoadIns(dec)) assert (checkKilledLoad(tags)) else $error("wrong kload op");
            if (isBranchIns(dec)) assert (checkKilledBranch(tags)) else $error("wrong kbranch op: %d / %p", id, tags);

            assert (checkKilledIq(tagsU)) else $error("wrong k iq");

            return 1;        
        endfunction

        function automatic logic checkKilledCommit(input InsId id, input MilestoneTag tags[$], input MilestoneTag tagsU[$]);
            AbstractInstruction dec = get(id).basicData.dec;
      
            MilestoneTag tag = tags.pop_front();
            assert (tag.kind == Rename) else $error(" where rename? k:   %p", tag);
    
            if (isStoreIns(dec)) assert (checkKilledStore(tags)) else $error("wrong kStore op");
            if (isLoadIns(dec)) assert (checkKilledLoad(tags)) else $error("wrong kload op");
            if (isBranchIns(dec)) assert (checkKilledBranch(tags)) else $error("wrong kbranch op: %d / %p", id, tags);
            
            assert (checkRetiredIq(tagsU)) else $error("wrong iq");
            
            return 1;        
        endfunction

        function automatic logic checkRetired(input InsId id, input MilestoneTag tags[$], input MilestoneTag tagsU[$]);
            AbstractInstruction dec = get(id).basicData.dec;
        
            MilestoneTag tag = tags.pop_front();
            assert (tag.kind == Rename) else $error(" where rename?:   %p", tag);
                
            assert (!has(tags, FlushOOO)) else $error("22eeee");
            assert (!has(tags, FlushExec)) else $error("333eeee");
            
            assert (has(tags, RobEnter)) else $error("4444eeee");
            assert (has(tags, RobComplete)) else $error("4444eeee");
            assert (!has(tags, RobFlush)) else $error("5544eeee");
            assert (has(tags, RobExit)) else $error("6664eeee");
              
            if (isStoreIns(dec)) assert (checkRetiredStore(tags)) else $error("wrong Store op");
            if (isLoadIns(dec)) assert (checkRetiredLoad(tags)) else $error("wrong load op");
            if (isBranchIns(dec)) assert (checkRetiredBranch(tags)) else $error("wrong branch op: %d / %p", id, tags);
            
            assert (checkRetiredIq(tagsU)) else $error("wrong iq");

                // HACK: if has been pulled back, remember it
                begin
                    if (has(tagsU, IqPullback)) storeReissued(id, tagsU);
                end

            return 1;
        endfunction
    
            function automatic void storeReissued(input InsId id, input MilestoneTag tags[$]);
                  //  $display("Store reissued %d, %p", id, tags[$]);
                if (reissuedId != -1) return;
                
                begin
                    MilestoneTag issueTags[$] = tags.find with (item.kind == IqIssue);
                    MilestoneTag exitTags[$] = tags.find with (item.kind == IqExit);
                    MilestoneTag pullbackTags[$] = tags.find with (item.kind == IqPullback);
                                        
                    issueTags.sort with (item.cycle);
                    pullbackTags.sort with(item.cycle);
                    
                    assert (exitTags.size() == 1) else $fatal(2, "!!!!!");
                    assert (issueTags[$].cycle < exitTags[0].cycle) else $fatal(2, "!!!!!");
                    assert (pullbackTags[$].cycle < issueTags[$].cycle) else $fatal(2, "!!!!!");
                                                
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
            MilestoneTag tagsU[$] = recordsU[id].tags;
            ExecClass eclass = determineClass(tags);

            if (eclass == EC_KilledCommit) return checkKilledCommit(id, tags, tagsU);
            else if (eclass == EC_KilledOOO) return checkKilledOOO(id, tags, tagsU);
            else return checkRetired(id, tags, tagsU);
        endfunction
        

            function automatic void assertReissue();
                assert (reissuedId != -1) else $fatal(2, "Not found reissued!");
            endfunction
        
    endclass


endpackage
