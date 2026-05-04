
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;
import EmulationDefs::*;

import UopList::*;
import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;
import ControlHandling::*;

import CacheDefs::*;

import Queues::*;

module EventUnit(input logic clk);


    typedef struct {
        logic active;
        InsId id;
        ProgramEvent etype;
    } EventDesc;

    localparam EventDesc EMPTY_EVENT_DESC = '{0, -1, PE_NONE};


    logic chp, chq;

    InsId currentEventReg = -1, lqRefetchNewH = -1;

    AccessDesc lastEvtAD;
    Translation lastEvtTr;

    ProgramEvent lastEvtFetch = PE_NONE;
    OpSlotB staticEventNewH = EMPTY_SLOT_B;
    UopPacket memRefetchNewH = EMPTY_UOP_PACKET;
    UopPacket memEventReg = EMPTY_UOP_PACKET, memEventNewH = EMPTY_UOP_PACKET;
    UopPacket fpInvReg = EMPTY_UOP_PACKET, fpInvNewH = EMPTY_UOP_PACKET;
    UopPacket fpOvReg = EMPTY_UOP_PACKET, fpOvNewH = EMPTY_UOP_PACKET;



    EventDesc frontH = EMPTY_EVENT_DESC, front = EMPTY_EVENT_DESC,
                dbStepH = EMPTY_EVENT_DESC, dbStep = EMPTY_EVENT_DESC, // Separate because can be overridden by exception
              execMemH = EMPTY_EVENT_DESC, execMem = EMPTY_EVENT_DESC,
              execArithH = EMPTY_EVENT_DESC, execArith = EMPTY_EVENT_DESC,
                fpInvH = EMPTY_EVENT_DESC, fpInv = EMPTY_EVENT_DESC,
                fpOvH = EMPTY_EVENT_DESC, fpOv = EMPTY_EVENT_DESC,

              execRefetchH = EMPTY_EVENT_DESC, execRefetch = EMPTY_EVENT_DESC,
              lqRefetchH = EMPTY_EVENT_DESC, lqRefetch = EMPTY_EVENT_DESC,

              interruptH = EMPTY_EVENT_DESC, interrupt = EMPTY_EVENT_DESC,
              nmiH = EMPTY_EVENT_DESC, nmi = EMPTY_EVENT_DESC,
              generalH = EMPTY_EVENT_DESC, general = EMPTY_EVENT_DESC;



    always @(negedge clk) begin
        fpInvNewH <= findOldestWithState(ES_FP_INVALID, theExecBlock.floatImagesTr[0]);
        fpOvNewH <=  findOldestWithState(ES_FP_OVERFLOW, theExecBlock.floatImagesTr[0]);

        memEventNewH <= findOldestMemEvt(theExecBlock.memImagesTr[0]);
        memRefetchNewH <= findOldestWithState(ES_REFETCH, theExecBlock.memImagesTr[0]);

        lqRefetchNewH <= theLq.submod.oldestRefetchEntryP0.mid;
        staticEventNewH <= getOldestRenameEvSlot();


            frontH <= edFromFront(getOldestRenameEvSlot());

            fpInvH <= edFromUop(findOldestWithState(ES_FP_INVALID, theExecBlock.floatImagesTr[0]));
            fpOvH <=  edFromUop(findOldestWithState(ES_FP_OVERFLOW, theExecBlock.floatImagesTr[0]));

            execMemH <= edFromUop(findOldestMemEvt(theExecBlock.memImagesTr[0]));
            execRefetchH <= edFromUop(findOldestWithState(ES_REFETCH, theExecBlock.memImagesTr[0]));
            lqRefetchH <= edFromLqRefetch(theLq.submod.oldestRefetchEntryP0.mid);


    end


    always @(posedge clk) begin
        updateCurrentEventReg();
    end


    function automatic OpSlotB getOldestRenameEvSlot();
        // TODO: if stageRename1_N is not empty and has a fetch event, catch it

        OpSlotB found[$] = AbstractCore.stageRename1.find_first with (item.active && hasStaticEvent(item.mid));
        // No need to find oldest because they are ordered in slot. They are also younger than any executed op and current slot content.

        if (found.size() == 0) return EMPTY_SLOT_B;
        else return found[0];
    endfunction


    function automatic EventDesc edFromUop(input UopPacket p);
        if (!p.active) return EMPTY_EVENT_DESC;

        // TODO: fill evt type
        return '{1, U2M(p.TMP_oid), PE_NONE};
    endfunction

    function automatic EventDesc edFromLqRefetch(input InsId id);
        if (id == -1) return EMPTY_EVENT_DESC;

        return '{1, id, PE_HW_REFETCH};
    endfunction 

    function automatic EventDesc edFromFront(input OpSlotB slot);
        if (slot.mid == -1) return EMPTY_EVENT_DESC;

        // TODO: fill evt
        return '{1, slot.mid, PE_NONE};
    endfunction 


        task automatic updateCurrentEventReg();
            EventDesc newValue = getCurrentEvent();
            // int inds[$] = memImagesTr[0].find_first_index with (item.active && U2M(item.TMP_oid) == newValue); 

            // // Is the new ID one of mem uops?
            // if (inds.size() > 0) begin
            //     int ind = inds[0];
            //     lastEvtAD <= accessDescs_E2[ind];
            //     lastEvtTr <= dcacheTranslations_E2[ind];
            // end
            // else if (newValue != currentEventReg) begin // If changes to non-memory
            //     lastEvtAD <= DEFAULT_ACCESS_DESC;
            //     lastEvtTr <= DEFAULT_TRANSLATION;
            // end

            // // Is it a fetch event?
            // if (staticEventNewH.mid == newValue)
            //     lastEvtFetch <= AbstractCore.stageRename1_N.evt;
            // else if (newValue != currentEventReg)
            //     lastEvtFetch <= PE_NONE;


            general <= newValue;

            // // Needs: ?
            // fpInvReg <= Exec_replaceEvP(fpInvReg, fpInvNewH);
            // fpOvReg <= Exec_replaceEvP(fpOvReg, fpOvNewH);

            // // Needs: kind of event, mem access address (V only?)
            // memEventReg <= Exec_replaceEvP(memEventReg, memEventNewH);

        endtask


        function automatic EventDesc replaceEvt(input EventDesc prev, input EventDesc next);
            EventDesc older = prev;
            InsId prevId = (prev.id);
            InsId nextId = (next.id);
            InsId olderId = replaceEvId(prevId, nextId);

            if (prevId == -1) older = next;
            else if (nextId != -1 && prevId > nextId) older = next;

            assert (olderId == (older.id)) else $error("Ids differ");

            //if (shouldFlushId(olderId) || AbstractCore.lastRetired > olderId) return EMPTY_UOP_PACKET;
            //else
                return older;
        endfunction

        function automatic EventDesc getCurrentEvent();
            EventDesc tmp = general;
                        
            if (AbstractCore.CurrentConfig.enArithExc) begin
                tmp = replaceEvt(tmp, fpInvH);
                tmp = replaceEvt(tmp, fpOvH);
            end

            tmp = replaceEvt(tmp, execMemH);
            tmp = replaceEvt(tmp, execRefetchH);
            tmp = replaceEvt(tmp, lqRefetchH);
            tmp = replaceEvt(tmp, frontH);

            if (shouldFlushId(tmp.id) || AbstractCore.lastRetired > tmp.id) tmp = EMPTY_EVENT_DESC;

            return tmp;
        endfunction

endmodule
