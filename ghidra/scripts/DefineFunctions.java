// Defines functions at addresses that auto-analysis missed, such as code that only a table or a
// computed call reaches, leaving Ghidra's default names so they show up in an export for reading.
//
//   make ghidra-run SCRIPT=DefineFunctions.java ARGS="0x00405010 0x004069b0"
//
// Naming belongs in ghidra/names, which `make ghidra-annotate` applies and which also creates the
// functions it names; this is for looking before naming. Addresses already inside a function are
// reported and left alone.
//
//@category StarLancer

import ghidra.app.cmd.function.CreateFunctionCmd;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

public class DefineFunctions extends GhidraScript {

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length == 0) {
            println("usage: DefineFunctions.java <address>...");
            return;
        }
        for (String arg : args) {
            Address address = toAddr(arg);
            if (!currentProgram.getMemory().contains(address)) {
                println(arg + ": not in " + currentProgram.getName());
                continue;
            }
            Function containing = getFunctionContaining(address);
            if (containing != null) {
                println(arg + ": inside " + containing.getName() + " at " + containing.getEntryPoint());
                continue;
            }
            if (getInstructionAt(address) == null && !disassemble(address)) {
                println(arg + ": no code at the address");
                continue;
            }
            Function function = createFunction(address, null);
            if (function == null) {
                println(arg + ": no function could be created");
                continue;
            }
            if (function.getBody().getNumAddresses() <= 1) {
                CreateFunctionCmd.fixupFunctionBody(currentProgram, function, monitor);
            }
            println(arg + ": defined " + function.getName() + ", " + function.getBody().getNumAddresses() + " bytes");
        }
    }
}
