
package ControlRegisters; 
    import Base::*;
    import InsDefs::*;


    typedef struct {
        
        // 0
        Dword deviceID = -1;
        
        // 1
        struct packed {
            Word resA;
            
            logic [10:0] resB;
            
            logic       dbStep;
            
            logic [1:0] resC;
            logic       enArithExc;
            logic [4:0] resD;
             
            logic [3:0] intMask;
            logic [3:0] intLevel;
            logic [3:0] excLevel;
        } currentStatus = 0;
        
        // 2
        Dword excSavedIP = 0;
        // 3
        Dword intSavedIP = 0;
        // 4
        Dword excSavedStatus = 0;
        // 5
        Dword intSavedStatus = 0;
        
        // 6
        Dword excSyndrome = 0;
        // 7 
        Dword intSyndrome = 0;
        
        // 8
        struct packed {
            Word resA;
            logic INV;  // 31
            logic OV;   // 30
            logic [29:0] resB;
        } fpStatus = 0;
        
        // 9
        // .....
        
        // 10
        struct packed {
            Word resA;
            logic [28:0] resB;
            logic TMP_dcache;
            logic TMP_icache;
            logic enableMMU;
        } memControl = 0;
        
        
        
        
    } CpuControlRegisters;
    
    
    function automatic void syncCregsFromArray(ref CpuControlRegisters cregs, Mword arr[32]);
        cregs.deviceID = arr[0];
        cregs.currentStatus = arr[1];
        cregs.excSavedIP = arr[2];
        cregs.intSavedIP = arr[3];
        cregs.excSavedStatus = arr[4];
        cregs.intSavedStatus = arr[5];
        cregs.excSyndrome = arr[6];
        cregs.intSyndrome = arr[7];
        cregs.fpStatus = arr[8];
        
        cregs.memControl = arr[10];
    endfunction
    
    
    function automatic void syncArrayFromCregs(ref Mword arr[32], CpuControlRegisters cregs);
        arr[0] = cregs.deviceID;
        arr[1] = cregs.currentStatus;
        arr[2] = cregs.excSavedIP;
        arr[3] = cregs.intSavedIP;
        arr[4] = cregs.excSavedStatus;
        arr[5] = cregs.intSavedStatus;
        arr[6] = cregs.excSyndrome;
        arr[7] = cregs.intSyndrome;
        arr[8] = cregs.fpStatus;
        
        arr[10] = cregs.memControl;
    endfunction   
    
    
endpackage
