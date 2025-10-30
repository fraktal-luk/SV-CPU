
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

module SystemRegisterUnit(output DataCacheOutput readOuts[N_MEM_PORTS], input MemWriteInfo writeReqs[1]);

    Mword sysRegs[32];


    task automatic reset();
        sysRegs = SYS_REGS_INITIAL;
    endtask


    task automatic handleWrite();
        if (writeReqs[0].req) setSysReg(writeReqs[0].adr, writeReqs[0].value);
    endtask

    task automatic handleReads();
        foreach (readOuts[p])
            readOuts[p] <= getSysReadResponse(theExecBlock.accessDescs_E0[p]);
    endtask


    function automatic Mword getReg(input Mword adr);
        assert (isValidSysReg(adr)) else $fatal("Reading incorrect sys reg: adr = %d", adr);
        return sysRegs[adr];
    endfunction
    

    function automatic void setSysReg(input Mword adr, input Mword val);
        assert (isValidSysReg(adr)) else $fatal("Writing incorrect sys reg: adr = %d, val = %d", adr, val);
        sysRegs[adr] = val;
    endfunction
 
 
    function automatic DataCacheOutput getSysReadResponse(input AccessDesc aDesc);
        DataCacheOutput res = EMPTY_DATA_CACHE_OUTPUT;
        Mword regAdr = aDesc.vadr;
        
        if (!aDesc.active || !aDesc.sys) return res;
        
        res.active = 1;
        
        if (!isValidSysReg(regAdr)) begin
            res.status = CR_INVALID;
        end
        else begin
            res.status = CR_HIT;
            res.data = sysRegs[regAdr];
        end
        
        return res;
    endfunction



    function automatic void modifyStateSync(input ControlOp cOp, input Mword adr);
        case (cOp)
            CO_exception, CO_specificException: begin
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr;
                
                sysRegs[1] |= 1; // FUTURE: handle state register correctly
                sysRegs[1] &= ~('h00100000); // clear dbstep
            end
            CO_fetchError: begin
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr;// + 4;
                
                sysRegs[1] |= 1; // FUTURE: handle state register correctly
                sysRegs[1] &= ~('h00100000); // clear dbstep
            end
            CO_undef: begin
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr;// + 4;
                
                sysRegs[1] |= 1; // FUTURE: handle state register correctly
                sysRegs[1] &= ~('h00100000); // clear dbstep
            end
            CO_call: begin                  
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr + 4;
                
                sysRegs[1] |= 1; // FUTURE: handle state register correctly
                sysRegs[1] &= ~('h00100000); // clear dbstep
            end
            CO_dbcall: begin                  
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr + 4;
                
                sysRegs[1] |= 1; // FUTURE: handle state register correctly
                sysRegs[1] &= ~('h00100000); // clear dbstep
            end
            CO_retE: begin
                sysRegs[1] = sysRegs[4];
            end
            CO_retI: begin
                sysRegs[1] = sysRegs[5];
            end
            
            CO_refetch, CO_sync, CO_send: ;
            
            default: $error("Incorrect control op %p", cOp);
        endcase
    endfunction
    
    

    function automatic void saveStateAsync(input Mword prevTarget);
        sysRegs[5] = sysRegs[1];
        sysRegs[3] = prevTarget;

        sysRegs[1] |= 16; // FUTURE: handle state register correctly
        sysRegs[1] &= ~('h00100000); // clear dbstep
    endfunction

    function automatic void setFpInv();
        sysRegs[8][31] = 1;
    endfunction

    function automatic void setFpOv();
        sysRegs[8][30] = 1;
    endfunction

endmodule
