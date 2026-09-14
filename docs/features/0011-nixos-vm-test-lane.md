---
status: experimental
date: 2026-09-14
promotion-criteria: |
  experimental → testing: a second repo adopts mkVmChecks + vmTestPrelude
  for a real scenario (piggy is the first, its three lanes pre-dating the
  library), and the fleet defaults (TCG sizing, timeout) hold on the shared
  build host without per-repo overrides.

  testing → accepted: no lever adjustment needed for a release cycle, and
  every VM-testing repo uses the library rather than its own wrapper.
---

# NixOS VM test lane

## Problem Statement

A repo's unit and bats lanes never run its shipped closure on a real system:
daemons as systemd units, block devices, sshd, kernel modules. piggy needed
that to gate its LUKS, ZFS and agent ports and wrote the first `nixosTest`
lane in the fleet (piggy branch fresh-beech, `nix/vm-tests/`). Its
repo-agnostic parts — the Linux-only guard, the no-KVM declaration, the
TCG-sized defaults, and two Python helpers — are twenty lines every next
repo would copy, and the gotchas that cost time (the driver's linting, the
backdoor's `DISPLAY`, argon2 under emulation) would be rediscovered.

## Interface

- `pkgs.mkVmChecks { tests; defaults ? { }; kvm ? false; memorySize ? 2048;
  cores ? 2; globalTimeout ? 3600; }` — `tests` maps check names to
  `runNixOSTest` modules; `defaults` is a NixOS module merged into every node
  (the repo's stack). Returns the check derivations keyed by name, or `{ }`
  on non-Linux hosts, so it merges into `checks.<system>` without a guard.
  Every default is `mkDefault`, so a test overrides any of them; `name`
  defaults to the attribute name.
- `pkgs.vmTestPrelude` — Python prepended to a `testScript`:
  `wait_for_units(units, m=None)` and `journal_count(unit, needle, m=None)`.
- vm-tests(7) — the manpage, including the justfile conventions (leaf
  `test-vm-<noun>` recipes, a Linux-only aggregate hooked into `test`, a
  dry-run tripwire) and the gotchas.

## Examples

    checks = pkgs.mkVmChecks {
      defaults = import ./nix/vm-tests/myapp-stack.nix { inherit pkgs myapp; };
      tests.vm-myapp-luks = import ./nix/vm-tests/luks.nix { … };
    };

igloo's own `vm-tests-smoke` check boots a guest under TCG, exercises both
helpers, proves `defaults` reached the node and that a test's own
`globalTimeout` wins.

## Limitations

- **One VM boot per check, minutes each under TCG.** `nix flake check` boots
  every lane in `checks`; repos keep the count to what a unit lane cannot
  cover. igloo pays one boot in its own gate for the smoke test.
- **Linux only.** darwin hosts get `{ }`; the lanes run on the Linux build
  host (and, later, a Linux builder from darwin).
- **What stays in the repo:** the stack module, fixture or store setup in the
  script, the scenarios, and any askpass discipline (documented in the
  manpage, not code).

## Tuning Levers

| Lever | Current | Rationale | Change signal |
|---|---|---|---|
| memorySize | 2048 MiB | piggy's lanes under TCG | a lane OOMs, or hosts gain RAM headroom |
| cores | 2 | TCG scales poorly past that on the shared host | measured lane time improves with more |
| globalTimeout | 3600 s | a TCG boot plus a multi-subtest script is minutes | lanes time out, or a KVM host arrives |
| kvm | false | build hosts have no /dev/kvm | a KVM-capable builder joins the fleet |

## More Information

- piggy `nix/vm-tests/` (branch fresh-beech, 2026-09-14) — the reference
  implementation and first consumer; relayed by piggy/fresh-beech/coco.
- `pkgs/build-support/vm-tests/` — the library and vm-tests(7).
