    
    import Base::*;
    import InsDefs::*;
    import Asm::*;
    import EmulationDefs::*;
    import Emulation::*;
    import UopList::*;
    import AbstractSim::*;

    import MemoryLogic::*;


    class MemTracker;
        Transaction transactions[$];
        Transaction stores[$];
        Transaction loads[$];
        Transaction committedStores[$]; // Not included in transactions
        
        function automatic void add(input InsId id, input UopName uname, input AbstractInstruction ins, input Mword argVals[3],  input Dword padr);
            Mword effAdr = calculateEffectiveAddress(ins, argVals);
            AccessSize size = getTransactionSize(uname);

            if (isLoadAqIns(ins)) begin
                addLoadAq(id, effAdr, padr, 'x, size);
                return;
            end

            if (isMemBarrierIns(ins)) begin
                addBarrier(id, 'x, 'x, 'x, SIZE_NONE, isMemBarrierFwIns(ins));
            end

            if (isStoreMemIns(ins)) begin 
                Mword value = argVals[2];
                addStore(id, effAdr, padr, value, size);
            end
            if (isLoadMemIns(ins)) begin
                addLoad(id, effAdr, padr, 'x, size);
            end
            if (isStoreSysIns(ins)) begin 
                Mword value = argVals[2];
                addStoreSys(id, effAdr, value);
            end
            if (isLoadSysIns(ins)) begin
                addLoadSys(id, effAdr, 'x);
            end
        endfunction

        function automatic void addLoadAq(input InsId id, input Mword adr, input Dword padr, input Mword val, input AccessSize size);
            transactions.push_back('{id, adr, val, adr, padr, size, 0});
            loads.push_back('{id, adr, val, adr, padr, size, 0});
            stores.push_back('{id, adr, val, adr, padr, size, 1});
        endfunction

        function automatic void addBarrier(input InsId id, input Mword adr, input Dword padr, input Mword val, input AccessSize size, input logic isFw);
            transactions.push_back('{id, adr, val, adr, padr, size, isFw});
            stores.push_back('{id, adr, val, adr, padr, size, isFw});
        endfunction

        function automatic void addStore(input InsId id, input Mword adr, input Dword padr, input Mword val, input AccessSize size);
            transactions.push_back('{id, adr, val, adr, padr, size, 0});
            stores.push_back('{id, adr, val, adr, padr, size, 0});
        endfunction

        function automatic void addLoad(input InsId id, input Mword adr, input Dword padr, input Mword val, input AccessSize size);
            transactions.push_back('{id, adr, val, adr, padr, size, 0});
            loads.push_back('{id, adr, val, adr, padr, size, 0});
        endfunction

        function automatic void addStoreSys(input InsId id, input Mword adr, input Mword val);
            transactions.push_back('{id, 'x, val, adr, 'x, SIZE_NONE, 0});
            stores.push_back('{id, 'x, val, adr, 'x, SIZE_NONE, 0});
        endfunction

        function automatic void addLoadSys(input InsId id, input Mword adr, input Mword val);            
            transactions.push_back('{id, 'x, val, adr, 'x, SIZE_NONE, 0});
            loads.push_back('{id, 'x, val, adr, 'x, SIZE_NONE, 0});
        endfunction

        function automatic void remove(input InsId id);        
            assert (transactions[0].owner == id) begin
                void'(transactions.pop_front());
                if (stores.size() != 0 && stores[0].owner == id) begin
                    Transaction store = (stores.pop_front());
                    committedStores.push_back(store);                       
                end
                if (loads.size() != 0 && loads[0].owner == id) void'(loads.pop_front());
            end
            else $error("Incorrect transaction commit");
        endfunction

        function automatic void drain(input InsId id);
            assert (committedStores[0].owner == id) begin
                void'(committedStores.pop_front());
            end
            else $error("Incorrect transaction drain: %d but found %d", id, committedStores[0].owner);
        endfunction

        function automatic void flushAll();
            transactions.delete();
            stores.delete();
            loads.delete();
        endfunction

        function automatic void flush(input InsId id);
            while (transactions.size() != 0 && transactions[$].owner > id) void'(transactions.pop_back());
            while (stores.size() != 0 && stores[$].owner > id) void'(stores.pop_back());
            while (loads.size() != 0 && loads[$].owner > id) void'(loads.pop_back());
        endfunction
        
        
        function automatic Transaction checkTransactionOverlap(input InsId id);
            Transaction allStores[$] = {committedStores, stores};
            Transaction read[$] = transactions.find_first with (item.owner == id); 
            Transaction writers[$] = allStores.find_last with (item.owner < id && memOverlap(item.padr, (item.size), read[0].padr, (read[0].size)));
            return (writers.size() == 0) ? EMPTY_TRANSACTION : writers[$];
        endfunction


        function automatic Transaction findStore(input InsId id);
            Transaction writers[$] = stores.find with (item.owner == id);
            return (writers.size() == 0) ? EMPTY_TRANSACTION : writers[0];
        endfunction

        function automatic Transaction findStoreAll(input InsId id);
            Transaction allStores[$] = {committedStores, stores};
            Transaction writers[$] = allStores.find with (item.owner == id);
            return (writers.size() == 0) ? EMPTY_TRANSACTION : writers[0];
        endfunction

        function automatic logic checkIssue(input UidT uid);
            Transaction checked[$] = transactions.find_first with (item.owner == U2M(uid));

            Transaction allStores[$] = {committedStores, stores};
            Transaction barriers[$] = allStores.find with (item.barrierF === 1);
            Transaction activeBarriers[$] = barriers.find with (item.owner < U2M(uid));

            assert (activeBarriers.size() == 0) return 0; else $fatal(2, "Barrier violation by %p (barrier %p)", uid, activeBarriers[0].owner);
            return 1;
        endfunction

    endclass
