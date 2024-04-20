
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
                AbstractCore.issuedSt0 <= effIG(igIssue);
                updateReadyVecs_A();
            end
        end
        
    //endgenerate
    endmodule












