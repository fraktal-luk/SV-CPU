
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

    function automatic int getSize();
        return branchCheckpointQueue.size();
    endfunction

    function automatic BranchCheckpoint getCheckpoint(input InsId mid);
        BranchCheckpoint foundCP[$] = checkpointUnit.branchCheckpointQueue.find with (item.id == mid);
        return foundCP[0];
    endfunction

    task automatic flushAll();
        branchCheckpointQueue = '{};
    endtask

    task automatic flushPartial(input InsId id);
        while (branchCheckpointQueue.size() > 0 && branchCheckpointQueue[$].id > id) begin
            void'(branchCheckpointQueue.pop_back());
        end
    endtask  


    task automatic addCheckpoint(input BranchCheckpoint cp);
        branchCheckpointQueue.push_back(cp);
    endtask


    function automatic BranchCheckpoint frontElem();
        return branchCheckpointQueue[0];
    endfunction

    task automatic pop();
        branchCheckpointQueue.pop_front();
    endtask

endmodule

