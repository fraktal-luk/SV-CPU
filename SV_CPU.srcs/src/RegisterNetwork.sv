
import Base::*;
import InsDefs::*;
import Asm::*;
import Emulation::*;

import AbstractSim::*;
import Insmap::*;
import ExecDefs::*;
import Queues::*;


module RegisterNetwork();

    ForwardingElement intImages[N_INT_PORTS][-3:2];
    ForwardingElement memImages[N_MEM_PORTS][-3:2];
    ForwardingElement memImagesVec[N_MEM_PORTS][-3:2];
    ForwardingElement memImagesVec_M1[N_MEM_PORTS][-3:2];
    ForwardingElement floatImages[N_VEC_PORTS][-3:2];

    IntByStage intImagesTr;
    MemByStage memImagesTr;
    MemByStage memImagesVecTr;
    VecByStage floatImagesTr;

    ForwardsByStage_0 allByStage, allByStageVec;




    // Used before Exec0 to get final values
    function automatic Mword3 getAndVerifyArgs(input UopId uid);
        InsDependencies deps = AbstractCore.insMap.getU(uid).deps;
        Mword3 argsP = getArgValues(deps);
        AbstractCore.insMap.setActualArgs(uid, argsP);
        return argsP;
    endfunction;


    // Used once, file internal
    function automatic Mword3 getArgValues(input InsDependencies deps);
        Mword res[3];
        logic3 ready = checkArgsReady(deps, AbstractCore.intRegsReadyV, AbstractCore.floatRegsReadyV);

        foreach (deps.types[i]) begin
            case (deps.types[i])
                SRC_ZERO:  res[i] = 0;
                SRC_CONST: res[i] = deps.sources[i];
                SRC_INT:   res[i] = getArgValueInt(deps.producers[i], deps.sources[i], allByStage, ready[i]);
                SRC_FLOAT: res[i] = getArgValueVec(deps.producers[i], deps.sources[i], allByStageVec, ready[i]);
            endcase
        end

        return res;
    endfunction


    // File internal
    function automatic Mword getArgValueInt(input UopId producer, input int source, input ForwardsByStage_0 fws, input logic ready);
        FEQ found1, found0;

        if (ready) return registerUnit.registerTracker.ints.regs[source];
        
        found1 = findForwardInt(producer, fws.ints[1], fws.mems[1]);
        if (found1.size() != 0) begin
            verifyForward(producer, source, found1[0].result);
            return found1[0].result;
        end
        
        found0 = findForwardInt(producer, fws.ints[0], fws.mems[0]);
        if (found0.size() != 0) begin
            verifyForward(producer, source, found0[0].result);
            return found0[0].result;
        end

        $fatal(2, "oh no\n%p, %d", producer, source);
    endfunction


    // File internal
    function automatic Mword getArgValueVec(input UopId producer, input int source, input ForwardsByStage_0 fws, input logic ready);
        FEQ found1, found0;

        if (ready) return registerUnit.registerTracker.floats.regs[source];

        found1 = findForwardVec(producer, fws.vecs[1], fws.mems[1]);
        if (found1.size() != 0) begin
            verifyForward(producer, source, found1[0].result);
            return found1[0].result;
        end

        found0 = findForwardVec(producer, fws.vecs[0], fws.mems[0]);
        if (found0.size() != 0) begin
            verifyForward(producer, source, found0[0].result);
            return found0[0].result;
        end

        $fatal(2, "oh no");
    endfunction


    // File internal
    function automatic FEQ findForwardInt(input UopId producer, input ForwardingElement feInt[N_INT_PORTS], input ForwardingElement feMem[N_MEM_PORTS]);
        FEQ res = feInt.find with (matchProducer(item, producer));
        if (res.size() == 0)
            res = feMem.find with (matchProducer(item, producer));
        return res;
    endfunction

    // File internal
    function automatic FEQ findForwardVec(input UopId producer, input ForwardingElement feVec[N_VEC_PORTS], input ForwardingElement feMem[N_MEM_PORTS]);
        FEQ res = feVec.find with (matchProducer(item, producer));
        if (res.size() == 0)
            res = feMem.find with (matchProducer(item, producer));
        return res;
    endfunction


    // File internal
    function automatic void verifyForward(input UopId producer, input int source, input Mword result);
        InstructionInfo ii = AbstractCore.insMap.get(U2M(producer));
        UopInfo ui = AbstractCore.insMap.getU(producer);

        assert (ui.physDest === source) else $fatal(2, "Not correct match, should be %p:", ii.id);
        assert (ui.resultA === result) else $fatal(2, "Value differs! %d // %d;\n %p\n%s", ui.resultA, result, ii, disasm(ii.basicData.bits));
    endfunction





        function automatic IntByStage trsInt(input ForwardingElement imgs[N_INT_PORTS][-3:2]);
            IntByStage res;
            
            foreach (imgs[p]) begin
                ForwardingElement img[-3:2] = imgs[p];
                foreach (img[s])
                    res[s][p] = img[s];
            end
            
            return res;
        endfunction

        function automatic MemByStage trsMem(input ForwardingElement imgs[N_MEM_PORTS][-3:2]);
            MemByStage res;
            
            foreach (imgs[p]) begin
                ForwardingElement img[-3:2] = imgs[p];
                foreach (img[s])
                    res[s][p] = img[s];
            end
            
            return res;
        endfunction

        function automatic VecByStage trsVec(input ForwardingElement imgs[N_VEC_PORTS][-3:2]);
            VecByStage res;
            
            foreach (imgs[p]) begin
                ForwardingElement img[-3:2] = imgs[p];
                foreach (img[s])
                    res[s][p] = img[s];
            end
            
            return res;
        endfunction




    assign intImages = '{0: theExecBlock.regular0.image_E,
                         1: theExecBlock.regular1.image_E,
                         2: theExecBlock.branch0.image_E,
                         3: theExecBlock.divider.image_E,
                         4: theExecBlock.multiplier0.image_E,
                         5: theExecBlock.multiplier1.image_E,
                         default: EMPTY_IMAGE};
    assign floatImages = '{0: theExecBlock.float0.image_E, 1: theExecBlock.float1.image_E, 2: theExecBlock.fdiv.image_E, default: EMPTY_IMAGE};

    assign memImages = '{0: theExecBlock.mem0.image_E, 1: theExecBlock.mem1.image_E, 2: theExecBlock.mem2.image_E, default: EMPTY_IMAGE};

    assign memImagesVec_M1 = '{0: theExecBlock.mem0.imageM1_E,
                              1: theExecBlock.mem1.imageM1_E,
                              2: theExecBlock.mem2.imageM1_E, default: EMPTY_IMAGE};

    assign memImagesVec = memImages; //  TODO: separate, 1c longer load pipe on FP side: memImagesVec_M1



    always_comb intImagesTr = trsInt(intImages);
    always_comb memImagesTr = trsMem(memImages);
    always_comb memImagesVecTr = trsMem(memImagesVec);
    always_comb floatImagesTr = trsVec(floatImages);

    assign allByStage.ints = intImagesTr;
    assign allByStage.mems = memImagesTr;
    assign allByStage.vecs = floatImagesTr;


    assign allByStageVec.ints = intImagesTr;
    assign allByStageVec.mems = memImagesVecTr;
    assign allByStageVec.vecs = floatImagesTr;




    // IQs
    function automatic Wakeup checkForwardSourceInt(input UopId producer);
        ForwardingElement fea[N_INT_PORTS][-3:2] = intImages;
        Wakeup res = EMPTY_WAKEUP;
        if (producer == UID_NONE) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.uid == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe %d (%d):\n%p", p, found, fea[p]);
            
            if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

            res.active = 1;
            res.producer = producer;
            res.group = PG_INT;
            res.port = p;
            res.stage = found[0];
            res.poison = fea[p][found[0]].poison;
            return res;
        end
        return res;
    endfunction;

    function automatic Wakeup checkForwardSourceVec(input UopId producer);
        ForwardingElement fea[N_VEC_PORTS][-3:2] = floatImages;
        Wakeup res = EMPTY_WAKEUP;
        if (producer == UID_NONE) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.uid == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe");
            
            if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

            res.active = 1;
            res.producer = producer;
            res.group = PG_VEC;
            res.port = p;
            res.stage = found[0];
            res.poison = fea[p][found[0]].poison;
            return res;
        end
        return res;
    endfunction;


    function automatic Wakeup checkForwardSourceMem(input UopId producer);
        ForwardingElement fea[N_MEM_PORTS][-3:2] = memImages;
        Wakeup res = EMPTY_WAKEUP;
        if (producer == UID_NONE) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.uid == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe");
            
            if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

            res.active = 1;

            // Don't wake up if this is a failed op
            if (fea[p][found[0]].status != ES_OK && found[0] >= 0) res.active = 0;
            
            res.producer = producer;
            res.group = PG_MEM;
            res.port = p;
            res.stage = found[0];
            res.poison = addProducer(fea[p][found[0]].poison, producer, fea);
            return res;
        end
        return res;
    endfunction;

    function automatic Wakeup checkForwardSourceMemVec(input UopId producer);
        ForwardingElement fea[N_MEM_PORTS][-3:2] = memImagesVec;
        Wakeup res = EMPTY_WAKEUP;
        if (producer == UID_NONE) return res;
        foreach (fea[p]) begin
            int found[$] = fea[p].find_index with (item.uid == producer);
            if (found.size() == 0) continue;
            else if (found.size() > 1) $error("Repeated op id in same subpipe");
            
            if (found[0] < FW_FIRST || found[0] > FW_LAST) continue;

            res.active = 1;

            // Don't wake up if this is a failed op
            if (fea[p][found[0]].status != ES_OK && found[0] >= 0) res.active = 0;
            
            res.producer = producer;
            res.group = PG_MEM;
            res.port = p;
            res.stage = found[0];
            res.poison = addProducer(fea[p][found[0]].poison, producer, fea);
            return res;
        end
        return res;
    endfunction;

endmodule

