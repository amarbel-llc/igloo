# vm-tests — NixOS VM integration checks for fleet repos (FDR 0011, vm-tests(7)).
#
# Wraps pkgs.testers.runNixOSTest with the settings every repo would otherwise
# repeat: Linux-only (the attrset is empty elsewhere, so darwin never evaluates
# the test driver), no KVM requirement (the fleet's build hosts have no
# /dev/kvm; the guest runs under TCG), and TCG-sized defaults for memory, cores
# and the global timeout. A shared Python prelude gives test scripts the two
# helpers every lane wrote by hand.
{
  lib,
  stdenv,
  testers,
}:
let
  # Python (the nixos-test-driver testScript language) prepended to a script.
  # Defines, for the driver's default `machine` unless one is passed:
  #   wait_for_units(units, m=None)        wait for every unit in the list
  #   journal_count(unit, needle, m=None)  occurrences of needle in a unit's journal
  # Written to pass the driver's ruff lint and ty type check (a script that
  # fails either fails the build).
  prelude = ''
    def wait_for_units(units, m=None):
        node = m if m is not None else machine
        for unit in units:
            node.wait_for_unit(unit)


    def journal_count(unit, needle, m=None):
        node = m if m is not None else machine
        out = node.succeed(f"journalctl -u {unit} --no-pager -o cat || true")
        return out.count(needle)


  '';

  # tests: { <name> = <runNixOSTest module>; … }. Each module gets `name` (its
  # attribute name), `requiredFeatures.kvm`, `globalTimeout` and per-node
  # virtualisation defaults as mkDefault, so a test may still override any of
  # them; `defaults` is merged into every node (a per-repo stack module goes
  # here). Returns the derivations keyed by name, or { } on non-Linux hosts.
  mkVmChecks =
    {
      tests,
      kvm ? false,
      memorySize ? 2048,
      cores ? 2,
      globalTimeout ? 3600,
      defaults ? { },
    }:
    lib.optionalAttrs stdenv.isLinux (
      lib.mapAttrs (
        name: test:
        testers.runNixOSTest {
          imports = [ test ];
          name = lib.mkDefault name;
          requiredFeatures.kvm = lib.mkDefault kvm;
          globalTimeout = lib.mkDefault globalTimeout;
          defaults = {
            imports = [ defaults ];
            virtualisation.memorySize = lib.mkDefault memorySize;
            virtualisation.cores = lib.mkDefault cores;
          };
        }
      ) tests
    );
in
{
  inherit mkVmChecks;
  vmTestPrelude = prelude;
}
