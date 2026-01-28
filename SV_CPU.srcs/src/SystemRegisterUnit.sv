
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



    function automatic void modifyStateSync(input ControlOp cOp, input Mword adr, input AccessDesc ad, input Translation tr, input UopPacket p);
        case (cOp)
            CO_exception, CO_specificException: begin
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr;
                
                sysRegs[1] |= 1; // FUTURE: handle state register correctly
                sysRegs[1] &= ~('h00100000); // clear dbstep

                // TODO: assign precise values
                case (p.status)
                    ES_ILLEGAL: begin
                        UopName uname = decUname(p.TMP_oid);
                        if (isMemUop(uname)) sysRegs[6] = PE_MEM_DISALLOWED_ACCESS;
                        else if (isStoreSysUop(uname) || isLoadSysUop(uname)) sysRegs[6] = PE_MEM_DISALLOWED_ACCESS;

                    end

                    ES_FP_INVALID, ES_FP_OVERFLOW:
                        sysRegs[6] = PE_ARITH_EXCEPTION;

                    default: ;
                endcase
            end
            CO_fetchError: begin
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr;// + 4;
                
                sysRegs[1] |= 1; // FUTURE: handle state register correctly
                sysRegs[1] &= ~('h00100000); // clear dbstep

                begin
                    sysRegs[6] = PE_FETCH_INVALID_ADDRESS;
                end
            end
            CO_undef: begin
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr;// + 4;
                
                sysRegs[1] |= 1; // FUTURE: handle state register correctly
                sysRegs[1] &= ~('h00100000); // clear dbstep
                
                begin
                    sysRegs[6] = PE_SYS_UNDEFINED_INSTRUCTION;
                end
            end
            CO_call: begin                  
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr + 4;
                
                sysRegs[1] |= 1; // FUTURE: handle state register correctly
                sysRegs[1] &= ~('h00100000); // clear dbstep

                begin
                    sysRegs[6] = PE_SYS_CALL;
                end
            end
            CO_dbcall: begin                  
                sysRegs[4] = sysRegs[1];
                sysRegs[2] = adr + 4;
                
                sysRegs[1] |= 1; // FUTURE: handle state register correctly
                sysRegs[1] &= ~('h00100000); // clear dbstep

                begin
                    sysRegs[6] = PE_SYS_DBCALL;
                end
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
    

    function automatic void saveStateAsync(input Mword prevTarget, input ControlOp cop);
        sysRegs[5] = sysRegs[1];
        sysRegs[3] = prevTarget;

        sysRegs[1] |= 16; // FUTURE: handle state register correctly
        sysRegs[1] &= ~('h00100000); // clear dbstep

        case (cop)
            CO_reset: sysRegs[7] = PE_EXT_RESET;
            CO_int: sysRegs[7] = PE_EXT_INTERRUPT;
            CO_break: sysRegs[7] = PE_EXT_DEBUG;
            default: ;
        endcase
    endfunction

    function automatic void setFpInv();
        sysRegs[8][31] = 1;
    endfunction

    function automatic void setFpOv();
        sysRegs[8][30] = 1;
    endfunction

endmodule
