# Structured `-X` ldflags tests for `buildGoApplication` (the `ldflagsX` /
# `overwriteLdflagsX` params). Build with:
#   nix-build pkgs/build-support/gomod2nix/ldflags-x-test.nix
#
# `ldflagsX` is an attrset of `importpath.name -> value` that renders to
# `-X importpath.name=value` tokens appended AFTER the auto-injected
# version/commit ldflags and the raw `ldflags` list (so Go's last-wins `-X`
# makes ldflagsX authoritative). A key that collides with an already-set `-X`
# symbol throws at eval time unless `overwriteLdflagsX = true` is passed.
#
# These are eval-time assertions on `drv.ldflags`; no Go toolchain runs.
{ pkgs ? import ../../.. { } }:
let
  inherit (pkgs) lib;

  # Minimal single-module fixture (no version.env, so version falls back to
  # "dev" — keeps the auto-injected -X main.version stable across runs).
  fixture = pkgs.runCommand "ldflagsx-fixture" { } ''
    mkdir -p $out
    echo "module example.com/x" > $out/go.mod
    echo "go 1.26" >> $out/go.mod
    touch $out/go.sum
    touch $out/gomod2nix.toml
  '';

  build =
    extra:
    pkgs.buildGoApplication (
      {
        src = fixture;
        pwd = fixture;
        pname = "smoke";
      }
      // extra
    );

  # The two flags buildGoApplication always injects for this fixture.
  versionLdflags = [
    "-X main.version=dev"
    "-X main.commit=unknown"
  ];

  rendersDrv = build {
    ldflagsX = {
      "main.buildDate" = "2026-05-28";
      "main.channel" = "stable";
    };
  };

  noopDrv = build { };

  rawAndXDrv = build {
    ldflags = [ "-s" ];
    ldflagsX = {
      "main.channel" = "stable";
    };
  };

  collisionDrv = build {
    ldflagsX = {
      "main.version" = "x";
    };
  };

  rawCollisionDrv = build {
    ldflags = [ "-X x.y=1" ];
    ldflagsX = {
      "x.y" = "2";
    };
  };

  overwriteDrv = build {
    overwriteLdflagsX = true;
    ldflagsX = {
      "main.version" = "override";
    };
  };

  hasLdflag = drv: flag: builtins.elem flag drv.ldflags;
  # True when `throw` fired while forcing the ldflags list. `length` forces the
  # `++` spine (and thus the ldflagsXFlags binding), so a throw there is caught.
  throwsOnLdflags = drv: !(builtins.tryEval (builtins.length drv.ldflags)).success;

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";
in
pkgs.runCommand "ldflags-x-tests"
  {
    _ignored = [
      # ldflagsX renders one `-X k=v` per entry...
      (assert' "renders main.buildDate" (hasLdflag rendersDrv "-X main.buildDate=2026-05-28"))
      (assert' "renders main.channel" (hasLdflag rendersDrv "-X main.channel=stable"))
      # ...and is appended after the auto-injected version/commit flags.
      (assert' "ldflagsX appended last" (
        rendersDrv.ldflags == versionLdflags ++ [
          "-X main.buildDate=2026-05-28"
          "-X main.channel=stable"
        ]
      ))

      # Empty/absent ldflagsX is a no-op: ldflags == versionLdflags.
      (assert' "empty ldflagsX is a no-op" (noopDrv.ldflags == versionLdflags))

      # Raw `ldflags` and `ldflagsX` compose; non-`-X` raw flags don't collide.
      (assert' "raw + ldflagsX compose" (
        rawAndXDrv.ldflags == versionLdflags ++ [ "-s" ] ++ [ "-X main.channel=stable" ]
      ))

      # Collision with the auto-injected main.version → throws without opt-in.
      (assert' "collision with auto version throws" (throwsOnLdflags collisionDrv))

      # Collision with a raw `ldflags` `-X` → throws without opt-in.
      (assert' "collision with raw ldflags throws" (throwsOnLdflags rawCollisionDrv))

      # overwriteLdflagsX = true allows the override; ldflagsX wins by position
      # (appended last, so it's the final `-X main.version=` the linker sees).
      (assert' "overwrite opt-in does not throw" (!(throwsOnLdflags overwriteDrv)))
      (assert' "overwrite value present" (hasLdflag overwriteDrv "-X main.version=override"))
      (assert' "overwrite value wins (last)" (
        lib.last overwriteDrv.ldflags == "-X main.version=override"
      ))
    ];
  }
  "touch $out"
