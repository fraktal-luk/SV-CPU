

package RobDefs;

    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;

    import AbstractSim::*;
    import CoreConfig::*;

    import Insmap::*;

    import UopList::*;



    typedef logic CompletionVec[N_UOP_MAX];

    typedef struct {
        logic used;
        InsId mid;
        CompletionVec completed;
    } OpRecord;
    
    localparam OpRecord EMPTY_RECORD = '{used: 0, mid: -1, completed: '{default: 'x}};

    typedef OpRecord OpRecordA[ROB_WIDTH];

    typedef struct {
        OpRecord records[ROB_WIDTH];
    } Row;
    
    localparam Row EMPTY_ROW = '{records: '{default: EMPTY_RECORD}};

    function automatic CompletionVec initCompletedVec(input int n);
        CompletionVec res = '{default: 'x};
        for (int i = 0; i < n; i++)
            res[i] = 0;
        return res;
    endfunction


endpackage
