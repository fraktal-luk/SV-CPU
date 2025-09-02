
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

module SystemRegisterUnit();

    Mword sysRegs[32];


    task automatic reset();
        sysRegs = SYS_REGS_INITIAL;
    endtask



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
            
            default: $error("Incorrent control op %p", cOp);
        endcase
    endfunction
    
    

    function automatic void saveStateAsync(input Mword prevTarget);
        sysRegs[5] = sysRegs[1];
        sysRegs[3] = prevTarget;

        sysRegs[1] |= 16; // FUTURE: handle state register correctly
        sysRegs[1] &= ~('h00100000); // clear dbstep
    endfunction

endmodule
