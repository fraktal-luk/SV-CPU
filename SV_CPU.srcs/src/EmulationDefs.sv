
package EmulationDefs;
    import Base::*;
    import InsDefs::*;
    import Asm::*;


    localparam int V_INDEX_BITS = 12;

    function automatic Dword getPageBaseD(input Dword adr);
        Dword res = adr;
        res[V_INDEX_BITS-1:0] = 0;
        return res;
    endfunction

    function automatic Mword getPageBaseM(input Mword adr);
        Mword res = adr;
        res[V_INDEX_BITS-1:0] = 0;
        return res;
    endfunction


            typedef struct {
                logic ok;
                Word w;
            } TMP_FetchResult;


    // 4kB pages
    class PageBasedProgramMemory;
        localparam int PAGE_BYTES = PAGE_SIZE;
        localparam int PAGE_WORDS = PAGE_BYTES/4;
        typedef Word Page[];

        Page pages[int];


        function automatic void resetPage(input Dword startAdr);
            int index = startAdr/PAGE_BYTES;
            pages[index] = '{default: 'x};
        endfunction

        function automatic void createPage(input Dword startAdr);
            int index = startAdr/PAGE_BYTES;
            pages[index] = new[PAGE_WORDS]('{default: 'x});
        endfunction

        function automatic void assignPage(input Dword startAdr, input Word arr[]);
            int index = startAdr/PAGE_BYTES;
            pages[index] = arr;
        endfunction

        function automatic void writePage(input Dword startAdr, input Word arr[]);
            int index = startAdr/PAGE_BYTES;
            int size = arr.size() < PAGE_WORDS ? arr.size() : PAGE_WORDS;
            int offset = 0;
            
                           // $error(" >> %d, %x", arr.size(), arr[0]);

            
            while (offset < size) begin
                pages[index][offset] = arr[offset];
                offset++;
            end
                           //     $error("[[%x, %x...]]", pages[index][0], pages[index][1]);

            
            while (offset < PAGE_WORDS) begin
                pages[index][offset++] = 'x;
            end
                  //  $error("[[%x, %x...]]", pages[index][0], pages[index][1]);
        endfunction
        
            function automatic Word fetch(input Dword startAdr);
                int index = startAdr/PAGE_BYTES;
                int offset = (startAdr%PAGE_BYTES)/4;
                
                return pages[index][offset];
            endfunction
    
    

        function automatic TMP_FetchResult fetch_N(input Dword startAdr);
            int index = startAdr/PAGE_BYTES;
            int offset = (startAdr%PAGE_BYTES)/4;
            
            if (!pages.exists(index)) return '{0, 'x};
            
            return '{1, pages[index][offset]};
        endfunction
       
        
        function automatic Page getPage(input Mword startAdr);
            int index = startAdr/PAGE_BYTES;
            return pages[index];
        endfunction
    endclass



    class SparseDataMemory;
        
        class RW#(type Elem = Mbyte, int ESIZE = 1);
            static
            function automatic void write(input Dword startAdr, input Elem value, ref Mbyte ct[Dword]);
                Mbyte bytes[ESIZE] = {>>{value}};
                foreach (bytes[i]) ct[startAdr+i] = bytes[i];
            endfunction
            
            static
            function automatic Elem read(input Dword startAdr, ref Mbyte ct[Dword]);
                Mbyte bytes[ESIZE];
                foreach (bytes[i]) bytes[i] = ct.exists(startAdr+i) ? ct[startAdr+i] : 0;
                return {>>{bytes}};
            endfunction     
        endclass
        
        
        Mbyte content[Dword];
        
        function automatic void clear();
            content.delete();
        endfunction
        
        
        function automatic void writeWord(input Dword startAdr, input Word value);
            RW#(Word, 4)::write(startAdr, value, content);
        endfunction

        function automatic void writeByte(input Dword startAdr, input Mbyte value);
            RW#(Mbyte, 1)::write(startAdr, value, content);
        endfunction


        function automatic Word readWord(input Dword startAdr);
            return RW#(Word, 4)::read(startAdr, content);
        endfunction

        function automatic Mbyte readByte(input Dword startAdr);
            return RW#(Mbyte, 1)::read(startAdr, content);
        endfunction
       
    endclass



   
    // Not including memory
    function automatic logic isFloatCalcIns(input AbstractInstruction ins);
        return ins.def.o inside { O_floatMove, O_floatOr, O_floatAddInt };
    endfunction    


    function automatic logic isBranchIns(input AbstractInstruction ins);
        return ins.def.o inside {O_jump};
    endfunction

    function automatic logic isBranchImmIns(input AbstractInstruction ins);
        return ins.mnemonic inside {"ja", "jl", "jz_i", "jnz_i"};
    endfunction

    function automatic logic isBranchAlwaysIns(input AbstractInstruction ins);
        return ins.mnemonic inside {"ja", "jl"};
    endfunction

    function automatic logic isBranchRegIns(input AbstractInstruction ins);
        return ins.mnemonic inside {"jz_r", "jnz_r"};
    endfunction       
        

    function automatic logic isMemIns(input AbstractInstruction ins);
        return ins.def.o inside {O_intLoadW, O_intLoadD, O_intStoreW, O_intStoreD, O_floatLoadW, O_floatStoreW,  O_intLoadB,  O_intStoreB,  O_intLoadAqW, O_intStoreRelW};
    endfunction
    
    function automatic logic isSysIns(input AbstractInstruction ins); // excluding sys load
        return ins.def.o inside {O_undef,   O_error,  O_call, O_sync, O_retE, O_retI, O_replay, O_halt, O_send,     O_sysStore};
    endfunction

    function automatic logic isLoadIns(input AbstractInstruction ins);
        return isLoadMemIns(ins) || isLoadSysIns(ins);
    endfunction

    function automatic logic isLoadSysIns(input AbstractInstruction ins);
        return (ins.def.o inside {O_sysLoad});
    endfunction

    function automatic logic isLoadMemIns(input AbstractInstruction ins);
        return (ins.def.o inside {O_intLoadW, O_intLoadD, O_floatLoadW,    O_intLoadB,   O_intLoadAqW});
    endfunction

    function automatic logic isFloatLoadMemIns(input AbstractInstruction ins);
        return (ins.def.o inside {O_floatLoadW});
    endfunction

    function automatic logic isStoreMemIns(input AbstractInstruction ins);
        return ins.def.o inside {O_intStoreW, O_intStoreD, O_floatStoreW,    O_intStoreB,   O_intStoreRelW};
    endfunction

    function automatic logic isFloatStoreMemIns(input AbstractInstruction ins);
        return ins.def.o inside {O_floatStoreW};
    endfunction
    

    function automatic logic isStoreSysIns(input AbstractInstruction ins);
        return ins.def.o inside {O_sysStore};
    endfunction
    
    function automatic logic isStoreIns(input AbstractInstruction ins);
        return isStoreMemIns(ins) || isStoreSysIns(ins);
    endfunction


    function automatic bit hasIntDest(input AbstractInstruction ins);
        return ins.def.o inside {
            O_jump,
            
            O_intAnd,
            O_intOr,
            O_intXor,
            
            O_intAdd,
            O_intSub,
            O_intAddH,
            
                O_intCmpGtU,
                O_intCmpGtS,
            
            O_intMul,
            O_intMulHU,
            O_intMulHS,
            O_intDivU,
            O_intDivS,
            O_intRemU,
            O_intRemS,
            
            O_intShiftLogical,
            O_intShiftArith,
            O_intRotate,
            
            O_intLoadW,
            O_intLoadD,
                
                O_intLoadB,
                
                O_intLoadAqW,
                O_intStoreRelW,
            
            O_sysLoad
        };
    endfunction

    function automatic bit hasFloatDest(input AbstractInstruction ins);
        return ins.def.o inside {
            O_floatMove,
            O_floatOr, O_floatAddInt,
            O_floatLoadW
        };
    endfunction



    function automatic Mword getArgValue(input Mword intRegs[32], input Mword floatRegs[32], input int src, input byte spec);
        case (spec)
           "i": return (intRegs[src]);
           "f": return (floatRegs[src]);
           "c": return Mword'(src);
           "0": return 0;
           default: $fatal("Wrong arg spec");    
        endcase;    
    
    endfunction

    function automatic Mword3 getArgs(input Mword intRegs[32], input Mword floatRegs[32], input int sources[3], input string typeSpec);
        Mword3 res;        
        foreach (sources[i]) res[i] = getArgValue(intRegs, floatRegs, sources[i], typeSpec[i+2]);
        
        return res;
    endfunction


   function automatic Mword calculateResult(input AbstractInstruction ins, input Mword3 vals, input Mword ip);
        Mword result;
        case (ins.def.o)            
            O_intAnd:  result = vals[0] & vals[1];
            O_intOr:   result = vals[0] | vals[1];
            O_intXor:  result = vals[0] ^ vals[1];
            
            O_intAdd:  result = vals[0] + vals[1];
            O_intSub:  result = vals[0] - vals[1];
            O_intAddH: result = vals[0] + (vals[1] << 16);
            
                O_intCmpGtU:  result = $unsigned(vals[0]) > $unsigned(vals[1]);
                O_intCmpGtS:  result = $signed(vals[0]) > $signed(vals[1]);
            
            O_intMul:   result = vals[0] * vals[1];
            O_intMulHU: result = (Dword'($unsigned(vals[0])) * Dword'($unsigned(vals[1]))) >> 32;
            O_intMulHS: result = (Dword'($signed(vals[0])) * Dword'($signed(vals[1]))) >> 32;
            O_intDivU:  result = divUnsignedW(vals[0], vals[1]);//$unsigned(vals[0]) / $unsigned(vals[1]);
            O_intDivS:  result = divSignedW(vals[0], vals[1]);
            O_intRemU:  result = remUnsignedW(vals[0], vals[1]);//$unsigned(vals[0]) % $unsigned(vals[1]);
            O_intRemS:  result = remSignedW(vals[0], vals[1]);
            
            O_intShiftLogical: begin                
                if ($signed(vals[1]) >= 0) result = $unsigned(vals[0]) << vals[1];
                else                       result = $unsigned(vals[0]) >> -vals[1];
            end
            O_intShiftArith: begin                
                if ($signed(vals[1]) >= 0) result = $signed(vals[0]) << vals[1];
                else                       result = $signed(vals[0]) >> -vals[1];
            end
            O_intRotate: begin
                if ($signed(vals[1]) >= 0) result = {vals[0], vals[0]} << vals[1];
                else                       result = {vals[0], vals[0]} >> -vals[1];
            end
            
            O_floatMove: result = vals[0];

            O_floatOr:   result = vals[0] | vals[1];
            O_floatAddInt: result = vals[0] + vals[1];

            default: ;
        endcase
        
        // Some operations may have undefined cases but must not cause problems for the CPU
        if ((ins.def.o inside {O_intDivU, O_intDivS, O_intRemU, O_intRemS}) && $isunknown(result)) result = -1;
        
        return result;
    endfunction


    function automatic Mword calculateEffectiveAddress(input AbstractInstruction ins, input Mword3 vals);
        return (ins.def.o inside {O_sysLoad, O_sysStore}) ? vals[1] : vals[0] + vals[1];
    endfunction



    typedef struct {
       Mword target;
       logic redirect;
    } ExecEvent;


    function automatic ExecEvent resolveBranch(input AbstractInstruction abs, input Mword adr, input Mword3 vals);
        Mword3 args = vals;
        bit redirect = 0;
        Mword brTarget = (abs.mnemonic inside {"jz_r", "jnz_r"}) ? args[1] : adr + args[1];

        case (abs.mnemonic)
            "ja", "jl": redirect = 1;
            "jz_i": redirect = (args[0] == 0);
            "jnz_i": redirect = (args[0] != 0);
            "jz_r": redirect = (args[0] == 0);
            "jnz_r": redirect = (args[0] != 0);
            default: ;
        endcase

        return '{brTarget, redirect};
    endfunction


    typedef enum {
        PE_NONE = 0,
        
        PE_FETCH_INVALID_ADDRESS = 16 + 0,
        PE_FETCH_UNALIGNED_ADDRESS = 16 + 1,
        PE_FETCH_TLB_MISS = 16 + 2, // HW
        PE_FETCH_UNMAPPED_ADDRESS = 16 + 3,
        PE_FETCH_DISALLOWED_ACCESS = 16 + 4,
        PE_FETCH_UNCACHED = 16 + 5, // HW
        PE_FETCH_CACHE_MISS = 16 + 6, // HW
        PE_FETCH_NONEXISTENT_ADDRESS = 16 + 7,

        PE_MEM_INVALID_ADDRESS = 3*16 + 0,
        PE_MEM_UNALIGNED_ADDRESS = 3*16 + 1, // when crossing blocks/pages
        PE_MEM_TLB_MISS = 3*16 + 2, // HW
        PE_MEM_UNMAPPED_ADDRESS = 3*16 + 3,
        PE_MEM_DISALLOWED_ACCESS = 3*16 + 4,
        PE_MEM_UNCACHED = 3*16 + 5, // HW
        PE_MEM_CACHE_MISS = 3*16 + 6, // HW
        PE_MEM_NONEXISTENT_ADDRESS = 3*16 + 7,
        
        PE_SYS_INVALID_ADDRESS = 5*16 + 0,
        PE_SYS_DISALLOWED_ACCESS = 5*16 + 1,
        PE_SYS_UNDEFINED_INSTRUCTION = 5*16 + 2,
        PE_SYS_ERROR = 5*16 + 3,
        PE_SYS_CALL = 5*16 + 4,
        PE_SYS_DISABLED_INSTRUCTION = 5*16 + 5, // FP op when SIMD off, etc
        
        FP_EXT_INTERRUPT = 6*16 + 0,
        FP_EXT_RESET = 6*16 + 1,
        FP_EXT_DEBUG = 6*16 + 2

    } ProgramEvent;

        // TODO: change to dependent on Mword size?
        localparam Mword VADR_LIMIT_LOW =  'h01000000;
        localparam Mword VADR_LIMIT_HIGH = 'hff000000;

        localparam Dword PADR_LIMIT = 'h10000000000;

    // For fetch
    function automatic logic virtualAddressValid(input Mword vadr);
        return !$isunknown(vadr) && ($signed(vadr) < $signed(VADR_LIMIT_LOW)) && ($signed(vadr) >= $signed(VADR_LIMIT_HIGH));
    endfunction

    function automatic logic physicalAddressValid(input Dword padr);
        return !$isunknown(padr) && ($unsigned(padr) < $unsigned(PADR_LIMIT));
    endfunction

endpackage
