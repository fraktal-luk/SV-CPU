
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


    //static EmulationWithMems emul = new();
    //static int commitCtr = 0;


//    function static void TMP_reset();
//        emul.resetData();
//        commitCtr = 0;
//        emul.resetCpu();
//    endfunction

//    function static void TMP_commit(input OpSlot op);
//        automatic Word theIp;
//        automatic Word trg = emul.emul.coreState.target;
//        automatic Word bits = fetchInstruction(emul.progMem, trg);
//        commitCtr++;
//        emul.step();
//        emul.writeAndDrain();

//        theIp = emul.emul.ip;

//        if (theIp != op.adr || emul.emul.str != disasm(op.bits)) $display("Mismatched commit: %d: %s;  %d: %s", theIp, emul.emul.str, op.adr, disasm(op.bits));
        
//        assert (trg === op.adr) else $error("Commit: mistached adr %h / %h", trg, op.adr);
//        assert (bits === op.bits) else $error("Commit: mistached enc %h / %h", bits, op.bits);
//    endfunction

//    function static void TMP_interrupt();
//        emul.interrupt();
//    endfunction

//    function static Emulator TMP_getEmul();
//        return emul.emul;
//    endfunction

    typedef Word Ptype[4096];

    Ptype simProgMem;

    function static Ptype TMP_getP();
        //return emul.progMem;
        return simProgMem;
    endfunction

    function static void TMP_setP(input Word p[4096]);
        //emul.progMem = p;
        simProgMem = p;
    endfunction


    function automatic void runInEmulator(ref Emulator emul, input OpSlot op);
        AbstractInstruction ins = decodeAbstract(op.bits);
        ExecResult res = emul.processInstruction(op.adr, ins, emul.tmpDataMem);
    endfunction


    typedef struct {
        Mword target;
        logic redirect;
        logic sig;
        logic wrong;
    } LateEvent;

    const LateEvent EMPTY_LATE_EVENT = '{'x, 0, 0, 0};


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
        
        Word content[4096];
        
        function void clear();
            this.content = '{default: 'x};
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
            foreach (arr[i]) content[i] = arr[i];
        endfunction
        
        function void clear();
            content = '{default: '0};
        endfunction;
        
        function automatic Word read(input Word adr);
            Word res = 0;
            
            for (int i = 0; i < 4; i++) res = (res << 8) + content[adr + i];
            
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
