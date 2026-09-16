

package MemoryLogic;

    import Base::*;
    import InsDefs::*;
    import Asm::*;

    import EmulationDefs::*;
    import Emulation::*;

    import AbstractSim::*;
    import Insmap::*;

    import UopList::*;

    import ExecDefs::*;


        function automatic logic memOverlap(input Dword wa, input AccessSize sizeA, input Dword wb, input AccessSize sizeB);
            Dword aEnd = wa + Dword'(sizeA); // Exclusive end
            Dword bEnd = wb + Dword'(sizeB); // Exclusive end
            
            if ($isunknown(wa) || $isunknown(wb)) return 0;
            return (wa < bEnd && wb < aEnd);
        endfunction
        
        // is a inside b
        function automatic logic memInside(input Dword wa, input AccessSize sizeA, input Dword wb, input AccessSize sizeB);
            Dword aEnd = wa + Dword'(sizeA); // Exclusive end
            Dword bEnd = wb + Dword'(sizeB); // Exclusive end
            
            if ($isunknown(wa) || $isunknown(wb)) return 0;
            return (wa >= wb && aEnd <= bEnd);
        endfunction



        // Only MemModules
        function automatic Translation translateAddress(input AccessDesc aDesc, input Translation tq[$], input logic MMU_EN);    
            Mword adr = aDesc.info.vadr;
            Translation res = DEFAULT_TRANSLATION;
            Translation found[$];

            if (!aDesc.active || $isunknown(adr)) return DEFAULT_TRANSLATION;
            if (!MMU_EN) return '{present: 1, vadr: adr, desc: '{1, 1, 1, 1, 0}, padr: adr};

            found = tq.find with (item.vadr == getPageBaseM(adr));

            assert (found.size() <= 1) else $fatal(2, "multiple hit in tlb\n%p", tq);

            if (found.size() == 0) begin
                res.vadr = adr; // It's needed because TLB fill is based on this adr
                return res;
            end

            res = found[0];

            res.vadr = adr;
            res.padr = res.padr + (adr - getPageBaseM(adr));

            return res;
        endfunction



            // Only MemSubpipe
        function automatic Mword loadValue(input Mword w, input UopName uop);
            case (uop)
                UOP_mem_ldi: return $signed(Word'(w));
                UOP_mem_ldid: return w;
                UOP_mem_ldib: return Mword'(w[7:0]);
                UOP_mem_ldf: return (w);
                UOP_mem_ldfd: return w;
                UOP_mem_lds: return w;
                
                UOP_mem_lda: return w;

                UOP_mem_sti,
                UOP_mem_stid,
                UOP_mem_stib,
                UOP_mem_stf,
                UOP_mem_stfd,
                UOP_mem_sts: return 0;

                UOP_mem_stc: return 0;

                default: $fatal(2, "Wrong op");
            endcase
        endfunction

            // Only MemSubpipe
        // @endian
        function automatic Mword combineLoadValues(input Mword saved, input Mword w, input int shift, input UopName uop);
            Dword cw = w; // combined word
            Dword shifted = w << 8*(8-shift);

            foreach (cw[i]) begin
                if (saved[i] === 'x) cw[i] = shifted[i];
                else cw[i] = saved[i];
            end

            return loadValue(cw, uop);
        endfunction




endpackage
