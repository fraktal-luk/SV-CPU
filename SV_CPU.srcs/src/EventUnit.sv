
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
              interruptH = EMPTY_EVENT_DESC, interrupt = EMPTY_EVENT_DESC,
              nmiH = EMPTY_EVENT_DESC, nmi = EMPTY_EVENT_DESC,
              generalH = EMPTY_EVENT_DESC, general = EMPTY_EVENT_DESC;



    always @(negedge clk) begin
        

    end


    always @(posedge clk) begin
        

    end

endmodule
