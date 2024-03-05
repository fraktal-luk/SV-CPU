
package Asm;
    import Base::*;
    import InsDefs::*;

    typedef string squeue[$];

    typedef struct {
        bit ref21 = 0;
        bit ref26 = 0;
        string label = "";
    } CodeRef;


    function automatic Word getIns(input string parts[]);
        InstructionFormat fmt = getFormat(parts[0]);
        InstructionDef def = getDef(parts[0]);
        
        string args[] = orderArgs(parts[1:3], parsingMap[fmt]);
        Word4 vals;
        Word res;

        if ( checkArgs(args[0:3], parsingMap[fmt]) != 1) $error("Incorrect args");
                    
        vals = parseArgs(args[0:3]);
       
        res = fillArgs(vals, parsingMap[fmt], 0);            
        res = fillOp(res, def);
        
        return res;
    endfunction;

    function automatic CodeRef getCodeRef(input string parts[]);
        InstructionFormat fmt = getFormat(parts[0]);
        InstructionDef def = getDef(parts[0]);
        
        string args[] = orderArgs(parts[1:3], parsingMap[fmt]);
        Word4 vals;
        CodeRef res;

        res.label = parseLabel(args[0:3], parsingMap[fmt].decoding);
        if (res.label.len() != 0)
            case (def.p)
                P_ja: res.ref26 = 1;
                P_jl, P_jz, P_jnz: res.ref21 = 1;
                default: ;
            endcase            
        return res; 
    endfunction;



    function automatic string4 orderArgs(input string args[], input FormatSpec fmtSpec);
        string4 out;
        int index;
        string asmForm = fmtSpec.asmForm;
        
        foreach (asmForm[i]) begin
            case (asmForm[i])
                "d": index = 0;
                "0": index = 1;
                "1": index = 2;
                "2": index = 3;
                " ": continue;
                default: $fatal("Wrong format definition");
            endcase
            out[index] = args[i];
        end
        
        return out;
    endfunction

    function automatic int checkArgs(input string4 args, input FormatSpec fmtSpec);
        string typeSpec = fmtSpec.typeSpec;
        string decoding = fmtSpec.decoding;
        
        case (typeSpec[0])
            "i": if (args[0][0] != "r" && decoding[0] != "0") return 0;
            "f": if (args[0][0] != "f" && decoding[0] != "0") return 0;
            default: if (args[0][0] != "") return 0;
        endcase

        for (int i = 1; i <= 3; i++) begin
            case (typeSpec[i+1])
                "i": if (args[i][0] != "r" && decoding[i+1] != "0") return 0;
                "f": if (args[i][0] != "f" && decoding[i+1] != "0") return 0;
                "c": ;
                "0": if (args[i].len() != 0) return 0;
                default:   
                   begin
                       $error("arg spec: [%s]", typeSpec[i+1]);
                       if (args[i][0] != " ") return 0;
                   end
            endcase
        end
        
        return 1;
    endfunction


    function automatic Word4 parseArgs(input string4 args);
        Word4 res;
        integer value = 'x;

        foreach(args[i]) begin
            if (args[i].len() == 0) begin
               res[i] = 'x;
               continue;
            end
        
            case (args[i][0])
                "$", "@": value = 'x;
                "f":      value = args[i].substr(1, args[i].len()-1).atoi();
                "r":      value = args[i].substr(1, args[i].len()-1).atoi();
                "-":      value = args[i].substr(0, args[i].len()-1).atoi();
                "0", "1", "2", "3", "4", "5", "6", "7", "8", "9": 
                          value = args[i].atoi();
                default: $fatal("Wrong arg");
            endcase
            
            res[i] = value;
        end
        
        return res;
    endfunction


    function automatic string parseLabel(input string4 args, input string decoding);
        for (int i = 1; i < 4; i++) begin
            if (decoding[i+1] inside {"L", "J"} && args[i][0] == "$") return args[i];
        end
        
        return "";
    endfunction

    
    function automatic Word fillField(input Word w, input logic[7:0] field, input Word value);
        Word res = w;
        case (field)
            "a": res[25:21] = value[4:0];
            "b": res[20:16] = value[4:0];
            "c": res[9:5] = value[4:0];
            "d": res[4:0] = value[4:0];
            "X": res[9:0] = value[9:0];
            "H": res[15:0] = value[15:0];
            "J": res[20:0] = value[20:0];
            "L": res[25:0] = value[25:0];
            " ", "0": ;
            default: $fatal("Invalid field: %s", field);
        endcase
        
        return res;
    endfunction


    function automatic Word fillArgs(input Word4 args, input FormatSpec fmtSpec, input bit unknownOffset);
        string decoding = fmtSpec.decoding;
        Word res = '0;

        res = fillField(res, decoding[0], args[0]);
        
        res = fillField(res, decoding[2], args[1]);
        res = fillField(res, decoding[3], args[2]);
        res = fillField(res, decoding[4], args[3]);

        return res;
    endfunction
    
    function automatic Word fillOp(input Word w, input InstructionDef def);
        Word res = w;
        res[31:26] = def.p;
        if (def.s != S_none) res[15:10] = def.s;
        if (def.t != T_none) res[4:0] = def.t;
        return res;
    endfunction;


    typedef struct {
        string mnemonic;
        Word encoding;
        InstructionFormat fmt;
        InstructionDef def;
        int dest;
        int sources[3];
    } AbstractInstruction;


    const AbstractInstruction DEFAULT_ABS_INS = '{"", 'x, none,
                                '{P_none, S_none, T_none, O_undef},
                                0, '{default: 0}};

    function automatic string decodeMnem(input Word w);
        Primary p = toPrimary(w[31:26]);
        Secondary s = toSecondary(w[15:10], p);
        Ternary t = toTernary(w[4:0], p, s);
        
        InstructionDef def = '{p, s, t, O_undef};

        return findMnemonic(def);               
    endfunction

    function automatic AbstractInstruction decodeAbstract(input Word w);
        string s = decodeMnem(w);
        AbstractInstruction res;
        InstructionFormat f = getFormat(s);
        InstructionDef d = getDef(s);
        
        FormatSpec fmtSpec = parsingMap[f];

        int qa = w[25:21];        
        int qb = w[20:16];        
        int qc = w[9:5];        
        int qd = w[4:0];        

        int dest;
        int sources[3];

        if ($isunknown(w)) begin
            //$warning("Decoding unknown word");
            res.mnemonic = "unknown";
            return res;
        end

        case (fmtSpec.decoding[0])
            "a": dest = qa;
            "b": dest = qb;
            "c": dest = qc;
            "d": dest = qd;
            "0", " ": ;
            default: $fatal("Wrong dest specifier");
        endcase

        foreach(sources[i])
            case (fmtSpec.decoding[i+2])
                "a": sources[i] = qa;
                "b": sources[i] = qb;
                "c": sources[i] = qc;
                "d": sources[i] = qd;
                "X": sources[i] = $signed(w[9:0]);
                "H": sources[i] = $signed(w[15:0]);
                "J": sources[i] = $signed(w[20:0]);
                "L": sources[i] = $signed(w[25:0]);
                "0", " ": ;
                default: $fatal("Wrong source specifier");
            endcase
        
        res.mnemonic = s;
        res.encoding = w;
        res.fmt = f;
        res.def = d;
        res.dest = dest;
        res.sources = sources;
        
        return res; 
    endfunction

    
    function automatic string ins2str(input AbstractInstruction ins);
        string s;
        int dest;
        int sources[3];
        string destStr;
        string sourcesStr[3];

        FormatSpec fmtSpec = parsingMap[ins.fmt];

        dest = ins.dest;
        sources = ins.sources;
               
        case (fmtSpec.typeSpec[0])
            "i": $swrite(destStr, "r%0d", dest);
            "f": $swrite(destStr, "f%0d", dest);
            "0": destStr = "";
            default: $fatal("Wrong dest specifier");
        endcase

        foreach(sources[i])
            case (fmtSpec.typeSpec[i+2])
                "i": $swrite(sourcesStr[i], "r%0d", sources[i]);
                "f": $swrite(sourcesStr[i], "f%0d", sources[i]);
                "c": $swrite(sourcesStr[i], "%0d", sources[i]);
                "0": sourcesStr[i] = "";
                default: $fatal("Wrong source specifier");
            endcase

        s = {ins.mnemonic, "          "};
        s = s.substr(0,9);

        foreach (fmtSpec.asmForm[i]) begin
            case (fmtSpec.asmForm[i])
                "d": s = {s, " ", destStr};
                "0": s = {s, " ", sourcesStr[0]};
                "1": s = {s, " ", sourcesStr[1]};
                "2": s = {s, " ", sourcesStr[2]};
                " ": ;
                default: $fatal("Wrong asm syntax description");
            endcase;
          
            if (i == 3 || fmtSpec.asmForm[i+1] == " ") break;

            s = {s, ","};
        end
        
        return s;
    endfunction

    function automatic string disasm(input Word w);        
        AbstractInstruction absIns = decodeAbstract(w);        
        return ins2str(absIns);
    endfunction;


    function automatic squeue readFile(input string name);
        int file = $fopen(name, "r");
        string line;
        string lines[$];

        while (!$feof(file)) begin
            int dummy = $fgets(line, file);
            lines.push_back(line);
        end
        $fclose(file);
                
        return lines;
    endfunction

    // UNUSED
    function automatic bit writeFile(input string name, input squeue lines);
        int file = $fopen(name, "w");
        foreach (lines[i]) $fdisplay(file, lines[i]);  
        $fclose(file);

        return 1;
    endfunction

    function bit isLetter(input logic[7:0] char);
        return (char inside {["A":"Z"], ["A":"z"]});            
    endfunction
    
    function bit isDigit(input logic[7:0] char);
        return (char inside {["0":"9"]});            
    endfunction

    function bit isAlpha(input logic[7:0] char);
        return (char inside {["A":"Z"], ["A":"z"], ["0":"9"], "_"});            
    endfunction

    function bit isWhite(input logic[7:0] char);
        return (char inside {" ", "\t"});            
    endfunction

    function automatic squeue breakLine(input string line);
        squeue elems;

        for (int i = 0; i < line.len(); i = i) begin
            
            if (line[i] inside {0, ";", "\n"}) begin
                break;
            end
            else if (isWhite(line[i])) begin
                while (isWhite(line[i])) i++; // Skip spaces
            end
            else if (line[i] inside {"$", "@"}) begin
                int iStart = i;
                i++;
                while (isAlpha(line[i])) begin
                    i++;
                end
                elems.push_back(line.substr(iStart, i-1));
            end
            else if (isAlpha(line[i]) || line[i] == "-") begin
                int iStart = i;
                i++;
                while (isAlpha(line[i])) begin
                    i++;
                end 
                elems.push_back(line.substr(iStart, i-1));
            end
            else if (line[i] == ",") begin
                i++;
            end
            else begin
                i++;
                $error("char %s at %d not recognized", line[i-1], i-1);
            end
            
        end
        
        return elems;
    endfunction


    typedef enum {
        NONE, SOME
    } ParseError;


    typedef struct {
        int line;
        int codeLine;
        squeue parts;
        ParseError error = SOME;
        Word ins;
        CodeRef codeRef;
    } CodeLine;

    typedef struct {
        int line;
        int codeLine;
        squeue parts;
        ParseError error = SOME;
        string label;
    } DirectiveLine;

    typedef struct {
        int codeLine; string label; int size;
    } ImportRef;

    typedef struct {
        int codeLine; string label;
    } ExportRef;

    typedef struct {
        string desc;
        Word words[];
        ImportRef imports[];
        ExportRef exports[];
    } Section;

    function automatic Section processLines(input squeue lines);
        Section res;
        squeue labels = '{};
        int labelMap[string];
        ImportRef importMap[string];
        ImportRef imports[$];
        ExportRef exports[$];
        squeue errors = '{};
        CodeLine instructions[$];
        Word code[];
    
        int nInstructionLines = 0;
    
        foreach (lines[i]) begin
            squeue parts = breakLine({lines[i], 8'h0});
            if (parts.size() == 0)
                continue;
            else if (parts[0][0] == "$") begin
                labels.push_back(parts[0]);
                labelMap[parts[0]] = nInstructionLines + 1;
                errors.push_back($sformatf("%d: Something after label", i));
            end
            else if (parts[0][0] == "@") begin
                DirectiveLine dl = analyzeDirective(i, nInstructionLines, parts);
                if (dl.label.len() != 0)
                    exports.push_back('{nInstructionLines + 1, dl.label});
            end
            else begin
                instructions.push_back(analyzeCodeLine(i, nInstructionLines, parts));
                nInstructionLines++;
            end
        end
        
        code = new[nInstructionLines];
        
        // Resolve labels
        foreach(instructions[i]) begin
            CodeLine ins = instructions[i];
            if (ins.codeRef.label.len() != 0) begin
                if (labelMap.exists(ins.codeRef.label)) begin
                    int cline = labelMap[ins.codeRef.label];
                    int targetAdr = 4*cline;
                    int usingAdr = 4*ins.codeLine;
                    Word newWord = ins.ins;
                    
                    if (ins.codeRef.ref26 == 1) newWord[25:0] = (targetAdr - usingAdr);
                    else if (ins.codeRef.ref21 == 1) newWord[20:0] = (targetAdr - usingAdr);
                    
                    instructions[i].ins = newWord;
                end
                else begin
                    int size = ins.codeRef.ref26 == 1 ? 26 : 21;                    
                    imports.push_back('{ins.codeLine, ins.codeRef.label, size});
                end             
            end
            code[i] = instructions[i].ins;
        end
        
        res.words = code;
        
        begin
            int nImports = imports.size();
            int nExports = exports.size();
            res.imports = new[nImports](imports[0:$]);
            res.exports = new[nExports](exports[0:$]);
        end
 
        return res;
    endfunction


    function automatic Word fillImport(input Word w, input int adrDiff, input ImportRef imp, input ExportRef exp);
        Word res = w;
        int offset = adrDiff + 4*(exp.codeLine - imp.codeLine);
        
        case (imp.size)
            21: res[20:0] = offset;
            26: res[25:0] = offset;
            default: $fatal("Incorrect offset size");
        endcase
        
        return res;
    endfunction
    

    function automatic CodeLine analyzeCodeLine(input int line, input int codeLine, input squeue parts);
        CodeLine res;
        string mnemonic = parts[0];
        string partsExt[4];
 
        res.line = line + 1;
        res.codeLine = codeLine + 1;
        res.parts = parts;
        res.error = NONE;
        
        if (!isLetter(mnemonic[0])) begin
            res.error = SOME;
            return res;
        end

        foreach(partsExt[i])
            if (i < parts.size())
                partsExt[i] = parts[i];

        // TODO: get rid of this hack, define sys instructions like sys_call etc?
        if (mnemonic == "sys") begin
            mnemonic = {mnemonic,"_", parts[1]};
            partsExt[0] = mnemonic;
            partsExt[1] = "";
        end
        
        res.ins = getIns(partsExt);      
        res.codeRef = getCodeRef(partsExt);

        return res;
    endfunction

    function automatic DirectiveLine analyzeDirective(input int line, input int codeLine, input squeue parts);
        DirectiveLine res;
        
        res.line = line + 1;
        res.codeLine = codeLine + 1;
        res.parts = parts;
        res.error = NONE;
        
        if (parts[0] == "@proc") begin
            res.label = {"$", parts[1]};
            if (parts.size() > 2) begin
                $error("Too many arguments: %d", line + 1);
                res.error = SOME;
            end
        end
        else if (parts[0] == "@end") begin
            if (parts.size() > 1) begin
                $error("Too many arguments: %d", line + 1);
                res.error = SOME;
            end
        end
        else begin
            $error("Unknown directive: %d", line + 1);
            res.error = SOME;
        end

        return res;
    endfunction

    // UNUSED
    function automatic squeue disasmBlock(input Word words[]);
        squeue res;
        string s;
        foreach (words[i]) begin
            $swrite(s, "%h: %h  %s", 4*i , words[i], disasm(words[i]));
            res.push_back(s);
        end
        return res;
    endfunction

    function automatic Section fillImports(input Section section, input int startAdr, input Section lib, input int libAdr);
        Section res = section;
        int adrDiff = libAdr - startAdr;
        
        foreach (section.imports[i]) begin
            ImportRef imp = section.imports[i];
            ExportRef exps[$] = lib.exports.find with (item.label == imp.label);
            if (exps.size() == 0) continue;

            res.words[imp.codeLine-1] = fillImport(res.words[imp.codeLine-1], adrDiff, imp, exps[0]);
        end 
        
        return res;
    endfunction

endpackage
