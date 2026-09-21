// Creates a function at every entry of the mission script VM's opcode handler table.
//
// The table is an array of 256 function pointers. Nothing in the image calls its entries
// directly, so auto-analysis leaves them undefined and they never reach the decompiler; the
// interpreter reaches them only through the table. This defines each one and names it after the
// opcode it serves, which is what makes the handlers readable and, in particular, makes it
// possible to see how far each advances the instruction pointer.
//
// Entries that are null, or point outside the code section, are opcodes the VM does not implement
// and are skipped.
//
//@category StarLancer

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.MemoryBlock;

public class DefineVmHandlers extends GhidraScript {

    /// The interpreter indexes this table by opcode byte: see FUN_0045c980.
    private static final long TABLE = 0x004F6350L;
    private static final int ENTRIES = 256;

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

        int defined = 0;
        int existing = 0;
        int skipped = 0;

        for (int opcode = 0; opcode < ENTRIES; opcode++) {
            monitor.checkCancelled();
            Address slot = toAddr(TABLE + opcode * 4L);
            long value = currentProgram.getMemory().getInt(slot) & 0xFFFFFFFFL;
            Address target = toAddr(value);

            if (value == 0 || !text.contains(target)) {
                skipped++;
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
            // Several opcodes share a handler, so keep the first name and note the rest.
            if (function.getName().startsWith("vm_op_")) {
                if (!function.getName().equals(name)) {
                    function.setComment("also opcode 0x" + String.format("%02x", opcode));
                }
            } else {
                function.setName(name, ghidra.program.model.symbol.SourceType.ANALYSIS);
            }
        }

        println(String.format(
            "VM handlers: %d defined, %d already present, %d table entries with no handler",
            defined, existing, skipped));
    }
}
