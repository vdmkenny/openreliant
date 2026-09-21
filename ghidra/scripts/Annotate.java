// Annotates the payload: defines the data types of a schema, then applies names, comments, data
// types and function signatures from tables of them.
//
//   Annotate.java <types.tsv> <names.tsv>...
//
// The schema is what `ghidragen types` writes from the Zig definitions; src/tools/ghidragen/types.zig
// describes its rows. Every type lands in the /StarLancer category and replaces an earlier
// definition of the same name, so running this again brings the project up to date, and data and
// functions typed with one keep it.
//
// A names table has rows of address, kind, name, type and comment, tab-separated; type and comment
// may be empty. A `function` row names the function at its address, creating it if need be. Its
// type is either the name of a function type from the schema or a signature in C without the
// function's name, such as `void __fastcall (VmThread *thread)`. A `data` row labels its address,
// and its type, such as `VmThread *` or `ConditionDescriptor[35]`, replaces whatever data was
// defined there. The comment becomes a function's plate comment or the data's pre comment. Lines
// starting with '#', blank lines and addresses the program does not contain are skipped, so one
// table can cover a group holding several programs.
//
// A type string is a type's name, then `*` and `[n]` decorations read as C reads them. Names are
// looked up in /StarLancer first, then among Ghidra's built-in types. Names are applied as
// user-defined. Re-running is harmless.
//
//@category StarLancer

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import ghidra.app.cmd.function.ApplyFunctionSignatureCmd;
import ghidra.app.cmd.function.CreateFunctionCmd;
import ghidra.app.cmd.function.FunctionRenameOption;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.ArrayDataType;
import ghidra.program.model.data.BuiltInDataTypeManager;
import ghidra.program.model.data.CategoryPath;
import ghidra.program.model.data.DataType;
import ghidra.program.model.data.DataTypeConflictHandler;
import ghidra.program.model.data.DataTypeManager;
import ghidra.program.model.data.DataUtilities;
import ghidra.program.model.data.EnumDataType;
import ghidra.program.model.data.FunctionDefinition;
import ghidra.program.model.data.FunctionDefinitionDataType;
import ghidra.program.model.data.ParameterDefinition;
import ghidra.program.model.data.ParameterDefinitionImpl;
import ghidra.program.model.data.PointerDataType;
import ghidra.program.model.data.StructureDataType;
import ghidra.program.model.data.UnionDataType;
import ghidra.program.model.listing.CommentType;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolTable;

public class Annotate extends GhidraScript {

    private static final CategoryPath CATEGORY = new CategoryPath("/StarLancer");
    private static final String[] CONVENTIONS = { "__cdecl", "__stdcall", "__fastcall", "__thiscall" };

    private DataTypeManager dtm;
    private int types;
    private int functions;
    private int labels;
    private int typed;
    private int skipped;
    private int failed;

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) {
            println("usage: Annotate.java <types.tsv> <names.tsv>...");
            return;
        }
        dtm = currentProgram.getDataTypeManager();
        defineTypes(Path.of(args[0]));
        for (int i = 1; i < args.length; i++) {
            applyNames(Path.of(args[i]));
        }
        println(String.format(
            "%s: %d types defined; %d functions and %d labels named, %d of them typed; " +
                "%d rows not in this program, %d failed",
            currentProgram.getName(), types, functions, labels, typed, skipped, failed));
    }

    // --- the schema -----------------------------------------------------------------------------

    /** One definition of the schema: its header row's fields, then its member rows' fields. */
    private record Definition(String[] header, List<String[]> rows) {
        String kind() { return header[0]; }
        String name() { return header[1]; }
    }

    private void defineTypes(Path schema) throws Exception {
        Map<String, Definition> definitions = new LinkedHashMap<>();
        for (String line : Files.readAllLines(schema)) {
            if (line.isBlank() || line.startsWith("#")) {
                continue;
            }
            String[] fields = line.split("\t", -1);
            switch (fields[0]) {
                case "struct", "union", "enum", "function" ->
                    definitions.put(fields[1], new Definition(fields, new ArrayList<>()));
                case "field", "bits", "member", "value" -> {
                    Definition owner = definitions.get(fields[1]);
                    if (owner == null) {
                        throw new IllegalArgumentException("row before its type: " + line);
                    }
                    owner.rows().add(fields);
                }
                default -> throw new IllegalArgumentException("unknown row: " + line);
            }
        }

        // Structures and unions first as empty shells of the right size, so that anything may
        // refer to them; then what refers only by pointer; structures last, since they may hold
        // the others by value.
        for (Definition d : definitions.values()) {
            switch (d.kind()) {
                case "struct" -> add(new StructureDataType(CATEGORY, d.name(), Integer.parseInt(d.header()[2]), dtm));
                case "union" -> add(new UnionDataType(CATEGORY, d.name(), dtm));
                default -> { }
            }
        }
        for (Definition d : definitions.values()) {
            if (d.kind().equals("enum")) {
                EnumDataType e = new EnumDataType(CATEGORY, d.name(), Integer.parseInt(d.header()[2]), dtm);
                for (String[] row : d.rows()) {
                    e.add(row[2], Long.parseLong(row[3]));
                }
                add(e);
            }
        }
        for (Definition d : definitions.values()) {
            if (d.kind().equals("function")) {
                add(parseSignature(d.name(), d.header()[2]));
            }
        }
        for (Definition d : definitions.values()) {
            if (d.kind().equals("union")) {
                UnionDataType u = new UnionDataType(CATEGORY, d.name(), dtm);
                for (String[] row : d.rows()) {
                    DataType member = parseType(row[3]);
                    u.add(member, member.getLength(), row[2], null);
                }
                expectLength(u, d);
                add(u);
            }
        }
        for (Definition d : definitions.values()) {
            if (d.kind().equals("struct")) {
                StructureDataType s = new StructureDataType(CATEGORY, d.name(), Integer.parseInt(d.header()[2]), dtm);
                for (String[] row : d.rows()) {
                    if (row[0].equals("field")) {
                        DataType field = parseType(row[4]);
                        s.replaceAtOffset(Integer.parseInt(row[2]), field, field.getLength(), row[3], null);
                    } else {
                        s.insertBitFieldAt(Integer.parseInt(row[2]), Integer.parseInt(row[3]),
                            Integer.parseInt(row[4]), parseType(row[7]), Integer.parseInt(row[5]), row[6], null);
                    }
                }
                expectLength(s, d);
                add(s);
            }
        }
        types = definitions.size();
    }

    private DataType add(DataType dt) {
        return dtm.addDataType(dt, DataTypeConflictHandler.REPLACE_HANDLER);
    }

    private static void expectLength(DataType dt, Definition d) {
        int expected = Integer.parseInt(d.header()[2]);
        if (dt.getLength() != expected) {
            throw new IllegalStateException(String.format("%s: %d bytes in Ghidra, %d in the schema",
                d.name(), dt.getLength(), expected));
        }
    }

    // --- type strings and signatures ------------------------------------------------------------

    private DataType lookup(String name) {
        DataType dt = dtm.getDataType(CATEGORY, name);
        if (dt != null) {
            return dt;
        }
        dt = BuiltInDataTypeManager.getDataTypeManager().getDataType(CategoryPath.ROOT, name);
        if (dt != null) {
            return dt.clone(dtm);
        }
        throw new IllegalArgumentException("unknown type " + name);
    }

    /** A type string: a name, then `*` and `[n]`, with a run of dimensions outermost first. */
    private DataType parseType(String text) {
        text = text.trim();
        int end = 0;
        while (end < text.length() && Character.isJavaIdentifierPart(text.charAt(end))) {
            end++;
        }
        DataType dt = lookup(text.substring(0, end));
        List<Integer> dimensions = new ArrayList<>();
        for (int i = end; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == ' ') {
                continue;
            }
            if (c == '*') {
                dt = new PointerDataType(array(dt, dimensions), dtm);
                dimensions.clear();
            } else if (c == '[') {
                int close = text.indexOf(']', i);
                dimensions.add(Integer.parseInt(text.substring(i + 1, close).trim()));
                i = close;
            } else {
                throw new IllegalArgumentException("bad type string: " + text);
            }
        }
        return array(dt, dimensions);
    }

    private DataType array(DataType element, List<Integer> dimensions) {
        DataType dt = element;
        for (int k = dimensions.size() - 1; k >= 0; k--) {
            dt = new ArrayDataType(dt, dimensions.get(k), dt.getLength(), dtm);
        }
        return dt;
    }

    /** `<return type> [<convention>] (<type> <name>, ...)`, which gets `name`. */
    private FunctionDefinitionDataType parseSignature(String name, String text) throws Exception {
        int open = text.indexOf('(');
        int close = text.lastIndexOf(')');
        if (open < 0 || close < open) {
            throw new IllegalArgumentException("bad signature: " + text);
        }
        String head = text.substring(0, open).trim();
        String convention = null;
        for (String c : CONVENTIONS) {
            if (head.endsWith(c)) {
                convention = c;
                head = head.substring(0, head.length() - c.length()).trim();
            }
        }
        List<ParameterDefinition> parameters = new ArrayList<>();
        String list = text.substring(open + 1, close).trim();
        if (!list.isEmpty() && !list.equals("void")) {
            for (String parameter : list.split(",")) {
                parameter = parameter.trim();
                int split = parameter.length();
                while (split > 0 && Character.isJavaIdentifierPart(parameter.charAt(split - 1))) {
                    split--;
                }
                parameters.add(new ParameterDefinitionImpl(parameter.substring(split),
                    parseType(parameter.substring(0, split)), null));
            }
        }
        FunctionDefinitionDataType definition = new FunctionDefinitionDataType(CATEGORY, name, dtm);
        definition.setReturnType(parseType(head));
        definition.setArguments(parameters.toArray(new ParameterDefinition[0]));
        if (convention != null) {
            definition.setCallingConvention(convention);
        }
        return definition;
    }

    // --- names tables ---------------------------------------------------------------------------

    private void applyNames(Path table) throws Exception {
        for (String line : Files.readAllLines(table)) {
            monitor.checkCancelled();
            if (line.isBlank() || line.startsWith("#")) {
                continue;
            }
            String[] fields = line.split("\t", -1);
            if (fields.length < 3) {
                println("malformed row in " + table + ": " + line);
                failed++;
                continue;
            }
            Address address = toAddr(Long.parseLong(fields[0].trim(), 16));
            if (!currentProgram.getMemory().contains(address)) {
                skipped++;
                continue;
            }
            String kind = fields[1].trim();
            String name = fields[2].trim();
            String type = fields.length > 3 ? fields[3].trim() : "";
            String comment = fields.length > 4 ? fields[4].trim() : "";
            try {
                switch (kind) {
                    case "function" -> nameFunction(address, name, type, comment);
                    case "data" -> labelData(address, name, type, comment);
                    default -> {
                        println("unknown kind '" + kind + "' in " + table + ": " + line);
                        failed++;
                    }
                }
            } catch (Exception e) {
                println("could not apply " + name + " at " + address + ": " + e.getMessage());
                failed++;
            }
        }
    }

    private void nameFunction(Address address, String name, String type, String comment) throws Exception {
        // Code only the tables reach was never disassembled, and a function made over undefined
        // bytes gets no body.
        if (getInstructionAt(address) == null && !disassemble(address)) {
            throw new Exception("no code at the address");
        }
        Function function = getFunctionAt(address);
        if (function == null) {
            function = createFunction(address, name);
            if (function == null) {
                throw new Exception("no function could be created");
            }
        } else if (function.getBody().getNumAddresses() <= 1) {
            CreateFunctionCmd.fixupFunctionBody(currentProgram, function, monitor);
        }
        if (!function.getName().equals(name)) {
            function.setName(name, SourceType.USER_DEFINED);
        }
        if (!type.isEmpty()) {
            FunctionDefinition signature = type.contains("(")
                ? parseSignature(name, type)
                : (FunctionDefinition) lookup(type);
            ApplyFunctionSignatureCmd command = new ApplyFunctionSignatureCmd(address, signature,
                SourceType.USER_DEFINED, false, FunctionRenameOption.NO_CHANGE);
            if (!command.applyTo(currentProgram, monitor)) {
                throw new Exception("signature not applied: " + command.getStatusMsg());
            }
            typed++;
        }
        if (!comment.isEmpty()) {
            function.setComment(comment);
        }
        functions++;
    }

    private void labelData(Address address, String name, String type, String comment) throws Exception {
        if (!type.isEmpty()) {
            DataUtilities.createData(currentProgram, address, parseType(type), -1,
                DataUtilities.ClearDataMode.CLEAR_ALL_CONFLICT_DATA);
            typed++;
        }
        SymbolTable symbols = currentProgram.getSymbolTable();
        Symbol existing = symbols.getGlobalSymbol(name, address);
        Symbol symbol = existing != null ? existing : symbols.createLabel(address, name, SourceType.USER_DEFINED);
        if (!symbol.isPrimary()) {
            symbol.setPrimary();
        }
        // The table is the authority on the addresses it lists: a name it no longer gives goes.
        for (Symbol other : symbols.getSymbols(address)) {
            if (!other.equals(symbol) && other.getSource() == SourceType.USER_DEFINED) {
                other.delete();
            }
        }
        if (!comment.isEmpty()) {
            currentProgram.getListing().setComment(address, CommentType.PRE, comment);
        }
        labels++;
    }
}
