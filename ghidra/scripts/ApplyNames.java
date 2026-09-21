// Applies names and comments from tables of address, kind, name and comment.
//
// Each argument is a tab-separated file. A row names a function (created if the address has
// none) or labels data, and its optional comment becomes the function's plate comment or the
// data's pre comment. Lines starting with '#' and blank lines are skipped, as are addresses the
// program does not contain, so one table can cover a group holding several programs.
//
// Names are applied as user-defined, which DefineVmHandlers leaves alone. Re-running is harmless:
// a row whose name is already in place changes nothing.
//
//@category StarLancer

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.CommentType;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolTable;

public class ApplyNames extends GhidraScript {

    private int functions;
    private int labels;
    private int skipped;
    private int failed;

    @Override
    protected void run() throws Exception {
        String[] tables = getScriptArgs();
        if (tables.length == 0) {
            println("usage: ApplyNames.java <table.tsv>...");
            return;
        }
        for (String table : tables) {
            apply(Path.of(table));
        }
        println(String.format("%s: %d functions and %d labels named, %d rows not in this program, %d failed",
            currentProgram.getName(), functions, labels, skipped, failed));
    }

    private void apply(Path table) throws Exception {
        List<String> lines = Files.readAllLines(table);
        for (String line : lines) {
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
            String comment = fields.length > 3 ? fields[3].trim() : "";
            try {
                switch (kind) {
                    case "function" -> nameFunction(address, name, comment);
                    case "data" -> labelData(address, name, comment);
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

    private void nameFunction(Address address, String name, String comment) throws Exception {
        Function function = getFunctionAt(address);
        if (function == null) {
            function = createFunction(address, name);
            if (function == null) {
                throw new Exception("no function could be created");
            }
        }
        if (!function.getName().equals(name)) {
            function.setName(name, SourceType.USER_DEFINED);
        }
        if (!comment.isEmpty()) {
            function.setComment(comment);
        }
        functions++;
    }

    private void labelData(Address address, String name, String comment) throws Exception {
        SymbolTable symbols = currentProgram.getSymbolTable();
        Symbol existing = symbols.getGlobalSymbol(name, address);
        Symbol symbol = existing != null ? existing : symbols.createLabel(address, name, SourceType.USER_DEFINED);
        if (!symbol.isPrimary()) {
            symbol.setPrimary();
        }
        if (!comment.isEmpty()) {
            currentProgram.getListing().setComment(address, CommentType.PRE, comment);
        }
        labels++;
    }
}
