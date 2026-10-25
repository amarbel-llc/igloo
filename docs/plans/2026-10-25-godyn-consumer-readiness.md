# godyn consumer readiness — notes for the troupe bump (2026-10-25)

Written from igloo's side for the tier-5 troupe bump (troupe `c2dfba3` moved
to godyn with a derived graph, i.e. import-from-derivation — **R**, relayed by
circus/eager-holly). Labels: **V** observed on this host (flic, x86_64-linux)
or in this tree, **R** read in an issue, record or message, **I** inferred.
The host-side probes used two new recipes, `just explore-nix-config` and
`just explore-cache-has <drv> <store>`, both read-only.

## (a) What a consumer of a godyn package needs

| Need | Why | Status on flic |
|---|---|---|
| `ca-derivations` experimental feature | every godyn package compile is `__contentAddressed = true` (V: build-godyn-module.nix, the compile and analysis derivations); the link, install and test derivations are input-addressed | **V** on: `experimental-features = ca-derivations dynamic-derivations fetch-tree flakes impure-derivations nix-command recursive-nix` |
| import-from-derivation allowed | a go.nix / derived-graph consumer runs `godyn-gen` inside a derivation at **eval** time and imports its JSON (V: manifest.nix `withManifest`, build-godyn-module.nix graph derivation; FDR 0008 § Decision) — so `nix eval`, `nix build` and `nix flake check` of such a package all build that derivation first | **V** `allow-import-from-derivation = true` |
| a builder for the **evaluating** system | the graph derivation and the RFC 0001 merge are per-system derivations; evaluating another system's package needs a builder for that system (igloo#75, **R**; accepted limit, FDR 0008 § Decision) | **V** flic has `builders =` (none) and `system = x86_64-linux`, so flic can evaluate x86_64-linux packages only |
| the toolchain | igloo's builders compile with the registry toolchain (FDR 0012), now Go 1.27.3 (V: registry.nix, merged 212b10c); a consumer bumping igloo rebuilds its Go closure once | **V** 1.27.3 compiler built on flic 2026-10-24 and used by the gate |
| `-race` / cgo | need a `cc` (`nativeArgs.cc`) — only if troupe uses them (**R**: godyn(7); not checked for troupe) | n/a from here |

The operator's statement that every host has `ca-derivations` and IFD on is
**R** (relayed); it is **V** for flic only.

## (b) Does the krone cache serve godyn outputs and their CA realisations?

Substituters on flic (**V**, `nix config show`): `https://cache.nixos.org/`
and `https://nix.starbrandshoes.com` (trusted key `krone-cache-2:…`,
`Priority: 30`, `WantMassQuery: 1`).

Probe (**V**, 2026-10-25, `just explore-cache-has`) on a godyn CA compile
built on flic earlier the same day, `godyn-compile-example-com-mcommit`
(the igloo#91 fixture; realisation id `sha256:abf9bd40…!out`, output
`1xs8s0fc…`):

| Query against `https://nix.starbrandshoes.com` | Result |
|---|---|
| `nix-cache-info` | served |
| control: `00000000000000000000000000000000.narinfo` | **404** — the cache does not answer everything |
| `realisations/sha256:abf9bd40…!out.doi` | **200**, body `{"id": …, "outPath": "1xs8s0fc…-godyn-compile-example-com-mcommit"}` — the correct mapping |
| `1xs8s0fc….narinfo` | **200**, `CA: fixed:r:sha256:…`, `Sig: krone-cache-2:…` |

So, for an output built on flic: **the krone cache serves both the NAR and
the CA realisation record**, signed. That is exactly what a consumer host
needs to substitute a godyn output instead of rebuilding it (FDR 0007 §
Limitations said this was "not verified"; it is now verified positive for
this host's outputs, and the FDR is updated in the same change).

**Qualifier (V, 2026-10-25 15:20–15:35 UTC, `just explore-cache-has-pkg` and
`just explore-cache-has-local`):** that holds for the outputs the uploader
selects, not for everything flic builds. The two `godyn-multimod-test`
compiles built on flic around 14:30 and again in the #73 merge gate around
14:50 had no realisation on the cache at 15:20. Of 150 spinclass
`godyn-compile-*` derivations found as `.drv` files in flic's store, 148 with
a local realisation had none on the cache, 1 was fully served (realisation,
signed narinfo, fetchable NAR), 1 had never been realised here. Of troupe's
116 `godyn-compile-*` derivations in the store, all realised here, 5 were
fully served and 111 had no realisation on the cache. flic's
effective nix config has an empty `post-build-hook` (V, `just
explore-nix-config`), so the upload is not a per-build hook.

**Explained the same evening (R, circus#385, filed from circus's
`debug-cache-roots`):** the uploader is a watcher that uploaded all 347 godyn
compiles flic built; the cache runs a 6-hour GC window (circus
`krone/configuration.nix`, chosen after the uploader filled ~4–5 GB/h into a
100 GB volume) and nothing roots the compile outputs, so every one registered
before the window's edge was evicted (404 for narinfo and realisation) and
every one since was served. So the probes above measured eviction, not
selection: an output is served for roughly six hours after upload. The fixes
are circus's: pin each host's system closure (`system/flic`, circus#383),
root each deployed host's build graph (`build-graph/<host>`, circus#385),
then widen the window to a measured value with an ENOSPC guard (circus#384).
Until #383 and #385 land, a consumer host substitutes a godyn package only
within hours of the builder's upload and rebuilds the per-package closure
otherwise. `just explore-cache-has-pkg` is the acceptance probe for #385: a
compile in a rooted build graph must still be served after a sweep.

What this does **not** establish, and what needs a host:

- **How the output got there.** Something uploads flic's builds to the cache
  within hours (the fixture was built around 03:30 UTC and probed around
  03:30–04:00 UTC). A post-build hook on flic is the obvious mechanism (**I**);
  FDR 0031 in circus presumably describes it (**R**: named by the coordinator;
  not read — circus's lane).
- **Whether the host that builds troupe for a deploy uploads too.** If
  `circus deploy --input troupe` builds troupe's godyn closure on krone (or on
  the deploying host) and that host has the same hook, every target host
  substitutes; if it builds on a host without the hook, targets rebuild the
  whole per-package closure (minutes, hundreds of derivations). Check on the
  building host after the first deploy: `just explore-cache-has <troupe
  compile .drv> https://nix.starbrandshoes.com` — any `godyn-compile-*.drv`
  from `nix derivation show troupe#…` will do.
- **Realisation freshness across toolchain bumps.** A CA realisation is keyed
  by the *resolved* derivation, so a consumer whose igloo pin is on a different
  Go than the uploader's rebuilds (correct, not a cache failure). troupe's
  igloo pin and the uploader's igloo pin should agree for substitution to hit.

igloo#82 (an input bump invalidates per-package vet closures, ~100 min gates)
is the same question from the other side: shared vet runs substitute only if
the building host uploads them and the consumer's resolved derivations match.

## (c) igloo#33 and igloo#75 during `circus deploy --input troupe`

**igloo#33 (godyn on darwin / aarch64), R from the issue:**

- Part 1, CA output stranding on darwin after an interrupted build: root-caused
  (an unregistered `_nixbld`-owned scratch dir at the deterministic output
  path), cleanup procedure recorded, upstream report DeterminateSystems
  nix-src#487; igloo added a writability probe with an actionable message.
  darwin only.
- Part 2, committed graphs are platform-specific: **shipped** as per-system
  `graphFiles` (84d0ab6) — and moot for a consumer with a **derived** graph,
  which is generated on the evaluating system (FDR 0008 § Decision). troupe
  has a derived graph (**R**), so part 2 does not apply to it.
- Remaining: running the godyn fixtures on a real darwin/aarch64 builder.
  godyn's default (`buildGoAuto` with no strategy) is godyn on every
  `godynSystems` system (V: build-go-auto.nix:90), unvalidated off
  x86_64-linux.

**igloo#75 (per-system IFD), R:** evaluating a goFlakeInputs or go.nix package
for system B from a host of system A needs a builder for B. Accepted (FDR
0008). It bites a deploy only when the deploying host evaluates a target of a
different system without a builder for it.

**Who would hit them (I, pending the hosts' systems — circus's record):**

- flic: x86_64-linux (**V**), no remote builders (**V**). It can evaluate and
  build troupe for x86_64-linux targets only. Neither #33 nor #75 applies to
  an x86_64-linux target.
- nikulin, krone: systems **not known from here**. If both are x86_64-linux,
  nothing in #33/#75 is reached by the deploy. If either is aarch64-linux or
  darwin: #75 is hit the moment flic evaluates its troupe (no builder), and
  #33's remaining validation gap applies to the build itself.
- The operator's Mac does not build clown or troupe (**R**), so the one darwin
  host is out of scope for this bump.

What to verify before the bump, one line each: the three hosts' `nix config
show system`, their `experimental-features` (must include `ca-derivations`)
and `allow-import-from-derivation`; which host builds for the deploy; whether
that host uploads to the cache (probe above after a build). All read-only.
