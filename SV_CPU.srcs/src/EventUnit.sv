
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



    logic chp, chq;


    AccessDesc lastEvtAD = DEFAULT_ACCESS_DESC;
    Translation lastEvtTr = DEFAULT_TRANSLATION;

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
        frontH <= getFrontEv();

        fpInvH <= edFromUop(findOldestWithState(ES_FP_INVALID, theExecBlock.floatImagesTr[0]));
        fpOvH <=  edFromUop(findOldestWithState(ES_FP_OVERFLOW, theExecBlock.floatImagesTr[0]));

        execMemH <= edFromUop(findOldestMemEvt(theExecBlock.memImagesTr[0]));
        execRefetchH <= edFromUop(findOldestWithState(ES_REFETCH, theExecBlock.memImagesTr[0]));
        lqRefetchH <= edFromLqRefetch(theLq.submod.oldestRefetchEntryP0.mid);
    end


    always @(posedge clk) begin
        updateCurrentEventReg();
    end


    function automatic EventDesc getFrontEv();
        // TODO: if stageRename1_N is not empty and has a fetch event, catch it

        OpSlotB found[$] = AbstractCore.stageRename1.find_first with (item.active && hasStaticEvent(item.mid));
        // No need to find oldest because they are ordered in slot. They are also younger than any executed op and current slot content.

        if (!AbstractCore.stageRename1_N.active) return EMPTY_EVENT_DESC;

        if (AbstractCore.stageRename1_N.evt) return '{1, AbstractCore.stageRename1[0].mid, AbstractCore.stageRename1_N.evt};

        if (found.size() == 0) return EMPTY_EVENT_DESC;
        else return edFromFront(found[0]);
    endfunction


    function automatic EventDesc edFromUop(input UopPacket p);
        ProgramEvent evt = PE_NONE;
        UopName uname;

        if (!p.active) return EMPTY_EVENT_DESC;

        uname = decUname(p.TMP_oid);

        case (p.status)
            ES_INVALID: begin
                if (isMemUop(uname)) evt = PE_MEM_INVALID_ADDRESS;
                else if (isStoreSysUop(uname) || isLoadSysUop(uname)) evt = PE_SYS_INVALID_ADDRESS;
            end
            ES_ILLEGAL: begin
                if (isMemUop(uname)) evt = PE_MEM_DISALLOWED_ACCESS;
                else if (isStoreSysUop(uname) || isLoadSysUop(uname)) evt = PE_SYS_DISALLOWED_ACCESS;
            end

            ES_FP_INVALID, ES_FP_OVERFLOW: evt = PE_ARITH_EXCEPTION;

            ES_REFETCH: evt = PE_HW_REFETCH;

            default: ;
        endcase

        return '{1, U2M(p.TMP_oid), evt};
    endfunction

    function automatic EventDesc edFromLqRefetch(input InsId id);
        if (id == -1) return EMPTY_EVENT_DESC;

        return '{1, id, PE_HW_REFETCH};
    endfunction 

    function automatic EventDesc edFromFront(input OpSlotB slot);
        ProgramEvent evt = PE_NONE;

        if (slot.mid == -1) return EMPTY_EVENT_DESC;

        // TODO: fill evt
        

        
        return '{1, slot.mid, evt};
    endfunction 


    task automatic updateCurrentEventReg();
        EventDesc newValue = getCurrentEvent();

        general <= newValue;

        front <= replaceEvt(front, frontH);

        fpInv <= replaceEvt(fpInv, fpInvH);
        fpOv <=  replaceEvt(fpOv, fpOvH);

        execMem <= replaceEvt(execMem, execMemH);
        execRefetch <= replaceEvt(execRefetch, execRefetchH);
        lqRefetch <= replaceEvt(lqRefetch, lqRefetchH);

        if (execMemH != execMem && execMemH.active) begin
            int inds[$] = theExecBlock.memImagesTr[0].find_first_index with (item.active && U2M(item.TMP_oid) == newValue.id); 
            assert (inds.size() > 0) else $error("Can't find mem op responsible for event\n%p\n%p", execMemH, execMem);

            lastEvtAD <= theExecBlock.accessDescs_E2[inds[0]];
            lastEvtTr <= theExecBlock.dcacheTranslations_E2[inds[0]];
        end
    endtask


    function automatic EventDesc replaceEvt(input EventDesc prev, input EventDesc next);
        EventDesc older = prev;
        InsId prevId = (prev.id);
        InsId nextId = (next.id);
        InsId olderId = replaceEvId(prevId, nextId);

        if (prevId == -1) older = next;
        else if (nextId != -1 && prevId > nextId) older = next;

        assert (olderId == (older.id)) else $error("Ids differ");

        if (shouldFlushId(olderId) || AbstractCore.lastRetired > olderId) return EMPTY_EVENT_DESC;
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

        //if (shouldFlushId(tmp.id) || AbstractCore.lastRetired > tmp.id) tmp = EMPTY_EVENT_DESC;

        return tmp;
    endfunction

        assign chp = (general.id == theExecBlock.currentEventReg); 

endmodule
