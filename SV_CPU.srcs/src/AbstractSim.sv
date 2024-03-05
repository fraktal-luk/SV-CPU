//`timescale 1ns / 1ps

 import Base::*;
 import InsDefs::*;
 import Asm::*;
 import Emulation::*;

package AbstractSim;
    
     import Base::*;
     import InsDefs::*;
     import Asm::*;
     import Emulation::*;

     typedef Word Mword;

    typedef struct {
        logic active;
        int id;
        Word adr;
        Word bits;
    } OpSlot;

    const OpSlot EMPTY_SLOT = '{'0, -1, 'x, 'x};

     typedef struct {
        Mword target;
        logic redirect;
        logic sig;
        logic wrong;
     } LateEvent;

    const LateEvent EMPTY_LATE_EVENT = '{'x, 0, 0, 0};
    
    static EmulationWithMems emul = new();
    static int commitCtr = 0;
    static string testName;

    function static void TMP_setTest(input string str);
        testName = str;
        emul.prepareTest({str, ".txt"}, 1024);
    endfunction

    function static void TMP_prepareErrorTest();
        emul.prepareErrorTest(1024);            
    endfunction

    function static void TMP_prepareEventTest();
        emul.prepareEventTest(1024);            
    endfunction
    
    function static void TMP_prepareIntTest();
        emul.prepareIntTest(1024);            
    endfunction


    function static void TMP_reset();
        commitCtr = 0;
        emul.resetCpu();
    endfunction

    function static void TMP_commit(input OpSlot op);
        automatic Word theIp;
        commitCtr++;
        emul.step();
        emul.writeAndDrain();
            
        theIp = emul.emul.ip;
            
        if (theIp != op.adr || emul.emul.str != disasm(op.bits)) $display("Mismatched commit: %d: %s;  %d: %s", theIp, emul.emul.str, op.adr, disasm(op.bits));
    endfunction

    function static int TMP_getCommit();
        return commitCtr;
    endfunction


    function static void TMP_interrupt();
        emul.interrupt();
    endfunction

    function static Emulator TMP_getEmul();
        return emul.emul;
    endfunction

    function static EmulationWithMems TMP_getEmulWithMems();
        return emul;
    endfunction

    function automatic LateEvent getLateEvent(input OpSlot op, input AbstractInstruction abs, input Mword sr2, input Mword sr3);
        LateEvent res = '{target: 'x, redirect: 0, sig: 0, wrong: 0};
        case (abs.def.o)
            O_sysStore: ;
            O_undef: begin
                res.target = IP_ERROR;
                res.redirect = 1;
                res.wrong = 1;
            end
            O_call: begin
                res.target = IP_CALL;
                res.redirect = 1;
            end
            O_retE: begin
                res.target = sr2;
                res.redirect = 1;
            end 
            O_retI: begin
                res.target = sr3;
                res.redirect = 1;
            end 
            O_sync: begin
                res.target = op.adr + 4;
                res.redirect = 1;
            end
            
            O_replay: begin
                res.target = op.adr;
                res.redirect = 1;
            end 
            O_halt: begin                
                res.target = op.adr + 4;
                res.redirect = 1;
            end
            O_send: begin
                res.target = op.adr + 4;
                res.redirect = 1;
                res.sig = 1;
            end
            default: ;                            
        endcase

        return res;
    endfunction
        


    function automatic logic writesIntReg(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return hasIntDest(abs);
    endfunction


    function automatic logic writesFloatReg(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return hasFloatDest(abs);
    endfunction


    function automatic logic isBranchOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isBranchIns(abs);
    endfunction
    

    function automatic logic isStoreMemOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return abs.def.o inside {O_intStoreW, O_intStoreD, O_floatStoreW};
    endfunction

    function automatic logic isLoadOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isLoadIns(abs);
    endfunction
    
 
    function automatic logic isMemOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isMemIns(abs);
    endfunction
    
    function automatic logic isSysOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isSysIns(abs);
    endfunction





     class ProgramMemory #(parameter WIDTH = 4);
        typedef Word Line[4];
        
        Word content[1024];
        
        function void setBasicHandlers();
            this.content[IP_RESET/4] = processLines({"ja -512"}).words[0];
            this.content[IP_RESET/4 + 1] = processLines({"ja 0"}).words[0];
            
            this.content[IP_ERROR/4] = processLines({"sys error"}).words[0];
            this.content[IP_ERROR/4 + 1] = processLines({"ja 0"}).words[0];
    
            this.content[IP_CALL/4] = processLines({"sys send"}).words[0];
            this.content[IP_CALL/4 + 1] = processLines({"ja 0"}).words[0];
        endfunction
        
        function void clear();
            this.content = '{default: 'x};
        endfunction
        
        function void setContent(input Word arr[]);
            foreach (arr[i]) this.content[i] = arr[i];
        endfunction

        function void setContentAt(input Word arr[], input Word adr);
            assert((adr % 4) == 0) else $fatal("Unaligned instruction address not allowed");
            foreach (arr[i]) this.content[adr/4 + i] = arr[i];
        endfunction
        
        function Line read(input Word adr);
            Line res;
            Word truncatedAdr = adr & ~(4*WIDTH-1);
            
            foreach (res[i]) res[i] = content[truncatedAdr/4 + i];
            return res;
        endfunction
        
        
    endclass
    
     class DataMemory #(parameter WIDTH = 4);
        typedef logic[7:0] Line[4];
        
        logic[7:0] content[4096];
        
        function void setContent(Word arr[]);
            foreach (arr[i]) this.content[i] = arr[i];
        endfunction
        
        function void clear();
            this.content = '{default: '0};
        endfunction;
        
        function automatic Word read(input Word adr);
            Word res = 0;
            
            for (int i = 0; i < 4; i++) 
                res = (res << 8) + content[adr + i];
            
            return res;
        endfunction

        function automatic void write(input Word adr, input Word value);
            Word data = value;
            
            for (int i = 0; i < 4; i++) begin
                content[adr + i] = data[31:24];
                data <<= 8;
            end        
        endfunction    
        
    endclass




    typedef int InsId;

    typedef struct {
        int id;
        Word adr;
        Word bits;
        Word target;
        Word result;
        int divergence;
    } InstructionInfo;

    function automatic InstructionInfo makeInsInfo(input OpSlot op);
        InstructionInfo res;
        res.id = op.id;
        res.adr = op.adr;
        res.bits = op.bits;
        res.divergence = -1;
        return res;
    endfunction


    class InstructionMap;
        InstructionInfo content[int];
        
        function automatic InstructionInfo get(input int id);
            return content[id];
        endfunction
        
        function automatic int size();
            return content.size();
        endfunction
        

        function automatic void add(input OpSlot op);
            assert (op.active) else $error("Inactive op added to base");
            content[op.id] = makeInsInfo(op);
        endfunction

        function automatic void setEncoding(input OpSlot op);
            assert (op.active) else $error("encoding set for inactive op");
            content[op.id].bits = op.bits;
        endfunction
    
        function automatic void setTarget(input int id, input Word trg);
            content[id].target = trg;
        endfunction
    
        function automatic void setResult(input int id, input Word res);
            content[id].result = res;
        endfunction
    
        function automatic void setDivergence(input int id, input int divergence);
            content[id].divergence = divergence;
        endfunction
        
    endclass




endpackage
