
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
        
            SqEnter, SqFlush, SqExit,            
            LqEnter, LqFlush, LqExit,
            BqEnter, BqFlush, BqExit,
            
            WqEnter, WqExit, // committed write queue
            
            FlushOOO,
                FlushExec,
                // TODO: flush in every region? (ROB, subpipes, queues etc.)
            
            Wakeup,
            CancelWakeup,
            Issue,
            Pullback,
            
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
            InsId id;
            Milestone kind;
            int cycle;
        } MilestoneDesc;
        
        typedef struct {
            Milestone kind;
            int cycle;
        } MilestoneTag;
                

        class InsRecord;
            MilestoneTag tags[$];
        endclass
        
        int indexList[$];
    
        InstructionInfo content[int];
        
        InsId retiredArr[$];
        InsId killedArr[$];

        InsId retiredArrPre[$];
        InsId killedArrPre[$];


        string retiredArrStr;
        string killedArrStr;
        
        
        InsId lastRenamed = -1;
        InsId lastRetired = -1;
        InsId lastKilled = -1;
        
            InsId lastRetiredPre = -1;
            InsId lastRetiredPrePre = -1;

            InsId lastKilledPre = -1;
            InsId lastKilledPrePre = -1;
        
            string lastRetiredStr;
         
            string lastRetiredStrPre;
            string lastRetiredStrPrePre;
        
            string lastKilledStr;
         
            string lastKilledStrPre;
            string lastKilledStrPrePre;


            InsRecord records[int];

            MilestoneTag lastRecordArr[16];
                MilestoneTag lastRecordArrPre[16];
                MilestoneTag lastRecordArrPrePre[16];
            
            MilestoneTag lastKilledRecordArr[16];
                MilestoneTag lastKilledRecordArrPre[16];
                MilestoneTag lastKilledRecordArrPrePre[16];
            
            
   
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

                setLastRecordArr(lastRecordArr, lastRetired);
                setLastRecordArr(lastRecordArrPre, lastRetiredPre);
                setLastRecordArr(lastRecordArrPrePre, lastRetiredPrePre);
          
                setLastRecordArr(lastKilledRecordArr, lastKilled);
                setLastRecordArr(lastKilledRecordArrPre, lastKilledPre);
                setLastRecordArr(lastKilledRecordArrPrePre, lastKilledPrePre);

        endfunction
        
        
        function automatic InstructionInfo get(input int id);
            assert (content.exists(id)) else $fatal(2, "wrong id %d", id);
            return content[id];
        endfunction
        
        function automatic int size();
            return content.size();
        endfunction
        

        function automatic void add(input OpSlot op);
            assert (op.active) else $error("Inactive op added to base");
            content[op.id] = makeInsInfo(op);
        endfunction

        // CAREFUL: temporarily here: decode and store to avoid repeated decoding later 
        function automatic void setEncoding(input OpSlot op);
            AbstractInstruction ins;
            assert (op.active) else $error("encoding set for inactive op");
            content[op.id].bits = op.bits;
            ins = decodeAbstract(op.bits);
            content[op.id].dec = ins;
        endfunction

        function automatic void setTarget(input int id, input Word trg);
            content[id].target = trg;
        endfunction
    
        function automatic void setResult(input int id, input Word res);
            content[id].result = res;
        endfunction
 
        function automatic void setActualResult(input int id, input Word res);
            content[id].actualResult = res;
        endfunction

        function automatic void setDeps(input int id, input InsDependencies deps);
            content[id].deps = deps;
        endfunction
        
        function automatic void setInds(input int id, input IndexSet indexSet);
            content[id].inds = indexSet;
        endfunction

        function automatic void setSlot(input int id, input int slot);
            content[id].slot = slot;
        endfunction

        function automatic void setPhysDest(input int id, input int dest);
            content[id].physDest = dest;
        endfunction
      
        function automatic void setArgValues(input int id, input Word vals[3]);
            content[id].argValues = vals;
        endfunction

        function automatic void setArgError(input int id);
            content[id].argError = 1;
        endfunction

       
       
        function automatic void setRetired(input int id);
            assert (id != -1) else $fatal(2, "retired -1");

            retiredArr.push_back(id);
            $swrite(retiredArrStr, "%p", retiredArr);
            
            lastRetired = id;
            lastRetiredStr = disasm(get(id).bits);
        endfunction
        
        function automatic void setKilled(input int id);
            assert (id != -1) else $fatal(2, "killed -1");
        
            killedArr.push_back(id);
            $swrite(killedArrStr, "%p", killedArr);

            if (id <= lastKilled) return;
            lastKilled = id;
            if (content.exists(id))
                lastKilledStr = disasm(get(id).bits);
            else begin
                lastKilledStr = "???";
                $error("Killed not added: %d", id);
            end
        endfunction




        function automatic void setLastRecordArr(ref MilestoneTag arr[16], input InsId id);
            MilestoneTag def = '{___, -1};
            InsRecord empty = new();
            InsRecord rec = id == -1 ? empty : records[id];
            arr = '{default: def};
            
            foreach(rec.tags[i]) arr[i] = rec.tags[i];
        endfunction

         
        function automatic void registerIndex(input int id);
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
        
        function automatic void putMilestone(input int id, input Milestone kind, input int cycle);
            if (id == -1) return;
            records[id].tags.push_back('{kind, cycle});
        endfunction
        
        
            function automatic void verifyMilestones(input int id);
                MilestoneTag tagList[$] = records[id].tags;
                MilestoneTag found[$] = tagList.find_first with (item.kind == RobExit);
                assert (found.size() > 0) else $error("Op %d: not seen exiting ROB!", id); 
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

        function automatic logic checkKilledFront(input MilestoneTag tags[$]);
            MilestoneTag tag = tags.pop_front();
            assert (tag.kind == GenAddress) else $error("ddkld");
            tag = tags.pop_front();
            assert (tag.kind == FlushFront) else $error(" ttt:   %p", tag);
            
            assert (tags.size() == 0) else $error("   why not empty: %p", tags);
            
            return 1;
        endfunction

        function automatic logic checkKilledOOO(input MilestoneTag tags[$]);
        
        endfunction

        function automatic logic checkRetired(input MilestoneTag tags[$]);
        
        endfunction
        

        function automatic logic checkOk(input InsId id);
            MilestoneTag tags[$] = records[id].tags;
            ExecClass eclass = determineClass(tags);
            
            if (eclass == EC_KilledFront) return checkKilledFront(tags);
            else if (eclass == EC_KilledOOO) return checkKilledOOO(tags);
            else return checkRetired(tags);            
        endfunction

//                ___,
            
//                GenAddress,  Must (all)
//                FlushFront,  Final
//                PutFQ,       UNUSED

//                Rename,      Must OR FlushFront                
//                RobEnter,    Must OR FlushFront
//                    RobFlush,  
//                    RobExit,   
            
//                SqEnter, SqFlush, SqExit,            
//                LqEnter, LqFlush, LqExit,
//                BqEnter, BqFlush, BqExit,
                
//                WqEnter, WqExit, // committed write queue
                
//                FlushOOO,
//                    FlushExec,
//                    // TODO: flush in every region? (ROB, subpipes, queues etc.)
                
//                Wakeup,
//                CancelWakeup,
//                Issue,
//                Pullback,
                
//                    ReadArg, // TODO: by source type
                    
//                    ExecRedirect,            
                
//                ReadMem,
//                ReadSysReg,
//                ReadSQ,
                
//                WriteMemAddress,
//                WriteMemValue,
                
//                // TODO: MQ related: Miss (by type? or types handled separately by mem tracking?), writ to MQ, activate, issue
                
                
//                WriteResult,
//                Complete,
                
//                Retire,
                
//                Drain    

        
        
    endclass


