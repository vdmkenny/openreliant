// Creates a function at every entry of the mission script VM's opcode handler table.
//
// Nothing in the image calls the handlers directly: the interpreter reaches them only through the
// table, so auto-analysis leaves most of them undefined and they never reach the decompiler. This
// defines each one and names it after the opcode it serves.
//
// The table runs from its start to the first entry that is neither null nor a code address; past
// that point the data belongs to another structure, whose values can look like code addresses.
// That is the same rule src/tools/vmgen applies. A `vm_op_` name on any function that is not the
// handler for its opcode is cleared, so running this again corrects a project it named wrongly.
// Functions that already have a name, such as those ApplyNames gives the handlers, are left alone.
//
//@category StarLancer

import java.util.regex.Matcher;
import java.util.regex.Pattern;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.SourceType;

public class DefineVmHandlers extends GhidraScript {

    /// The interpreter indexes this table by opcode byte: see FUN_0045c980.
    private static final long TABLE = 0x004F6350L;
    /// The most a byte-indexed table could hold. The real one ends earlier.
    private static final int MAX_ENTRIES = 256;
    private static final Pattern HANDLER_NAME = Pattern.compile("vm_op_([0-9a-f]{2})");

    @Override
    protected void run() throws Exception {
        MemoryBlock text = currentProgram.getMemory().getBlock(".text");
        if (text == null) {
            println("no .text block: not the payload, nothing to do");
            return;
        }
        // The group holds more than one program; only the payload carries this table.
        if (!currentProgram.getMemory().contains(toAddr(TABLE))) {
            println("no handler table in " + currentProgram.getName() + ", nothing to do");
            return;
        }

        Address[] handlers = new Address[MAX_ENTRIES];
        int length = 0;
        for (int opcode = 0; opcode < MAX_ENTRIES; opcode++) {
            long value = currentProgram.getMemory().getInt(toAddr(TABLE + opcode * 4L)) & 0xFFFFFFFFL;
            if (value == 0) {
                continue;
            }
            Address target = toAddr(value);
            if (!text.contains(target)) {
                break;
            }
            handlers[opcode] = target;
            length = opcode + 1;
        }

        int defined = 0;
        int existing = 0;
        for (int opcode = 0; opcode < length; opcode++) {
            monitor.checkCancelled();
            Address target = handlers[opcode];
            if (target == null) {
                continue;
            }
            String name = String.format("vm_op_%02x", opcode);
            Function function = getFunctionAt(target);
            if (function == null) {
                function = createFunction(target, name);
                if (function == null) {
                    println("could not create a function at " + target + " for opcode " + name);
                    continue;
                }
                defined++;
            } else {
                existing++;
            }
            // Name only a function that has no name yet: ApplyNames gives handlers user-defined
            // names, and those stay.
            if (function.getSymbol().getSource() == SourceType.DEFAULT) {
                function.setName(name, SourceType.ANALYSIS);
            }
        }

        int cleared = 0;
        for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
            Matcher match = HANDLER_NAME.matcher(function.getName());
            if (!match.matches()) {
                continue;
            }
            int opcode = Integer.parseInt(match.group(1), 16);
            Address handler = opcode < length ? handlers[opcode] : null;
            if (handler == null || !handler.equals(function.getEntryPoint())) {
                function.setName(null, SourceType.DEFAULT);
                cleared++;
            }
        }

        println(String.format(
            "VM handler table: %d entries; %d handlers defined, %d already present, %d stray names cleared",
            length, defined, existing, cleared));
    }
}
