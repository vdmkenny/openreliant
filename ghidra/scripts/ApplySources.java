// Groups the payload's code by the source file it was compiled from, as a program tree named
// Sources: a module for each directory of the original tree and a fragment for each file, holding
// the code known to be that file's; the stretches between two files, which hold the end of one,
// the start of the next or files whose paths the binary does not hold, under `unplaced`; and the C
// runtime. Code outside every row stays in the fragments of its memory block.
//
//   ApplySources.java <sources.tsv>
//
// Each row of <sources.tsv>, which `ghidragen sources` writes from src/lancer/sources.zig, is a
// start address, an end address (exclusive) and the fragment's path in the tree, its modules and
// name separated by '/'. The tree is built afresh each run.
//
//@category StarLancer

import java.nio.file.Files;
import java.nio.file.Path;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Group;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.listing.ProgramFragment;
import ghidra.program.model.listing.ProgramModule;

public class ApplySources extends GhidraScript {

    private static final String TREE = "Sources";

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1) {
            println("usage: ApplySources.java <sources.tsv>");
            return;
        }
        Listing listing = currentProgram.getListing();
        if (listing.getRootModule(TREE) != null) {
            listing.removeTree(TREE);
        }
        ProgramModule root = listing.createRootModule(TREE);

        int fragments = 0;
        for (String line : Files.readAllLines(Path.of(args[0]))) {
            if (line.isBlank() || line.startsWith("#")) {
                continue;
            }
            String[] fields = line.split("\t");
            long start = Long.parseLong(fields[0], 16);
            long end = Long.parseLong(fields[1], 16);
            String[] path = fields[2].split("/");

            ProgramModule module = root;
            for (int i = 0; i < path.length - 1; i++) {
                module = child(module, path[i]);
            }
            ProgramFragment fragment = module.createFragment(path[path.length - 1]);
            fragment.move(toAddr(start), toAddr(end - 1));
            fragments++;
        }
        println(currentProgram.getName() + ": " + fragments + " fragments in the " + TREE + " tree");
    }

    private static ProgramModule child(ProgramModule parent, String name) throws Exception {
        for (Group group : parent.getChildren()) {
            if (group instanceof ProgramModule module && module.getName().equals(name)) {
                return module;
            }
        }
        return parent.createModule(name);
    }
}
