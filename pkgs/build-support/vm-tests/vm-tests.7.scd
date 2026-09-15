vm-tests(7) ["amarbel-llc/igloo"]

# NAME

vm-tests - NixOS VM integration checks for fleet repositories

# DESCRIPTION

*mkVmChecks* wraps *pkgs.testers.runNixOSTest* with the settings every fleet
repository would otherwise repeat, and *vmTestPrelude* is a shared Python
prefix for test scripts. A VM check boots a NixOS guest carrying the repo's
shipped package, runs its daemons as systemd units, and drives them from the
test driver's Python script — the end-to-end validation a bats or unit lane
cannot give (FDR 0011; piggy's LUKS, ZFS and agent lanes are the reference).

The fleet defaults encode what the build hosts are: no */dev/kvm* (the guest
runs under TCG, a boot is minutes, not seconds), Linux only (darwin cannot run
the driver, so the attrset is empty there and evaluation never touches it),
and TCG-sized memory, cores and timeout.

# mkVmChecks

```
checks = pkgs.mkVmChecks {
  # every runNixOSTest module, keyed by check name
  tests = {
    vm-myapp-smoke = { nodes.machine = { }; testScript = pkgs.vmTestPrelude + '''…'''; };
    vm-myapp-luks  = import ./nix/vm-tests/luks.nix { … };
  };
  # a NixOS module merged into EVERY node: the repo's "stack" (its daemons as
  # systemd units, its package on PATH, disk images, …)
  defaults = import ./nix/vm-tests/myapp-stack.nix { inherit pkgs myapp; };
  # fleet defaults, shown; each test may still override them
  kvm = false; memorySize = 2048; cores = 2; globalTimeout = 3600;
};
```

Merge the result into *checks.<system>* (it is *{ }* on non-Linux hosts, so
no guard is needed at the call site). Every value is set with *mkDefault*, so
a test module that states its own *globalTimeout* or a node's
*virtualisation.memorySize* wins. *name* defaults to the attribute name. With
*kvm = false* every node also gets *boot.kernelParams = [ "no_timer_check" ]*
(the guest's timer check fails spuriously under TCG).

*defaults* is one module for every test; a test that needs its own stack on
top (a different daemon argv or seed per lane) adds it in the test module's
own *defaults.imports* — the two merge, as piggy's per-lane stacks do — so
one shared node module plus per-test additions is the expected shape.

Keep repo-specific pieces in the repo: the stack module, the store or fixture
setup a script needs, and the scenarios. Only the wrapper and the prelude are
igloo's.

# vmTestPrelude

Prepend *pkgs.vmTestPrelude* to a *testScript*. It defines:

- *wait_for_units(units, m=None)* — *wait_for_unit* on each name in the list.
- *journal_count(unit, needle, m=None)* — how many times *needle* occurs in
  the unit's journal (via *journalctl -u <unit> -o cat*); the shape for
  "this operation happened exactly N times" assertions.

Both act on the driver's default *machine* unless a node is passed as *m*.

# CONVENTIONS

The justfile shape (conformist-justfile(7)): one leaf recipe per check,
*test-vm-<noun>*, running *nix build .#checks.<system>.<check>* with
*--no-link --print-build-logs*; a *[linux]* / *[macos]* aggregate pair
*\_test-vm-linux-only* hooked into *test* (the macos body is a no-op); and a
*debug-vm-dry-run check=…* recipe running *nix build --dry-run* — the
cache-miss tripwire for a guest that pulls in a kernel module (ZFS).

Anything that might prompt (an askpass, a PIN) must be pinned inside the
guest: re-home the test askpass into the store with *writeShellScript* and
run commands with *SSH_ASKPASS_REQUIRE=force SSH_ASKPASS=<store path> DISPLAY=*,
because the backdoor shell exports *DISPLAY=:0.0* and a misrouted prompt
would otherwise hang on a GUI that does not exist.

# GOTCHAS

- The driver lints the script with ruff and type-checks it with ty; an
  f-string without placeholders (F541) fails the build.
- *virtualisation.emptyDiskImages* gives a real block device (*/dev/vdb*) —
  prefer it to loop files, which need the loop module.
- argon2id is hostile under TCG: use *--pbkdf pbkdf2 --pbkdf-force-iterations*
  in LUKS tests, as upstream's do with *--iter-time=1*.
- *nix flake check* boots every VM in *checks*: budget minutes per lane, and
  keep the count to the scenarios a unit lane cannot cover.
- A TCG guest on a host under memory or load pressure can hang rather than
  fail (a guest ssh login that never completes), and then costs the full
  *globalTimeout*. The library has no host guard; run VM lanes on an idle
  host, or lower *globalTimeout* per test when a lane is known to be short.

# SEE ALSO

*godyn*(7), FDR 0011 (docs/features/0011-nixos-vm-test-lane.md).
