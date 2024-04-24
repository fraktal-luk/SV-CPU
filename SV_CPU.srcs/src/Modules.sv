
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;





    // Frontend
    module Frontend(ref InstructionMap insMap, input EventInfo branchEventInfo, input EventInfo lateEventInfo);
    
        typedef Word FetchGroup[FETCH_WIDTH];

    
   // generate

        int fqSize = 0;


        Stage_N ipStage = EMPTY_STAGE, fetchStage0 = EMPTY_STAGE, fetchStage1 = EMPTY_STAGE;
        Stage_N fetchQueue[$:FETCH_QUEUE_SIZE];

        int fetchCtr = 0;
        OpSlotA stageRename0 = '{default: EMPTY_SLOT};


        task automatic registerNewTarget(input int fCtr, input Word target);
            int slotPosition = (target/4) % FETCH_WIDTH;
            Word baseAdr = target & ~(4*FETCH_WIDTH-1);
            for (int i = slotPosition; i < FETCH_WIDTH; i++) begin
                Word adr = baseAdr + 4*i;
                int index = fCtr + i;
                insMap.registerIndex(index);
                putMilestone(index, InstructionMap::GenAddress);
            end
        endtask


        function automatic Stage_N setActive(input Stage_N s, input logic on, input int ctr);
            Stage_N res = s;
            Word firstAdr = res[0].adr;
            Word baseAdr = res[0].adr & ~(4*FETCH_WIDTH-1);

            if (!on) return EMPTY_STAGE;

            foreach (res[i]) begin
                res[i].active = (((firstAdr/4) % FETCH_WIDTH <= i)) === 1;
                res[i].id = res[i].active ? ctr + i : -1;
                res[i].adr = res[i].active ? baseAdr + 4*i : 'x;
            end

            return res;
        endfunction

        function automatic Stage_N setWords(input Stage_N s, input FetchGroup fg);
            Stage_N res = s;
            foreach (res[i])
                if (res[i].active) res[i].bits = fg[i];
            return res;
        endfunction


        task automatic flushFrontend();
            markKilledFrontStage(fetchStage0);
            markKilledFrontStage(fetchStage1);
            fetchStage0 <= EMPTY_STAGE;
            fetchStage1 <= EMPTY_STAGE;

            foreach (fetchQueue[i]) begin
                Stage_N current = fetchQueue[i];
                markKilledFrontStage(current);
            end
            fetchQueue.delete();
        endtask

        task automatic redirectFront();
            Word target;

            if (lateEventInfo.redirect)         target = lateEventInfo.target;
            else if (branchEventInfo.redirect)  target = branchEventInfo.target;
            else $fatal(2, "Should never get here");

            markKilledFrontStage(ipStage);
            ipStage <= '{0: '{1, -1, target, 'x}, default: EMPTY_SLOT};

            fetchCtr <= fetchCtr + FETCH_WIDTH;

            registerNewTarget(fetchCtr + FETCH_WIDTH, target);

            flushFrontend();

            markKilledFrontStage(stageRename0);
            stageRename0 <= '{default: EMPTY_SLOT};
        endtask

        task automatic fetchAndEnqueue();
            Stage_N fetchStage0ua, ipStageU;
            if (AbstractCore.fetchAllow) begin
                Word target = (ipStage[0].adr & ~(4*FETCH_WIDTH-1)) + 4*FETCH_WIDTH;
                ipStage <= '{0: '{1, -1, target, 'x}, default: EMPTY_SLOT};
                fetchCtr <= fetchCtr + FETCH_WIDTH;
                
                registerNewTarget(fetchCtr + FETCH_WIDTH, target);
            end

            ipStageU = setActive(ipStage, ipStage[0].active & AbstractCore.fetchAllow, fetchCtr);

            fetchStage0 <= ipStageU;
            fetchStage0ua = setWords(fetchStage0, AbstractCore.insIn);
            
            foreach (fetchStage0ua[i]) if (fetchStage0ua[i].active) begin
                insMap.add(fetchStage0ua[i]);
                insMap.setEncoding(fetchStage0ua[i]);
            end

            fetchStage1 <= fetchStage0ua;
            if (anyActive(fetchStage1)) fetchQueue.push_back(fetchStage1);
        
            stageRename0 <= readFromFQ();
        endtask
        
        function automatic OpSlotA readFromFQ();
            OpSlotA res = '{default: EMPTY_SLOT};
    
            // fqSize is written in prev cycle, so new items must wait at least a cycle in FQ
            if (fqSize > 0 && AbstractCore.renameAllow) begin
                Stage_N fqOut_N = fetchQueue.pop_front();
                foreach (fqOut_N[i]) res[i] = fqOut_N[i];
            end
            
            return res;
        endfunction

         
        // Frontend process
        always @(posedge AbstractCore.clk) begin
            if (lateEventInfo.redirect || branchEventInfo.redirect)
                redirectFront();
            else
                fetchAndEnqueue();
                
            fqSize <= fetchQueue.size();
        end

    //endgenerate

    endmodule
    
    



    // IQs
    module IssueQueueComplex(ref InstructionMap insMap);
    //generate
        typedef logic ReadyVec[OP_QUEUE_SIZE];

        OpSlot opQueue[$:OP_QUEUE_SIZE];            
        ReadyVec opsReady, opsReadyRegular, opsReadyBranch, opsReadyMem, opsReadySys;
    
        OpSlot T_iqRegular[$:OP_QUEUE_SIZE];
        OpSlot T_iqBranch[$:OP_QUEUE_SIZE];
        OpSlot T_iqMem[$:OP_QUEUE_SIZE];
        OpSlot T_iqSys[$:OP_QUEUE_SIZE];
    

        task automatic writeToIqs();
            foreach (AbstractCore.stageRename1[i]) begin
                OpSlot op = AbstractCore.stageRename1[i];
                if (op.active) begin
                    addToIssueQueues(op);
                end
            end
        endtask
    
        task automatic addToIssueQueues(input OpSlot op);
            opQueue.push_back(op);
            // Mirror into separate queues 
            if (isLoadIns(decAbs(op)) || isStoreIns(decAbs(op))) T_iqMem.push_back(op);
            else if (isSysIns(decAbs(op))) T_iqSys.push_back(op);
            else if (isBranchIns(decAbs(op))) T_iqBranch.push_back(op);
            else T_iqRegular.push_back(op); 
        endtask
    
        task automatic flushIqs();
            if (AbstractCore.lateEventInfo.redirect) begin
                flushOpQueueAll();
            end
            else if (AbstractCore.branchEventInfo.redirect) begin
                flushOpQueuePartial(AbstractCore.branchEventInfo.op);
            end
        endtask
    
    
        task automatic flushOpQueueAll();
            while (opQueue.size() > 0) begin
                OpSlot op = (opQueue.pop_back());
                //insMap.setKilled(op.id);
            end
            while (T_iqRegular.size() > 0) begin
                void'(T_iqRegular.pop_back());
            end
            while (T_iqBranch.size() > 0) begin
                void'(T_iqBranch.pop_back());
            end
            while (T_iqMem.size() > 0) begin
                void'(T_iqMem.pop_back());
            end
            while (T_iqSys.size() > 0) begin
                void'(T_iqSys.pop_back());
            end
        endtask
    
        task automatic flushOpQueuePartial(input OpSlot op);
            while (opQueue.size() > 0 && opQueue[$].id > op.id) begin
                void'(opQueue.pop_back());
            end
            while (T_iqRegular.size() > 0 && T_iqRegular[$].id > op.id) begin
                void'(T_iqRegular.pop_back());
            end
            while (T_iqBranch.size() > 0 && T_iqBranch[$].id > op.id) begin
                void'(T_iqBranch.pop_back());
            end
            while (T_iqMem.size() > 0 && T_iqMem[$].id > op.id) begin
                void'(T_iqMem.pop_back());
            end
            while (T_iqSys.size() > 0 && T_iqSys[$].id > op.id) begin
                void'(T_iqSys.pop_back());
            end
        endtask
    
    
        function automatic IssueGroup issueFromOpQ(ref OpSlot queue[$:OP_QUEUE_SIZE], input int size, input ReadyVec rv);
            IssueGroup res = DEFAULT_ISSUE_GROUP;
    
            int maxNum = size > 4 ? 4 : size;
            if (maxNum > queue.size()) maxNum = queue.size(); // Queue may be flushing in this cycle, so possiblre shrinkage is checked here 
        
            for (int i = 0; i < maxNum; i++) begin
                OpSlot op;
                
                if (!rv[i]) break;
                
                op = queue.pop_front();
                assert (op.active) else $fatal(2, "Op from queue is empty!");
                res.num++;
                
                if (isBranchIns(decAbs(op))) begin
                    res.branch = op;
                    assert (op === T_iqBranch.pop_front()) else $error("wrong");
                    break;
                end
                else if (isLoadIns(decAbs(op)) || isStoreIns(decAbs(op))) begin
                    res.mem = op;
                    assert (op === T_iqMem.pop_front()) else $error("wrong");
                    break;
                end
                else if (isSysIns(decAbs(op))) begin
                    res.sys = op;
                    assert (op === T_iqSys.pop_front()) else $error("wrong");
                    break;
                end
                
                assert (op === T_iqRegular.pop_front()) else $error("wrong");
                res.regular[i] = op;
            end
            
            return res;
        endfunction


        function automatic logic3 checkArgsReady_A(input InsDependencies deps);//, input logic readyInt[N_REGS_INT], input logic readyFloat[N_REGS_FLOAT]);
            logic3 res;
            foreach (deps.types[i])
                case (deps.types[i])
                    SRC_ZERO:  res[i] = 1;
                    SRC_CONST: res[i] = 1;
                    SRC_INT:   res[i] = AbstractCore.intRegsReadyV[deps.sources[i]];
                    SRC_FLOAT: res[i] = AbstractCore.floatRegsReadyV[deps.sources[i]];
                endcase      
            return res;
        endfunction

        function automatic ReadyVec getReadyVec_A(input OpSlot iq[$:OP_QUEUE_SIZE]);
            ReadyVec res = '{default: 'z};
            foreach (iq[i]) begin
                InsDependencies deps = insMap.get(iq[i].id).deps;
                logic3 ra = checkArgsReady_A(deps);
                res[i] = ra.and();
            end
            return res;
        endfunction


        task automatic updateReadyVecs_A();
            opsReady <= getReadyVec_A(opQueue);
            
            opsReadyRegular <= getReadyVec_A(T_iqRegular);
            opsReadyBranch <= getReadyVec_A(T_iqBranch);
            opsReadyMem <= getReadyVec_A(T_iqMem);
            opsReadySys <= getReadyVec_A(T_iqSys);
    
            AbstractCore.oooLevels_N.oq <= opQueue.size();
        endtask    
    
   
        always @(posedge AbstractCore.clk) begin
            if (AbstractCore.lateEventInfo.redirect || AbstractCore.branchEventInfo.redirect)
                flushIqs();
            else
                writeToIqs();
           
            // Issue
            begin
                automatic IssueGroup igIssue = issueFromOpQ(opQueue, AbstractCore.oooLevels_N.oq, opsReady);
                AbstractCore.theExecBlock.issuedSt0 <= effIG(igIssue);
                updateReadyVecs_A();
            end
        end
        
    //endgenerate
    endmodule





    module ExecBlock(ref InstructionMap insMap);

        // Issue/Exec
        IssueGroup issuedSt0 = DEFAULT_ISSUE_GROUP, issuedSt1 = DEFAULT_ISSUE_GROUP;
        IssueGroup issuedSt0_E, issuedSt1_E;
    
        // Exec
        OpSlot memOp_A = EMPTY_SLOT, memOpPrev = EMPTY_SLOT;
        OpSlot memOp_E, memOpPrev_E;
        
        OpSlot doneOpsRegular[4] = '{default: EMPTY_SLOT};
        OpSlot doneOpBranch = EMPTY_SLOT, doneOpMem = EMPTY_SLOT, doneOpSys = EMPTY_SLOT;
    
        OpSlot doneOpsRegular_E[4];
        OpSlot doneOpBranch_E, doneOpMem_E, doneOpSys_E;
    
    
    
        Word execResultsRegular[4] = '{'x, 'x, 'x, 'x};
        Word execResultLink = 'x, execResultMem = 'x;

    
        // Exec process
        always @(posedge AbstractCore.clk) begin
            begin
                AbstractCore.readInfo <= EMPTY_WRITE_INFO;
                AbstractCore.branchEventInfo <= EMPTY_EVENT_INFO;
                runExec();
            end
        end
        
        assign memOp_E = eff(memOp_A);
        assign memOpPrev_E = eff(memOpPrev);
    
        assign issuedSt0_E = effIG(issuedSt0);
        assign issuedSt1_E = effIG(issuedSt1);
    
        assign doneOpsRegular_E = effA(doneOpsRegular);
        assign doneOpBranch_E = eff(doneOpBranch);
        assign doneOpMem_E = eff(doneOpMem);
        assign doneOpSys_E = eff(doneOpSys);
    
    
    
        // $$Exec
        task automatic runExec();
            IssueGroup igExec = DEFAULT_ISSUE_GROUP;
    
            issuedSt1 <= issuedSt0_E;
            igExec = issuedSt1_E;
    
            execResultsRegular <= '{default: 'x};
            execResultLink <= 'x;
            execResultMem <= 'x;
    
            foreach (igExec.regular[i])
                if (igExec.regular[i].active) performRegularOp(igExec.regular[i], i);
            if (igExec.branch.active)   execBranch(igExec.branch);
            if (igExec.mem.active) performMemFirst(igExec.mem);
    
            memOp_A <= igExec.mem;
    
            memOpPrev <= memOp_E;
            if (memOpPrev_E.active) performMemLater(memOpPrev_E);
    
            doneOpsRegular <= igExec.regular;
            doneOpBranch <= igExec.branch;
            doneOpMem <= memOpPrev_E;
            doneOpSys <= igExec.sys;
        endtask
    
    
    
        
    
        task automatic setBranchTarget(input OpSlot op, input Word trg);
            int ind[$] = AbstractCore.branchTargetQueue.find_first_index with (item.id == op.id);
            AbstractCore.branchTargetQueue[ind[0]].target = trg;
        endtask
    
        task automatic updateSQ(input InsId id, input Word adr, input Word val);
            int ind[$] = AbstractCore.storeQueue.find_first_index with (item.op.id == id);
            AbstractCore.storeQueue[ind[0]].adr = adr;
            AbstractCore.storeQueue[ind[0]].val = val;
        endtask
        
    
        function automatic Word3 getPhysicalArgValues(input RegisterTracker tracker, input OpSlot op);
            InsDependencies deps = insMap.get(op.id).deps;
            return getArgValues(tracker, deps);            
        endfunction
    
        function automatic Word3 getAndVerifyArgs(input OpSlot op);
            Word3 argsP = getPhysicalArgValues(AbstractCore.registerTracker, op);
            Word3 argsM = insMap.get(op.id).argValues;
            assert (argsP === argsM) else $error("not equal args %p / %p", argsP, argsM);
            return argsP;
        endfunction;
    
    
    
        task automatic performRegularOp(input OpSlot op, input int index);
            AbstractInstruction abs = decAbs(op);
            Word3 args = getAndVerifyArgs(op);
            Word result = calculateResult(abs, args, op.adr); // !!!!
            
            execResultsRegular[index] <= result;
        endtask    
    
        task automatic performMemFirst(input OpSlot op);
            AbstractInstruction abs = decAbs(op);
            Word3 args = getAndVerifyArgs(op);
            Word adr = calculateEffectiveAddress(abs, args);
    
            // TODO: compare adr with that in memTracker
            if (isStoreIns(decAbs(op))) begin
                updateSQ(op.id, adr, args[2]);
                
                if (isStoreMemIns(decAbs(op))) begin
                    checkStoreValue(op.id, adr, args[2]);
                    
                    putMilestone(op.id, InstructionMap::WriteMemAddress);
                    putMilestone(op.id, InstructionMap::WriteMemValue);
                end
            end

            AbstractCore.readInfo <= '{1, adr, 'x};
        endtask
    
        typedef StoreQueueEntry StoreQueueExtract[$];
    
        task automatic performMemLater(input OpSlot op);
            AbstractInstruction abs = decAbs(op);
            Word3 args = getAndVerifyArgs(op);
    
            Word adr = calculateEffectiveAddress(abs, args);
    
            StoreQueueEntry matchingStores[$] = getMatchingStores(op, adr);
            // Get last (youngest) of the matching stores
            Word memData = (matchingStores.size() != 0) ? matchingStores[$].val : AbstractCore.readIn[0];
            Word data = isLoadSysIns(abs) ? getSysReg(args[1]) : memData;
        
            if (matchingStores.size() != 0) begin
              //  $display("SQ forwarding %d->%d", matchingStores[$].op.id, op.id);
            end
    
            execResultMem <= data;
        endtask
    
        function automatic StoreQueueExtract getMatchingStores(input OpSlot op, input Word adr);  
            // TODO: develop adr overlap check?
            StoreQueueEntry oooMatchingStores[$] = AbstractCore.storeQueue.find with (item.adr == adr && isStoreMemIns(decAbs(item.op)) && item.op.id < op.id);
            StoreQueueEntry committedMatchingStores[$] = AbstractCore.csq_N.find with (item.adr == adr && isStoreMemIns(decAbs(item.op)) && item.op.id < op.id);
            StoreQueueEntry matchingStores[$] = {committedMatchingStores, oooMatchingStores};
            return matchingStores;
        endfunction
    
    
        task automatic setExecEvent(input OpSlot op);
            AbstractInstruction abs = decAbs(op);
            Word3 args = getAndVerifyArgs(op);
    
            ExecEvent evt = resolveBranch(abs, op.adr, args);
    
            BranchCheckpoint found[$] = AbstractCore.branchCheckpointQueue.find with (item.op.id == op.id);
            AbstractCore.branchCP = found[0];
            setBranchTarget(op, evt.redirect ? evt.target : op.adr + 4);
    
            AbstractCore.branchEventInfo <= '{op, 0, 0, evt.redirect, evt.target};
        endtask
    
        task automatic performLinkOp(input OpSlot op);
            AbstractInstruction abs = decAbs(op);
            Word result = op.adr + 4;
    
            execResultLink <= result;       
        endtask
        
        task automatic execBranch(input OpSlot op);
            setExecEvent(op);
            performLinkOp(op);
        endtask
    

    endmodule














