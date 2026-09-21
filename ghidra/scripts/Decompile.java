// Decompiles the functions at the given addresses and prints the C, for reading code that the
// export does not hold yet, such as a function only a callback reaches.
//
//   make ghidra-run SCRIPT=Decompile.java ARGS="0x004843b0"
//
// The whole-program export is `make ghidra-export`; this is for one function at a time.
//
//@category StarLancer

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

public class Decompile extends GhidraScript {

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length == 0) {
            println("usage: Decompile.java <address>...");
            return;
        }
        DecompInterface decompiler = new DecompInterface();
        try {
            if (!decompiler.openProgram(currentProgram)) {
                println("the decompiler would not open " + currentProgram.getName());
                return;
            }
            for (String arg : args) {
                Address address = toAddr(arg);
                if (!currentProgram.getMemory().contains(address)) continue;
                Function function = getFunctionContaining(address);
                if (function == null) {
                    println(arg + ": no function there");
                    continue;
                }
                DecompileResults results = decompiler.decompileFunction(function, 120, monitor);
                if (!results.decompileCompleted()) {
                    println(arg + ": " + results.getErrorMessage());
                    continue;
                }
                println("// ==== " + function.getName() + " @ " + function.getEntryPoint() + " ====");
                println(results.getDecompiledFunction().getC());
            }
        } finally {
            decompiler.dispose();
        }
    }
}
