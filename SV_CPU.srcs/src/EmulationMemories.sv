
package EmulationMemories;
    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import EmulationDefs::*;
    

        localparam int TMP_BLOCK_SIZE = 64;

    // 4kB pages
    class PageBasedProgramMemory;
        localparam int PAGE_BYTES = PAGE_SIZE;
        localparam int PAGE_WORDS = PAGE_BYTES/4;
        typedef Word Page[];

        Page pages[int];


        function automatic void setLike(input PageBasedProgramMemory other);
            pages = other.pages; // TODO: pages are copied as references?
        endfunction


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

                if (!hasPage(startAdr)) $fatal(2, "missing page: %x %d", startAdr, startAdr);
            return pages[index];
        endfunction

        function automatic void createPage(input Dword startAdr);
            int index = startAdr/PAGE_BYTES;
            pages[index] = new[PAGE_WORDS]('{default: 'x});
        endfunction

        function automatic void assignPage(input Dword startAdr, input Word arr[]);
            int index = startAdr/PAGE_BYTES;

            //if (!hasPage())

            pages[index] = new[PAGE_WORDS](arr);// arr;
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


        Dword reservations[$];

        Mbyte content[Dword];
        logic usedBlocks[Dword];


        function automatic void clear();
            reservations.delete();
            content.delete();
            usedBlocks.delete();
        endfunction

        function automatic void setLike(input SparseDataMemory other);
            reservations = //new [other.reservations.size()](other.reservations);
                            other.reservations;
            content = other.content;
            usedBlocks = other.usedBlocks;
        endfunction


        function automatic void writeDword(input Dword startAdr, input Dword value);
            Dword baseAdr = TMP_bbase(startAdr);

            clearLock(startAdr);

            usedBlocks[baseAdr] = 1;
            usedBlocks[baseAdr + TMP_BLOCK_SIZE] = 1; // not checking for block cross, just in case assume next block too 

            RW#(Dword, 8)::write(startAdr, value, content);
        endfunction

        function automatic void writeWord(input Dword startAdr, input Word value);
            Dword baseAdr = TMP_bbase(startAdr);

            clearLock(startAdr);

            usedBlocks[baseAdr] = 1;
            usedBlocks[baseAdr + TMP_BLOCK_SIZE] = 1; // not checking for block cross, just in case assume next block too 

            RW#(Word, 4)::write(startAdr, value, content);
        endfunction

        function automatic void writeByte(input Dword startAdr, input Mbyte value);
            Dword baseAdr = TMP_bbase(startAdr);

            clearLock(startAdr);

            usedBlocks[baseAdr] = 1;
            // Not marking next block because one byte can't cross blocks

            RW#(Mbyte, 1)::write(startAdr, value, content);
        endfunction


        function automatic Dword readDword(input Dword startAdr);
            clearLock(startAdr);
            return RW#(Dword, 8)::read(startAdr, content);
        endfunction

        function automatic Word readWord(input Dword startAdr);
            clearLock(startAdr);
            return RW#(Word, 4)::read(startAdr, content);
        endfunction

        function automatic Mbyte readByte(input Dword startAdr);
            clearLock(startAdr);
            return RW#(Mbyte, 1)::read(startAdr, content);
        endfunction


        function automatic void setLock(input Dword adr);
            Dword blockBase = TMP_bbase(adr);
            if (reservations.size() > 0) begin // Let's fail if any reservations
                reservations.delete();
                return;
            end
            reservations.push_back(blockBase);
        endfunction

        function automatic logic getLock(input Dword adr);
            Dword blockBase = TMP_bbase(adr);
            Dword found[$] = reservations.find with (item == blockBase);
            return found.size() > 0;
        endfunction

        function automatic void clearLock(input Dword adr);
            reservations.delete();
        endfunction


        function automatic void writeWordArray(input Dword adr, input Word data[]);
            Dword baseAdr = TMP_bbase(adr);
            int nBlocks = 4*data.size()/TMP_BLOCK_SIZE + 2;  // 1 whole block + 2 bytes can span 3 blocks!
                                                         // So adding 2 to num of whole blocks
            for (int i = 0; i <= nBlocks; i++)
                usedBlocks[baseAdr + i*TMP_BLOCK_SIZE] = 1;

            foreach (data[i])
                RW#(Word, 4)::write(adr + 4*i, data[i], content);
        endfunction

    endclass


    function automatic Dword TMP_bbase(input Dword adr);
        Dword res = adr;
        res[5:0] = 0; // 64b block
        return res;
    endfunction

endpackage
