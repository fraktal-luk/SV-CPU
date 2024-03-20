
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


    typedef Word Ptype[4096];

    Ptype simProgMem;

    function static Ptype TMP_getP();
        return simProgMem;
    endfunction

    function static void TMP_setP(input Word p[4096]);
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
        //return abs.def.o inside {O_intStoreW, O_intStoreD, O_floatStoreW};
        return isStoreMemIns(abs);
    endfunction

    function automatic logic isLoadMemOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isLoadMemIns(abs);
    endfunction

    function automatic logic isLoadOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isLoadIns(abs);
    endfunction

    function automatic logic isStoreOp(input OpSlot op);
        AbstractInstruction abs = decodeAbstract(op.bits);
        return isStoreIns(abs);
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

    typedef enum { SRC_ZERO, SRC_CONST, SRC_INT, SRC_FLOAT
    } SourceType;
    
    typedef struct {
        int sources[3];
        SourceType types[3];
    } InsDependencies;


    typedef struct {
        int rename;
        int bq;
        int lq;
        int sq;
    } IndexSet;


    typedef struct {
        int id;
        Word adr;
        Word bits;
        Word target;
        Word result;
        //int renameIndex;
        IndexSet inds;
        int divergence;
        InsDependencies deps;
        
        Word argValues[3];
    } InstructionInfo;

    function automatic InstructionInfo makeInsInfo(input OpSlot op);
        InstructionInfo res;
        res.id = op.id;
        res.adr = op.adr;
        res.bits = op.bits;
        
        //res.renameIndex = -1;
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

        function automatic void setDeps(input int id, input InsDependencies deps);
            content[id].deps = deps;
        endfunction
        
        function automatic void setInds(input int id, input IndexSet indexSet);
            content[id].inds = indexSet;
        endfunction
        
        function automatic void setArgValues(input int id, input Word vals[3]);
            content[id].argValues = vals;
        endfunction
    endclass




    class BranchCheckpoint;
    
        function new(input OpSlot op, input CpuState state, input SimpleMem mem, 
                        input int intWr[32], input int floatWr[32],
                        input int intMapR[32], input int floatMapR[32],
                        //input int renameInd, 
                        input IndexSet indexSet);
            this.op = op;
            this.state = state;
            this.mem = new();
            this.mem.copyFrom(mem);
            this.intWriters = intWr;
            this.floatWriters = floatWr;
            this.intMapR = intMapR;
            this.floatMapR = floatMapR;
            //this.renameIndex = renameInd;
            this.inds = indexSet;
        endfunction

        OpSlot op;
        CpuState state;
        SimpleMem mem;
        int intWriters[32];
        int floatWriters[32];
        int intMapR[32];
        int floatMapR[32];
        //int renameIndex;
        IndexSet inds;
    endclass


    typedef logic logic3[3];


    class RegisterTracker #(parameter int N_REGS_INT = 128, parameter int N_REGS_FLOAT = 128);
        typedef enum {FREE, SPECULATIVE, STABLE
        } PhysRegState;
        
        typedef struct {
            PhysRegState state;
            InsId owner;
        } PhysRegInfo;

        const PhysRegInfo REG_INFO_FREE = '{state: FREE, owner: -1};
        const PhysRegInfo REG_INFO_STABLE = '{state: STABLE, owner: -1};

        PhysRegInfo intInfo[N_REGS_INT] = '{0: REG_INFO_STABLE, default: REG_INFO_FREE};        
        Word intRegs[N_REGS_INT] = '{0: 0, default: 'x};
        logic intReady[N_REGS_INT] = '{0: 1, default: '0};
        
        PhysRegInfo floatInfo[N_REGS_INT] = '{0: REG_INFO_STABLE, default: REG_INFO_FREE};        
        Word floatRegs[N_REGS_INT] = '{0: 0, default: 'x};
        logic floatReady[N_REGS_INT] = '{0: 1, default: '0};
        
        
        int intMapR[32] = '{default: 0};
        int intMapC[32] = '{default: 0};
        
        int floatMapR[32] = '{default: 0};
        int floatMapC[32] = '{default: 0};
 
       
        function automatic int findDestInt(input InsId id);
            int inds[$] = intInfo.find_first_index with (item.owner == id);
            return inds.size() > 0 ? inds[0] : -1;
        endfunction;

        function automatic void setReadyInt(input InsId id);
            int pDest = findDestInt(id);
            intReady[pDest] = 1;
        endfunction;

        function automatic void reserveInt(input OpSlot op);
            AbstractInstruction ins = decodeAbstract(op.bits);
            int vDest = ins.dest;
            int pDest = findFreeInt();
            
            if (!writesIntReg(op) || vDest == 0) return;
            
            intInfo[pDest] = '{SPECULATIVE, op.id};
            intMapR[vDest] = pDest;
        endfunction


        function automatic int findDestFloat(input InsId id);
            int inds[$] = floatInfo.find_first_index with (item.owner == id);
            return inds.size() > 0 ? inds[0] : -1;
        endfunction;

        function automatic void setReadyFloat(input InsId id);
            int pDest = findDestFloat(id);
            floatReady[pDest] = 1;
        endfunction;

        function automatic void reserveFloat(input OpSlot op);
            AbstractInstruction ins = decodeAbstract(op.bits);
            int vDest = ins.dest;
            int pDest = findFreeFloat();
            
            if (!writesFloatReg(op)) return;
            
            floatInfo[pDest] = '{SPECULATIVE, op.id};
            floatMapR[vDest] = pDest;
        endfunction

        
        function automatic void commitInt(input OpSlot op);
            AbstractInstruction ins = decodeAbstract(op.bits);
            int vDest = ins.dest;
            int ind[$] = intInfo.find_first_index with (item.owner == op.id);
            int pDest = ind[0];
            int pDestPrev = intMapC[vDest];
            
            if (!writesIntReg(op) || vDest == 0) return;
            
            intInfo[pDest] = '{STABLE, -1};
            intMapC[vDest] = pDest;
            if (pDestPrev == 0) return; 
            intInfo[pDestPrev] = REG_INFO_FREE;
            intReady[pDestPrev] = 0;
            intRegs[pDestPrev] = 'x;
        endfunction
        
        
        function automatic int findFreeInt();
            int res[$] = intInfo.find_first_index with (item.state == FREE);
            return res[0];
        endfunction
        

        
        function automatic void commitFloat(input OpSlot op);
            AbstractInstruction ins = decodeAbstract(op.bits);
            int vDest = ins.dest;
            int ind[$] = floatInfo.find_first_index with (item.owner == op.id);
            int pDest = ind[0];
            int pDestPrev = floatMapC[vDest];
            
            if (!writesFloatReg(op)) return;
            
            floatInfo[pDest] = '{STABLE, -1};
            floatMapC[vDest] = pDest;
            if (pDestPrev == 0) return;
            floatInfo[pDestPrev] = REG_INFO_FREE;
            floatReady[pDestPrev] = 0;
            floatRegs[pDestPrev] = 'x;
        endfunction
        
        
        function automatic int findFreeFloat();
            int res[$] = floatInfo.find_first_index with (item.state == FREE);
            return res[0];
        endfunction
   
        
        
        function automatic void flush(input OpSlot op);
            //AbstractInstruction ins = decodeAbstract(op.bits);

            int indsInt[$] = intInfo.find_index with (item.state == SPECULATIVE && item.owner > op.id);
            int indsFloat[$] = floatInfo.find_index with (item.state == SPECULATIVE && item.owner > op.id);

            foreach (indsInt[i]) begin
                int pDest = indsInt[i];
                intInfo[pDest] = REG_INFO_FREE;
                intReady[pDest] = 0;
                intRegs[pDest] = 'x;
            end

            foreach (indsFloat[i]) begin
                int pDest = indsFloat[i];
                floatInfo[pDest] = REG_INFO_FREE;
                floatReady[pDest] = 0;
                floatRegs[pDest] = 'x;
            end          
            
            // Restoring map is separate
        endfunction
        
        function automatic void flushAll();
            //int vDest = ins.dest;
            int indsInt[$] = intInfo.find_index with (item.state == SPECULATIVE);
            int indsFloat[$] = floatInfo.find_index with (item.state == SPECULATIVE);

            foreach (indsInt[i]) begin
                int pDest = indsInt[i];
                intInfo[pDest] = REG_INFO_FREE;
                intReady[pDest] = 0;
                intRegs[pDest] = 'x;
            end
             
            foreach (indsFloat[i]) begin
                int pDest = indsFloat[i];
                floatInfo[pDest] = REG_INFO_FREE;
                floatReady[pDest] = 0;
                floatRegs[pDest] = 'x;
            end
            
            // Restoring map is separate
        endfunction
 
        function automatic void restore(input int intM[32], input int floatM[32]);
            intMapR = intM;
            floatMapR = floatM;
        endfunction
        
        
        function automatic void writeValueInt(input OpSlot op, input Word value);
            //AbstractInstruction ins = decodeAbstract(op.bits);
            int pDest = findDestInt(op.id);
            if (!writesIntReg(op) || ins.dest == 0) return;
            
            intRegs[pDest] = value;
        endfunction
        
        function automatic void writeValueFloat(input OpSlot op, input Word value);
            //AbstractInstruction ins = decodeAbstract(op.bits);
            int pDest = findDestFloat(op.id);
            if (!writesFloatReg(op)) return;
            
            floatRegs[pDest] = value;
        endfunction     
        
        
        function automatic int getNumFreeInt();
            int freeInds[$] = intInfo.find_index with (item.state == FREE);
            int specInds[$] = intInfo.find_index with (item.state == SPECULATIVE);
            int stabInds[$] = intInfo.find_index with (item.state == STABLE);            
            return freeInds.size();
        endfunction 
        
        function automatic int getNumSpecInt();
            int specInds[$] = intInfo.find_index with (item.state == SPECULATIVE);            
            return specInds.size();
        endfunction 

        function automatic int getNumStabInt();
            int stabInds[$] = intInfo.find_index with (item.state == STABLE);            
            return stabInds.size();
        endfunction
        
        
        function automatic int getNumFreeFloat();
            int freeInds[$] = floatInfo.find_index with (item.state == FREE);
            int specInds[$] = floatInfo.find_index with (item.state == SPECULATIVE);
            int stabInds[$] = floatInfo.find_index with (item.state == STABLE);            
            return freeInds.size();
        endfunction
        
        
        function automatic logic3 checkArgsReady(input InsDependencies deps);//, input logic readyInt[N_REGS_INT], input logic readyFloat[N_REGS_FLOAT]);
            logic3 res;
            foreach (deps.types[i])
                case (deps.types[i])
                    SRC_ZERO:  res[i] = 1;
                    SRC_CONST: res[i] = 1;
                    SRC_INT:   res[i] = intReady[deps.sources[i]];
                    SRC_FLOAT: res[i] = floatReady[deps.sources[i]];
                endcase      
            return res;
        endfunction
    endclass






    function automatic InsDependencies getPhysicalArgs(input OpSlot op, input int mapInt[32], input int mapFloat[32]);
        int sources[3] = '{-1, -1, -1};
        SourceType types[3] = '{SRC_CONST, SRC_CONST, SRC_CONST}; 
        
        AbstractInstruction abs = decodeAbstract(op.bits);
        string typeSpec = parsingMap[abs.fmt].typeSpec;
        
        foreach (sources[i]) begin
            if (typeSpec[i + 2] == "i") begin
                sources[i] = mapInt[abs.sources[i]];
                types[i] = SRC_INT;
            end
            else if (typeSpec[i + 2] == "f") begin
                sources[i] = mapFloat[abs.sources[i]];
                types[i] = SRC_FLOAT;
            end
            else if (typeSpec[i + 2] == "c") begin
                sources[i] = abs.sources[i];
                types[i] = SRC_CONST;
            end
            else if (typeSpec[i + 2] == "0") begin
                sources[i] = //abs.sources[i];
                            0;
                types[i] = SRC_ZERO;
            end
        end

        return '{sources, types};
    endfunction

        function automatic Word3 getArgValues(input RegisterTracker tracker, input InsDependencies deps);
            Word res[3];
            foreach (res[i]) begin
                case (deps.types[i])
                    SRC_ZERO: res[i] = 0;
                    SRC_CONST: res[i] = deps.sources[i];
                    SRC_INT: res[i] = tracker.intRegs[deps.sources[i]];
                    SRC_FLOAT: res[i] = tracker.floatRegs[deps.sources[i]];
                endcase
            end
    
            return res;
        endfunction

    typedef struct {
        logic req;
        Word adr;
        Word value;
    } MemWriteInfo;
    
    const MemWriteInfo EMPTY_WRITE_INFO = '{0, 'x, 'x};
    
    typedef struct {
        OpSlot op;
        logic redirect;
        Word target;
    } EventInfo;
    
    const EventInfo EMPTY_EVENT_INFO = '{EMPTY_SLOT, 0, 'x};

    
        typedef struct {
            InsId owner;
            Word adr;
            Word val;
        } Transaction;


        class MemTracker;
            Transaction transactions[$];
            Transaction stores[$];
            Transaction loads[$];
            
//            function automatic void reset();

//            endfunction
            
            function automatic void addStore(input OpSlot op, input Word adr, input Word val);
                transactions.push_back('{op.id, adr, val});
                stores.push_back('{op.id, adr, val});
            endfunction

            function automatic void addLoad(input OpSlot op, input Word adr, input Word val);
                    InsId wrId;
            
                transactions.push_back('{op.id, adr, val});
                loads.push_back('{op.id, adr, val});
                
//                if (0) begin
//                    wrId = checkWriter(op);
//                    if (wrId != -1) $display("Potential forward %d -> %d \n      %d: %s;  %d %s", wrId, op.id,
//                            insMap.get(wrId).adr, disasm(insMap.get(wrId).bits),
//                            insMap.get(op.id).adr, disasm(insMap.get(op.id).bits));
//                end
            endfunction

            function automatic void remove(input OpSlot op);
                assert (transactions[0].owner == op.id) begin
                    transactions.pop_front();
                    if (stores.size() != 0 && stores[0].owner == op.id) stores.pop_front();
                    if (loads.size() != 0 && loads[0].owner == op.id) loads.pop_front();
                end
                else $error("Incorrect transaction commit");
            endfunction
            
            function automatic void flushAll();
                transactions.delete();
                stores.delete();
                loads.delete();
            endfunction

            function automatic void flush(input OpSlot op);
                while (transactions.size() != 0 && transactions[$].owner > op.id) transactions.pop_back();
                while (stores.size() != 0 && stores[$].owner > op.id) stores.pop_back();
                while (loads.size() != 0 && loads[$].owner > op.id) loads.pop_back();
            endfunction   
            
            // Find which op is the source of data
            function automatic InsId checkWriter(input OpSlot op);
                Transaction read[$] = transactions.find_first with (item.owner == op.id); 
                Transaction writers[$] = stores.find with (item.adr == read[0].adr && item.owner < op.id);
                return (writers.size() == 0) ? -1 : writers[$].owner;
            endfunction
            
        endclass
    

endpackage
