
package TempMems;

    import Base::*;
    import InsDefs::*;
    import Asm::*;

   
    class ProgramMemory #(parameter WIDTH = 4);
        typedef Word Line[WIDTH];
        
        Word content[4096];
        
        function void clear();
            this.content = '{default: 'x};
        endfunction
        
        function Line read(input Mword adr);
            Line res;
            Mword truncatedAdr = adr & ~(4*WIDTH-1);
            
            foreach (res[i]) res[i] = content[truncatedAdr/4 + i];
            return res;
        endfunction
    
    endclass
    
    
    class DataMemory;        
        Mbyte content[4096];
        
        function void setContent(Mword arr[]);
            foreach (arr[i]) content[i] = arr[i];
        endfunction
        
        function void clear();
            content = '{default: '0};
        endfunction;
        
        function automatic Mword read(input Mword adr);
            Mword res = 0;
            for (int i = 0; i < 4; i++) res = (res << 8) + content[adr + i];
            return res;
        endfunction
    
        function automatic void write(input Mword adr, input Mword value);
            Mword data = value;            
            for (int i = 0; i < 4; i++) begin
                content[adr + i] = data[31:24];
                data <<= 8;
            end        
        endfunction    
        
    endclass

endpackage
