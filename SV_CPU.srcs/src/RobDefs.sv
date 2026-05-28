


package RobDefs;


    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import Emulation::*;

    import AbstractSim::*;
    import Insmap::*;

    import UopList::*;



    typedef logic CompletedVec[N_UOP_MAX];

    typedef struct {
        logic used;
        InsId mid;
        CompletedVec completed;
    } OpRecord;
    
    localparam OpRecord EMPTY_RECORD = '{used: 0, mid: -1, completed: '{default: 'x}};

    typedef OpRecord OpRecordA[ROB_WIDTH];

    typedef struct {
        OpRecord records[ROB_WIDTH];
    } Row;
    
    localparam Row EMPTY_ROW = '{records: '{default: EMPTY_RECORD}};


    typedef OpRecord QM[3*ROB_WIDTH];


        // Experimental
        typedef struct {
            int row;
            int slot;
            InsId mid;
        } TableIndex;
        
        localparam TableIndex EMPTY_TABLE_INDEX = '{-1, -1, -1};

        
        typedef struct {
            InsId id = -1;
            TableIndex tableIndex = EMPTY_TABLE_INDEX;
            logic control;
            logic refetch;
            logic exception;
        } RobResult;
        
        localparam RobResult EMPTY_ROB_RESULT = '{-1, EMPTY_TABLE_INDEX, 'x, 'x, 'x};
        
        typedef RobResult RRQ[$];



    function automatic CompletedVec initCompletedVec(input int n);
        CompletedVec res = '{default: 'x};
        for (int i = 0; i < n; i++)
            res[i] = 0;
        return res;
    endfunction


endpackage
