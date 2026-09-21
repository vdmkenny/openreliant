// Dumps the current program as greppable text: functions, strings, imports/exports, a per-function
// disassembly listing and the decompiler's C.
//
// Meant for headless use (`make ghidra-export`):
//
//   analyzeHeadless <dir> <project>/<folder> -process -noanalysis -readOnly \
//       -scriptPath ghidra/scripts -postScript ExportProgram.java <out-dir>
//
// Output lands in <out-dir>/<program name>/. It is derived from the game's binaries, so it lives
// under ghidra/export/, which is git-ignored.
//
//@category StarLancer

import java.io.File;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.listing.ProgramFragment;
import ghidra.program.model.listing.ProgramModule;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolTable;

public class ExportProgram extends GhidraScript {

    private static final int DECOMPILE_TIMEOUT_SECONDS = 120;

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1) {
            throw new IllegalArgumentException("usage: ExportProgram.java <out-dir>");
        }
        File outDir = new File(args[0], currentProgram.getName());
        if (!outDir.isDirectory() && !outDir.mkdirs()) {
            throw new IllegalStateException("cannot create " + outDir);
        }

        exportSegments(new File(outDir, "segments.tsv"));
        exportSymbols(new File(outDir, "imports.tsv"), new File(outDir, "exports.tsv"));
        exportStrings(new File(outDir, "strings.tsv"));
        exportFunctions(new File(outDir, "functions.tsv"));
        exportDisassembly(new File(outDir, "disassembly.asm"));
        exportDecompilation(new File(outDir, "decompiled.c"));
        println("exported " + currentProgram.getName() + " to " + outDir);
    }

    private static PrintWriter open(File file) throws Exception {
        return new PrintWriter(file, StandardCharsets.UTF_8);
    }

    /** Keeps a value on one TSV line. */
    private static String cell(String value) {
        return value.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r");
    }

    /**
     * Where the Sources tree that ApplySources builds puts an address: the path of its fragment,
     * such as game/Ai.cpp or unplaced/Ai.cpp .. aidefend.cpp, or empty without the tree.
     */
    private String source(Address address) {
        ProgramFragment fragment = currentProgram.getListing().getFragment("Sources", address);
        if (fragment == null) {
            return "";
        }
        StringBuilder path = new StringBuilder(fragment.getName());
        ProgramModule[] parents = fragment.getParents();
        while (parents.length > 0 && parents[0].getParents().length > 0) {
            path.insert(0, parents[0].getName() + "/");
            parents = parents[0].getParents();
        }
        return path.toString();
    }

    private void exportSegments(File file) throws Exception {
        try (PrintWriter out = open(file)) {
            out.println("start\tend\tsize\tflags\tinitialized\tname");
            for (MemoryBlock block : currentProgram.getMemory().getBlocks()) {
                String flags = (block.isRead() ? "r" : "-") + (block.isWrite() ? "w" : "-") + (block.isExecute() ? "x" : "-");
                out.printf("%s\t%s\t%d\t%s\t%b\t%s%n", block.getStart(), block.getEnd(), block.getSize(), flags,
                    block.isInitialized(), block.getName());
            }
        }
    }

    private void exportSymbols(File importsFile, File exportsFile) throws Exception {
        SymbolTable symbols = currentProgram.getSymbolTable();
        try (PrintWriter out = open(importsFile)) {
            out.println("address\tlibrary\tname\treferences");
            for (Symbol symbol : symbols.getExternalSymbols()) {
                monitor.checkCancelled();
                // The address worth knowing is the import thunk slot that refers to the external.
                StringBuilder slots = new StringBuilder();
                for (Reference ref : symbol.getReferences()) {
                    if (slots.length() > 0) slots.append(',');
                    slots.append(ref.getFromAddress());
                }
                out.printf("%s\t%s\t%s\t%s%n", symbol.getAddress(), symbol.getParentNamespace().getName(),
                    symbol.getName(), slots);
            }
        }
        try (PrintWriter out = open(exportsFile)) {
            out.println("address\tname");
            for (Address entry : symbols.getExternalEntryPointIterator()) {
                monitor.checkCancelled();
                Symbol primary = symbols.getPrimarySymbol(entry);
                out.printf("%s\t%s%n", entry, primary == null ? "" : primary.getName(true));
            }
        }
    }

    private void exportStrings(File file) throws Exception {
        try (PrintWriter out = open(file)) {
            out.println("address\treferences\tvalue");
            for (Data data : currentProgram.getListing().getDefinedData(true)) {
                monitor.checkCancelled();
                if (!data.hasStringValue()) continue;
                Object value = data.getValue();
                if (value == null) continue;
                out.printf("%s\t%d\t%s%n", data.getAddress(),
                    currentProgram.getReferenceManager().getReferenceCountTo(data.getAddress()), cell(value.toString()));
            }
        }
    }

    private void exportFunctions(File file) throws Exception {
        try (PrintWriter out = open(file)) {
            out.println("address\tsize\tcallers\tthunk\tname\tsignature\tsource");
            for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
                monitor.checkCancelled();
                out.printf("%s\t%d\t%d\t%b\t%s\t%s\t%s%n", function.getEntryPoint(), function.getBody().getNumAddresses(),
                    currentProgram.getReferenceManager().getReferenceCountTo(function.getEntryPoint()),
                    function.isThunk(), function.getName(true), cell(function.getPrototypeString(true, true)),
                    cell(source(function.getEntryPoint())));
            }
        }
    }

    private void exportDisassembly(File file) throws Exception {
        Listing listing = currentProgram.getListing();
        try (PrintWriter out = open(file)) {
            for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
                monitor.checkCancelled();
                out.printf("%n; ==== %s @ %s ====%n", function.getName(true), function.getEntryPoint());
                for (Instruction instruction : listing.getInstructions(function.getBody(), true)) {
                    StringBuilder bytes = new StringBuilder();
                    for (byte b : instruction.getBytes()) bytes.append(String.format("%02x", b));
                    out.printf("%s  %-24s %s%n", instruction.getAddress(), bytes, instruction);
                }
            }
        }
    }

    private void exportDecompilation(File file) throws Exception {
        DecompInterface decompiler = new DecompInterface();
        decompiler.toggleCCode(true);
        decompiler.toggleSyntaxTree(false);
        decompiler.setSimplificationStyle("decompile");
        if (!decompiler.openProgram(currentProgram)) {
            throw new IllegalStateException("decompiler: " + decompiler.getLastMessage());
        }
        try (PrintWriter out = open(file)) {
            for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
                monitor.checkCancelled();
                if (function.isThunk()) continue;
                out.printf("%n// ==== %s @ %s ====%n", function.getName(true), function.getEntryPoint());
                DecompileResults results = decompiler.decompileFunction(function, DECOMPILE_TIMEOUT_SECONDS, monitor);
                if (results.decompileCompleted()) {
                    out.print(results.getDecompiledFunction().getC());
                } else {
                    out.printf("// decompilation failed: %s%n", results.getErrorMessage());
                }
            }
        } finally {
            decompiler.dispose();
        }
    }
}
