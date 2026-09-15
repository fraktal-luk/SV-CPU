    
    // import Base::*;
    // import InsDefs::*;
    // import Asm::*;
    // import EmulationDefs::*;
    // import Emulation::*;
    // import UopList::*;
    // import AbstractSim::*;

    // class RegisterTracker #(parameter int N_REGS_INT = 128, parameter int N_REGS_FLOAT = 128);

    //     // FUTURE: move to RegisterDomain after moving functiona for num free etc.
    //     typedef enum {FREE, SPECULATIVE, STABLE
    //     } PhysRegState;
        
    //     typedef struct {
    //         PhysRegState state;
    //         WriterId owner;
    //     } PhysRegInfo;    

    //     class RegisterDomain#(
    //         parameter int N_REGS = N_REGS_INT,
    //         parameter logic IGNORE_R0 = 1
    //     );
    //         localparam PhysRegInfo REG_INFO_FREE = '{state: FREE, owner: WID_NONE};
    //         localparam PhysRegInfo REG_INFO_STABLE = '{state: STABLE, owner: WID_NONE};
    
    //         PhysRegInfo info[N_REGS] = '{0: REG_INFO_STABLE, default: REG_INFO_FREE};        
    //         Mword regs[N_REGS] = '{0: 0, default: 'x};
    //         logic ready[N_REGS] = '{0: 1, default: '0};
            
    //         int MapR[32] = '{default: 0};
    //         int MapC[32] = '{default: 0};
            
    //         WriterId writersR[32] = '{default: WID_NONE};
    //         WriterId writersC[32] = '{default: WID_NONE};
            
    //         function automatic logic ignoreV(input int vReg);
    //             return (vReg == 0) && IGNORE_R0;
    //         endfunction
            
    //         function automatic int reserve(input int vDest, input WriterId id);
    //             int pDest = findFree();

    //             if (!ignoreV(vDest)) begin
    //                 writersR[vDest] = id;
    //                 info[pDest] = '{SPECULATIVE, id};
    //                 MapR[vDest] = pDest;
    //             end
    //             return findDest(id);
    //         endfunction

    //         function automatic void releaseRegister(input int p);                
    //             if (p == 0) return;
    //             info[p] = REG_INFO_FREE;
    //             ready[p] = 0;
    //             regs[p] = 'x;
    //         endfunction

    //         function automatic void commit(input int vDest, input WriterId id, input logic normal);
    //             int ind[$] = info.find_first_index with (item.owner == id);
    //             int pDest = ind[0];
    //             int pDestPrev = MapC[vDest];
 
    //             if (ignoreV(vDest)) return;
                
    //             if (normal) begin
    //                 writersC[vDest] = id;
    //                 MapC[vDest] = pDest;
    //                 info[pDest] = '{STABLE, WID_NONE};
    //                 releaseRegister(pDestPrev);
    //             end
    //             else begin
    //                 releaseRegister(pDest);
    //             end
    //         endfunction

    //         function automatic void setReady(input WriterId id);
    //             int pDest = findDest(id);
    //             ready[pDest] = 1;
    //         endfunction;
    
    //         function automatic void writeValue(input int vDest, input WriterId id, input Mword value);
    //             int pDest = findDest(id);
    //             if (ignoreV(vDest)) return;
    //             regs[pDest] = value;
    //         endfunction            
 
    //         function automatic int findFree();
    //             int res[$] = info.find_first_index with (item.state == FREE);
    //             return res[0];
    //         endfunction
    
    //         function automatic int findDest(input WriterId id);
    //             int inds[$] = info.find_first_index with (item.owner == id);
    //             return inds.size() > 0 ? inds[0] : -1;
    //         endfunction;

    //         function automatic void flush(input InsId id);
    //             int inds[$] = info.find_index with (item.state == SPECULATIVE && U2M(item.owner) > id);

    //             foreach (inds[i]) begin
    //                 int pDest = inds[i];
    //                 info[pDest] = REG_INFO_FREE;
    //                 ready[pDest] = 0;
    //                 regs[pDest] = 'x;
    //             end
    //             // Restoring map is separate
    //         endfunction

    //         function automatic void flushAll();
    //             int inds[$] = info.find_index with (item.state == SPECULATIVE);

    //             foreach (inds[i]) begin
    //                 int pDest = inds[i];
    //                 info[pDest] = REG_INFO_FREE;
    //                 ready[pDest] = 0;
    //                 regs[pDest] = 'x;
    //             end
    //             // Restoring map is separate
    //         endfunction

    //         function automatic void restoreCP(input int intM[32], input WriterId intWriters[32]);
    //             MapR = intM;
    //             writersR = intWriters;
    //         endfunction

    //         function automatic void restoreStable();
    //             MapR = MapC;
    //             writersR = writersC;
    //         endfunction

    //         function automatic void restoreReset();
    //             MapR = MapC;
    //             writersR = '{default: WID_NONE};

    //             foreach (info[i])
    //                 if (info[i].state == STABLE) regs[i] = 0;
    //         endfunction           
    //     endclass

    //     RegisterDomain#(N_REGS_INT, 1) ints = new();
    //     RegisterDomain#(N_REGS_INT, 0) floats = new(); // FUTURE: change to FP reg num

    //     function automatic int reserve(input UopName name, input int dest, input WriterId id);            
    //         if (uopHasIntDest(name)) return ints.reserve(dest, id);
    //         if (uopHasFloatDest(name)) return  floats.reserve(dest, id);
    //         return -1;
    //     endfunction

    //     function automatic void commit(input UopName name, input int dest, input WriterId id, input abnormal);            
    //         if (uopHasIntDest(name)) ints.commit(dest, id, !abnormal);      
    //         if (uopHasFloatDest(name)) floats.commit(dest, id, !abnormal);
    //     endfunction

    //     function automatic void writeValue(input UopName name, input int dest, input WriterId id, input Mword value);
    //         if (uopHasIntDest(name)) begin
    //             ints.setReady(id);
    //             ints.writeValue(dest, id, value);
    //         end
    //         if (uopHasFloatDest(name)) begin
    //             floats.setReady(id);
    //             floats.writeValue(dest, id, value);
    //         end
    //     endfunction


    //     function automatic InsDependencies getArgDeps(input AbstractInstruction abs);
    //         int sources[3] = '{-1, -1, -1};
    //         WriterId producers[3] = '{WID_NONE, WID_NONE, WID_NONE};
    //         SourceType types[3] = '{SRC_CONST, SRC_CONST, SRC_CONST}; 
            
    //         string typeSpec = parsingMap[abs.def.f].typeSpec;
            
    //         foreach (sources[i]) begin
    //             if (typeSpec[i + 2] == "i") begin
    //                 sources[i] = ints.MapR[abs.sources[i]];
    //                 types[i] = sources[i] ? SRC_INT: SRC_ZERO;
    //                 producers[i] = ints.info[sources[i]].owner;
    //             end
    //             else if (typeSpec[i + 2] == "f") begin
    //                 sources[i] = floats.MapR[abs.sources[i]];
    //                 types[i] = SRC_FLOAT;
    //                 producers[i] = floats.info[sources[i]].owner;
    //             end
    //             else if (typeSpec[i + 2] == "c") begin
    //                 sources[i] = abs.sources[i];
    //                 types[i] = SRC_CONST;
    //             end
    //             else if (typeSpec[i + 2] == "0") begin
    //                 sources[i] = 0;
    //                 types[i] = SRC_ZERO;
    //             end
    //         end
    
    //         return '{sources, types, producers};
    //     endfunction

 
    //     function automatic void flush(input InsId id);
    //         ints.flush(id);
    //         floats.flush(id);
    //     endfunction
        
    //     function automatic void flushAll();
    //         ints.flushAll();
    //         floats.flushAll();
    //     endfunction
 
    //     function automatic void restoreCP(input int intM[32], input int floatM[32], input WriterId intWriters[32], input WriterId floatWriters[32]);
    //         ints.restoreCP(intM, intWriters);
    //         floats.restoreCP(floatM, floatWriters);
    //     endfunction
    
    //     function automatic void restoreStable();
    //         ints.restoreStable();
    //         floats.restoreStable();
    //     endfunction

    //     function automatic void restoreReset();
    //         ints.restoreReset();
    //         floats.restoreReset();
    //     endfunction

    //     function automatic int getNumFreeInt();
    //         int freeInds[$] = ints.info.find_index with (item.state == FREE);   
    //         return freeInds.size();
    //     endfunction        
        
    //     function automatic int getNumFreeFloat();
    //         int freeInds[$] = floats.info.find_index with (item.state == FREE);           
    //         return freeInds.size();
    //     endfunction
    // endclass
