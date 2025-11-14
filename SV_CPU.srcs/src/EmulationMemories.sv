
package EmulationMemories;
    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import EmulationDefs::*;
    


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

        function automatic logic hasPage(input Mword startAdr);
            int index = startAdr/PAGE_BYTES;
            return pages.exists(index);
        endfunction

        function automatic Page getPage(input Mword startAdr);
            int index = startAdr/PAGE_BYTES;
            return pages[index];
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
            
            while (offset < size) begin
                pages[index][offset] = arr[offset];
                offset++;
            end
            
            while (offset < PAGE_WORDS) begin
                pages[index][offset++] = 'x;
            end
        endfunction


        function automatic logic addressValid(input Dword startAdr);
            int index = startAdr/PAGE_BYTES;
            int offset = (startAdr%PAGE_BYTES)/4;
            
            return pages.exists(index);            
        endfunction

        function automatic Word fetch(input Dword startAdr);
            int index = startAdr/PAGE_BYTES;
            int offset = (startAdr%PAGE_BYTES)/4;
            
            assert (pages.exists(index)) else $fatal(2, "Fetch padr nonexistent: %x", startAdr);
            
            return pages[index][offset];
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

    
endpackage
