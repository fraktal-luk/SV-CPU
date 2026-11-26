
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;
import Queues::*;


module CheckpointUnit();
    BranchCheckpoint branchCheckpointQueue[$:BC_QUEUE_SIZE];

    RegisterCheckpoint registerCheckpointQueue[$:BC_QUEUE_SIZE];


    function automatic int getSize();
        return branchCheckpointQueue.size();
    endfunction

    function automatic BranchCheckpoint getCheckpoint(input InsId mid);
        BranchCheckpoint foundCP[$] = branchCheckpointQueue.find with (item.id == mid);
        return foundCP[0];
    endfunction


    function automatic RegisterCheckpoint getRegisterCheckpoint(input InsId mid);
        RegisterCheckpoint foundCP[$] = registerCheckpointQueue.find with (item.mid == mid);
        return foundCP[0];
    endfunction

    task automatic flushAll();
        branchCheckpointQueue = '{};
        registerCheckpointQueue = '{};
    endtask

    task automatic flushPartial(input InsId id);
        while (branchCheckpointQueue.size() > 0 && branchCheckpointQueue[$].id > id) begin
            void'(branchCheckpointQueue.pop_back());
        end

        while (registerCheckpointQueue.size() > 0 && registerCheckpointQueue[$].mid > id) begin
            void'(registerCheckpointQueue.pop_back());
        end
    endtask  


    task automatic addCheckpoint(input BranchCheckpoint cp);
        branchCheckpointQueue.push_back(cp);
    endtask

        task automatic addRegCheckpoint(input InsId id, input int index, input RenamePatch patch, input PhysicalName tb[]);
            registerCheckpointQueue.push_back('{id, index, tb, patch});
        endtask


    function automatic BranchCheckpoint frontElem();
        return branchCheckpointQueue[0];
    endfunction


    task automatic pop();
        branchCheckpointQueue.pop_front();
        registerCheckpointQueue.pop_front();
    endtask



    function automatic void check();
        assert (branchCheckpointQueue.size() == registerCheckpointQueue.size()) else $fatal(2, "Disagrre size %d : %d",
                                        branchCheckpointQueue.size(), registerCheckpointQueue.size());
    endfunction

endmodule

