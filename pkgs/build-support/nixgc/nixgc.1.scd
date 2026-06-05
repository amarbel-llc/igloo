nixgc(1) ["amarbel-llc/igloo"]

# NAME

nixgc - targeted Nix store garbage collection

# SYNOPSIS

*nixgc reap* [*--with-referrers*] [*--dry-run*] [*-v*] _store-path_...

# DESCRIPTION

*nixgc* deletes the *dead subgraph* anchored at a set of seed store paths, in one
batched *nix-store --delete*, relying on Nix's own liveness refusal as the safety
net: anything reachable from a live GC root is kept, never deleted.

It is extracted and generalized from spinclass's *internal/nixgc* (igloo#28), which
reaps the closure of worktree-resident GC roots. nixgc takes arbitrary seed paths
(typically a build's output and/or its *.drv*) and adds *--with-referrers* so it
also handles content-addressed builds, where a dead output is referenced by a
sibling *.drv* reachable only via *nix-store --referrers*, not via the requisite
closure.

# COMMANDS

## reap _store-path_...

. Compute the live keep-set: the requisite closure of every current GC root.
. Compute the seeds' requisite closure and subtract the keep-set, leaving the dead
  *outputs* (non-*.drv*). Dependency *.drv*s in the closure are never targeted.
. With *--with-referrers*, BFS over *nix-store --referrers* to collect the dead
  *.drv*s that reference those outputs (so CA outputs become deletable), stopping at
  live paths.
. *nix-store --delete* the result, retrying the remainder after each batch (nix
  fail-fasts on the first un-deletable path), until no further progress.

Seed a build's *.drv* to pull its CA output paths (its inputSrcs) into the closure;
seed its output too / instead for the input-addressed case.

# OPTIONS

*--with-referrers*
	Pull in the dead *.drv*s that reference the dead outputs. Required to delete
	content-addressed outputs (a CA output is referenced by sibling *.drv*s).

*--dry-run*, *-n*
	Print the paths that would be deleted; delete nothing.

*-v*, *--verbose*
	Stream the underlying *nix-store --delete* output to stderr.

# SAFETY

nixgc never deletes a path reachable from a live GC root — Nix refuses such deletes
and nixgc reports them as *kept*. A shared content-addressed output that another
build has rooted (e.g. a dependency two projects compile to the same store path) is
therefore kept, not deleted; a cold rebuild then re-uses it. This is intentional —
nixgc will not break a concurrent build by deleting its live inputs.

# SEE ALSO

*nix-store*(1), *godyn*(7)
