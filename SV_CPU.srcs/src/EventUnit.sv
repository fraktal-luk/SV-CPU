
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

    BackendState backendState = BS_NONE;

    logic chp, chq;

    logic clearEvent = 0, clearInterruptEvt = 0;

    int intCounter = -1;

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
              generalH = EMPTY_EVENT_DESC, general = EMPTY_EVENT_DESC,
                interruptEvtH = EMPTY_EVENT_DESC, interruptEvt = EMPTY_EVENT_DESC,
                resetEvtH = EMPTY_EVENT_DESC, resetEvt = EMPTY_EVENT_DESC,
                dbEvtH = EMPTY_EVENT_DESC, dbEvt = EMPTY_EVENT_DESC;


    always @(negedge clk) begin
        frontH <= getFrontEv();
        dbEvtH <= getDbEv();

        fpInvH <= edFromUop(findOldestWithState(ES_FP_INVALID, theExecBlock.floatImagesTr[0]));
        fpOvH <=  edFromUop(findOldestWithState(ES_FP_OVERFLOW, theExecBlock.floatImagesTr[0]));

        execMemH <= edFromUop(findOldestMemEvt(theExecBlock.memImagesTr[0]));
        execRefetchH <= edFromUop(findOldestWithState(ES_REFETCH, theExecBlock.memImagesTr[0]));
        lqRefetchH <= edFromLqRefetch(theLq.submod.oldestRefetchEntry.mid);
    end


    always @(posedge clk) begin
        updateCurrentEventReg();

        clearInterruptEvt <= 0;

        if (AbstractCore.lateEventInfo.redirect) begin
            // Detect interrupt rejection
            if (interruptEvt.active && AbstractCore.lateEventInfo.etype != PE_EXT_INTERRUPT) begin
                clearInterruptEvt <= 1;
                    $display("Interrupt rejected");
            end

            interruptEvt <= EMPTY_EVENT_DESC;
            resetEvt <= EMPTY_EVENT_DESC;
            dbEvt <= EMPTY_EVENT_DESC;

            backendState <= BS_NORMAL;
        end


        if (AbstractCore.reset) begin
            resetEvt <= '{1, -1, PE_EXT_RESET};

            if (backendState == BS_NORMAL) backendState <= BS_WAIT;
        end
        else resetEvt <= EMPTY_EVENT_DESC;
        
        if (AbstractCore.interrupt) begin
            interruptEvt <= '{1, -1, PE_EXT_INTERRUPT};
            intCounter <= 10;

            if (backendState == BS_NORMAL) backendState <= BS_WAIT;
        end
        else if (intCounter > 0) intCounter <= intCounter - 1;

    end


    function automatic EventDesc getFrontEv();
        OpSlotB found[$] = AbstractCore.stageRename1_N.arr.find_first with (item.active && hasStaticEvent(item.mid));
        OpSlotB foundAny[$] = AbstractCore.stageRename1_N.arr.find_first with (item.active);
        // No need to find oldest because they are ordered in slot. They are also younger than any executed op and current slot content.

        if (!AbstractCore.stageRename1_N.active) return EMPTY_EVENT_DESC;

        assert (foundAny.size() > 0) else $error("Renamed group active, must have active element");

        if (AbstractCore.stageRename1_N.evt != PE_NONE) return '{1, foundAny[0].mid, AbstractCore.stageRename1_N.evt};

        if (found.size() == 0) return EMPTY_EVENT_DESC;

        return edFromFront(found[0]);
    endfunction

    function automatic EventDesc getDbEv();
        OpSlotB foundAny[$] = AbstractCore.stageRename1_N.arr.find_first with (item.active);

        if (!AbstractCore.stageRename1_N.active) return EMPTY_EVENT_DESC;

        if (AbstractCore.CurrentConfig.dbStep) return '{1, foundAny[0].mid, PE_EXT_DEBUG};
        else return EMPTY_EVENT_DESC;
    endfunction


    function automatic EventDesc edFromUop(input UopPacket p);
        ProgramEvent evt = PE_NONE;
        UopName uname;

        if (!p.active) return EMPTY_EVENT_DESC;

        uname = decUname(p.TMP_oid);

        case (p.status)
            ES_UNALIGNED:
                evt = PE_MEM_UNALIGNED_ADDRESS;
            ES_NONEXISTENT: begin
                evt = PE_MEM_NONEXISTENT_ADDRESS;
            end
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
        UopName uname;

        if (slot.mid == -1) return EMPTY_EVENT_DESC;

        uname = decMainUop(slot.mid);
        evt = eventFromUop(uname);

        return '{1, slot.mid, evt};
    endfunction 


    task automatic updateCurrentEventReg();
        EventDesc newValue = getCurrentEvent();

        // Signal if general is being cleared
        if (!newValue.active && general.active) clearEvent <= 1;
        else clearEvent <= 0;

        if (backendState != BS_HANDLING) begin
            if (newValue.active   ||     frontH.active ) backendState <= BS_WAIT;
            else if (!interruptEvt.active && !resetEvt.active) backendState <= BS_NORMAL;
        end

        general <= newValue;

        dbEvt <= replaceEvt(dbEvt, dbEvtH);

        front <= replaceEvt(front, frontH);

        fpInv <= replaceEvt(fpInv, fpInvH);
        fpOv <=  replaceEvt(fpOv, fpOvH);

        execMem <= replaceEvt(execMem, execMemH);
        execRefetch <= replaceEvt(execRefetch, execRefetchH);
        lqRefetch <= replaceEvt(lqRefetch, lqRefetchH);

        if (execMemH != execMem && execMemH.active) begin
            int inds[$] = theExecBlock.memImagesTr[0].find_first_index with (item.active && U2M(item.TMP_oid) == execMemH.id); 
            assert (inds.size() > 0) else $error("Can't find mem op responsible for event\n%p\n%p", execMemH, execMem);

            lastEvtAD <= //theExecBlock.accessDescs_E2[inds[0]];
                            mn.adE2[inds[0]];
            lastEvtTr <= //theExecBlock.dcacheTranslations_E2[inds[0]];
                            mn.trE2[inds[0]];
        end
    endtask


    function automatic EventDesc replaceEvt(input EventDesc prev, input EventDesc next);
        EventDesc older = prev;
        InsId prevId = (prev.id);
        InsId nextId = (next.id);
        InsId olderId = replaceEvId(prevId, nextId);

        if (prevId == -1) older = next;
        else if (nextId != -1 && prevId > nextId) older = next;
        //else if (prevId == nextId && prev.etype == PE_EXT_DEBUG) older = next; // DB step is overridden by exceptions 

        assert (olderId == (older.id)) else $error("Ids differ");

        if (shouldFlushId(olderId) || AbstractCore.lastRetired > olderId) return EMPTY_EVENT_DESC;
        return older;
    endfunction

    function automatic EventDesc getCurrentEvent();
        EventDesc tmp = general;

        if (AbstractCore.CurrentConfig.enArithExc || AbstractCore.CurrentConfig.enTrapInv) begin
            tmp = replaceEvt(tmp, fpInvH);
        end

        if (AbstractCore.CurrentConfig.enArithExc || AbstractCore.CurrentConfig.enTrapOv) begin
            tmp = replaceEvt(tmp, fpOvH);
        end

        tmp = replaceEvt(tmp, execMemH);
        tmp = replaceEvt(tmp, execRefetchH);
        tmp = replaceEvt(tmp, lqRefetchH);
        tmp = replaceEvt(tmp, frontH);

        return tmp;
    endfunction


    function automatic logic hasEvent();
        return general.active
            || dbEvt.active
            || resetEvt.active
            || interruptEvt.active
            ;
    endfunction 


    function automatic void setHandling();
        backendState <= BS_HANDLING;
    endfunction


    // > Needs ForwardingElement
    function automatic UopPacket findOldestWithState(input ExecStatus refSt, input ForwardingElement stages[]);
        ForwardingElement found[$] = stages.find with (item.active && item.status == refSt);
        ForwardingElement oldest[$] = found.min with (U2M(item.TMP_oid));

        if (found.size() == 0) return EMPTY_UOP_PACKET;

        assert (oldest[0].TMP_oid != UIDT_NONE) else $fatal(2, "id none");
        return oldest[0];
    endfunction

    // > Needs ForwardingElement
    function automatic UopPacket findOldestMemEvt(input ForwardingElement stages[]);
        ForwardingElement found[$] = stages.find with (item.active && item.status inside {ES_ILLEGAL, ES_INVALID, ES_NONEXISTENT, ES_UNALIGNED});
        ForwardingElement oldest[$] = found.min with (U2M(item.TMP_oid));
        
        if (found.size() == 0) return EMPTY_UOP_PACKET;
        
        assert (oldest[0].TMP_oid != UIDT_NONE) else $fatal(2, "id none");
        return oldest[0];
    endfunction


endmodule
