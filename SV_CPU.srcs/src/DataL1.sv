
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;


module DataL1(
                input logic clk,
                
                input DataReadReq readReqs[N_MEM_PORTS],
                output DataReadResp readResps[N_MEM_PORTS],
                
                input logic writeReqs[2],
                input Word writeAddresses[2],
                input Word writeData[2]
              );


    int tagsForWay[BLOCKS_PER_WAY] = '{default: 0}; // tags for each block of way 0

    Mbyte content[4096]; // So far this corresponds to way 0


    typedef struct {
        EffectiveAddress adr;
        int accessSize;
        VirtualAddressHigh aHigh;
        VirtualAddressLow aLow;
        int block;
        int blockOffset;
        logic blockCross;
        logic pageCross;
    } AccessInfo;


    typedef struct {
        logic present; // TLB hit
        VirtualAddressHigh vHigh;
        PhysicalAddressHigh pHigh;
        logic canRead;
        logic canWrite;
    } Translation;


    AccessInfo accesses[N_MEM_PORTS];
    Translation translations[N_MEM_PORTS];        


    Word readData[N_MEM_PORTS] = '{default: 'x};


    always @(posedge clk) begin
        handleReads();
        handleWrites();
        
    end
    

    function automatic void reset();
        content = '{default: 0};
    endfunction


    task automatic handleWrites();
        Mbyte writing[4];
        
        foreach (writing[i])
            writing[i] = writeData[0] >> 8*(3-i);
        
        foreach (writing[i])
            if (writeReqs[0]) content[writeAddresses[0] + i] <= writing[i];

    endtask


    task automatic handleReads();
        foreach (accesses[p]) begin
            accesses[p] <= analyzeAccess(readReqs[p].adr);
            translations[p] <= translateAddress(readReqs[p].adr);
        end
    
        foreach (readData[p]) begin
            logic[7:0] selected[4];
            Word val;       
            
            foreach (selected[i])
                selected[i] = content[readReqs[p].adr + i];
            
            val = (selected[0] << 24) | (selected[1] << 16) | (selected[2] << 8) | selected[3];
        
            readData[p] <= val;
            readResps[p] <= '{0, val};
        end
    endtask


    
    function automatic VirtualAddressLow adrLow(input EffectiveAddress adr);
        return adr[V_INDEX_BITS-1:0];
    endfunction

    function automatic VirtualAddressHigh adrHigh(input EffectiveAddress adr);
        return adr[$size(EffectiveAddress)-1:V_INDEX_BITS];
    endfunction


    function automatic AccessInfo analyzeAccess(input EffectiveAddress adr);
        AccessInfo res;
        
        VirtualAddressLow aLow = adrLow(adr);
        VirtualAddressHigh aHigh = adrHigh(adr);

        int accessSize = 4; // n bytes to read
        
        int block = aLow / BLOCK_SIZE;
        int blockOffset = aLow % BLOCK_SIZE;
        
        res.adr = adr;
        res.accessSize = accessSize;
        
        res.aHigh = aHigh;
        res.aLow = aLow;
        
        res.block = block;
        res.blockOffset = blockOffset;
        
        res.blockCross = (blockOffset + accessSize) > BLOCK_SIZE;
        res.pageCross = (aLow + accessSize) > PAGE_SIZE;

        return res;
    endfunction

    
    function automatic Translation translateAddress(input EffectiveAddress adr);
        Translation res;
        
        res.vHigh = adrHigh(adr);
        
        if ($isunknown(adr)) return res;
        
        // TMP:
        res.pHigh = res.vHigh; // Direct mapping of memory
        res.present = 1; // Obviously
        res.canRead = 1;
        res.canWrite = 1;
        
        return res;
    endfunction

endmodule
