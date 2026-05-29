// Lint fixture: process.exit() allowed via per-line escape hatch.
process.stdout.write("about to exit\n");
// eslint-disable-next-line n/no-process-exit
process.exit(0);
