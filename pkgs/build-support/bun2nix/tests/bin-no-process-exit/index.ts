// Lint fixture: recommended pattern, drains stdout before exit.
process.stdout.write("done\n");
process.exitCode = 0;
