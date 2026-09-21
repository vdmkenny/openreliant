// Lists every instruction that stores a constant into a structure field at a given offset, with
// the function it sits in and, where the constant is code, the function it points at. Finding what
// a callback field is set to is what this is for: a field the engine calls through rather than
// calling outright.
//
//   make ghidra-run SCRIPT=FindFieldStores.java ARGS="0x88"
//   make ghidra-run SCRIPT=FindFieldStores.java ARGS="0x88 0x004ab000 0x004b0000"
//
// The second form lists only the stores whose constant falls in that range, for picking the code
// pointers out of the ordinary numbers.
//
//@category StarLancer

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.lang.OperandType;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.scalar.Scalar;

public class FindFieldStores extends GhidraScript {

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length == 0) {
            println("usage: FindFieldStores.java <field-offset> [<low> <high>]");
            return;
        }
        long field = Long.decode(args[0]);
        long low = args.length > 1 ? Long.decode(args[1]) : 0;
        long high = args.length > 2 ? Long.decode(args[2]) : Long.MAX_VALUE;

        int found = 0;
        InstructionIterator instructions = currentProgram.getListing().getInstructions(true);
        while (instructions.hasNext() && !monitor.isCancelled()) {
            Instruction instruction = instructions.next();
            if (!instruction.getMnemonicString().equals("MOV")) continue;
            if (instruction.getNumOperands() < 2) continue;
            // The destination must be memory at the field's offset, and the source a constant.
            if (!writesField(instruction, field)) continue;
            Scalar value = constantOf(instruction);
            if (value == null) continue;
            long target = value.getUnsignedValue();
            if (target < low || target > high) continue;

            Address at = instruction.getAddress();
            Function in = getFunctionContaining(at);
            Address pointed = toAddr(target);
            Function points = currentProgram.getMemory().contains(pointed) ? getFunctionContaining(pointed) : null;
            println(String.format(
                "%s  in %-28s  -> 0x%08x %s",
                at,
                in == null ? "(none)" : in.getName(),
                target,
                points == null ? "" : "(" + points.getName() + (points.getEntryPoint().equals(pointed) ? ")" : " + inside)")));
            found++;
        }
        println("stores found: " + found);
    }

    /// Whether the instruction's first operand is memory written at `field` from a register.
    private boolean writesField(Instruction instruction, long field) {
        if (!OperandType.isAddress(instruction.getOperandType(0))
                && !OperandType.isDynamic(instruction.getOperandType(0))) return false;
        Object[] operands = instruction.getOpObjects(0);
        for (Object operand : operands) {
            if (operand instanceof Scalar && ((Scalar) operand).getUnsignedValue() == field) return true;
        }
        return false;
    }

    /// The constant the instruction stores, or null when it stores a register.
    private Scalar constantOf(Instruction instruction) {
        if (!OperandType.isScalar(instruction.getOperandType(1))) return null;
        Object[] operands = instruction.getOpObjects(1);
        for (Object operand : operands) {
            if (operand instanceof Scalar) return (Scalar) operand;
        }
        return null;
    }
}
