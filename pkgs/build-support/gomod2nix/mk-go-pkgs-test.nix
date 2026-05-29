# Smoke tests for mkGoPkgs (RFC 0001 § Producer interface).
# Build with: nix-build pkgs/build-support/gomod2nix/mk-go-pkgs-test.nix
{ pkgs ? import ../../.. { } }:
let
  # Realistic fixture exercising:
  #   - prod Go file (cmd/example/main.go)
  #   - test Go file (cmd/example/main_test.go)
  #   - module files (go.mod, go.sum, gomod2nix.toml)
  #   - workspace files (go.work, go.work.sum)
  #   - sub-module go.mod/go.sum at libs/dewey/ (amarbel-llc/nixpkgs#47)
  #   - root-anchored testdata/ (testdata/golden.txt)
  #   - nested testdata/ (internal/foo/testdata/cases.json)
  #   - testdata go.mod fixture that MUST stay out of prod
  #     (internal/foo/testdata/fixturemod/go.mod)
  #   - non-Go file the filter should drop (README.md)
  fixture = pkgs.runCommand "mk-go-pkgs-fixture" { } ''
    mkdir -p $out/cmd/example
    echo "package main" > $out/cmd/example/main.go
    echo "package main" > $out/cmd/example/main_test.go
    echo "module example.com/x" > $out/go.mod
    touch $out/go.sum
    touch $out/gomod2nix.toml
    echo "go 1.26" > $out/go.work
    touch $out/go.work.sum
    echo "# README" > $out/README.md

    # Sub-module under a go.work `use ./libs/dewey` directive (#47).
    mkdir -p $out/libs/dewey
    echo "module example.com/x/libs/dewey" > $out/libs/dewey/go.mod
    touch $out/libs/dewey/go.sum
    echo "package dewey" > $out/libs/dewey/dewey.go

    mkdir -p $out/testdata
    echo "golden" > $out/testdata/golden.txt

    mkdir -p $out/internal/foo
    echo "package foo" > $out/internal/foo/foo.go
    mkdir -p $out/internal/foo/testdata
    echo '{"k":"v"}' > $out/internal/foo/testdata/cases.json

    # testdata-resident go.mod fixture — MUST NOT be promoted into prod
    # by the relaxed isModuleFile predicate (#47).
    mkdir -p $out/internal/foo/testdata/fixturemod
    echo "module example.com/fixturemod" > $out/internal/foo/testdata/fixturemod/go.mod

    # #31: version.env files. The producer's filtered tree must keep
    # them so buildGoApplication's version.env auto-read finds the
    # package-local file when a producer self-consumes go-pkgs(-test).
    # Kept by basename anywhere EXCEPT under testdata/ — a testdata
    # fixture's version.env must not be promoted into prod.
    echo "export EXAMPLE_VERSION=1.2.3" > $out/version.env
    echo "export DEWEY_VERSION=0.2.4" > $out/libs/dewey/version.env
    echo "export FIXTURE_VERSION=9.9.9" > $out/internal/foo/testdata/version.env

    # #60: //go:embed prod assets — the asset under templates/ must be
    # kept in both outputs when the caller passes a matching `extras`
    # regex. Until go2nix can derive these from the AST, adopters
    # maintain `extras` by hand alongside the //go:embed directive.
    mkdir -p $out/cmd/example/templates
    echo "package main" > $out/cmd/example/embed_prod.go
    echo "" >> $out/cmd/example/embed_prod.go
    echo "//go:embed templates/hello.tmpl" >> $out/cmd/example/embed_prod.go
    echo "var _ = \"stub\"" >> $out/cmd/example/embed_prod.go
    echo "hi" > $out/cmd/example/templates/hello.tmpl

    # #60: //go:embed test-only assets — the directive lives in a
    # *_test.go file and the asset is needed only by go-pkgs-test, so
    # the caller routes it through `testExtras` rather than `extras`.
    mkdir -p $out/cmd/example/fixtures
    echo "package main" > $out/cmd/example/embed_more_test.go
    echo "" >> $out/cmd/example/embed_more_test.go
    echo "//go:embed fixtures/cases.json" >> $out/cmd/example/embed_more_test.go
    echo "var _ = \"stub\"" >> $out/cmd/example/embed_more_test.go
    echo "{}" > $out/cmd/example/fixtures/cases.json
  '';

  built = pkgs.mkGoPkgs { src = fixture; };
  builtWithExtras = pkgs.mkGoPkgs {
    src = fixture;
    extras = [ "^README\\.md$" ];
    testExtras = [ "^.*\\.fixtures$" ]; # synthetic, fixture has none
  };

  # #60: documents the manual //go:embed pattern. Mirrors the example
  # in mkGoPkgs(7). When go2nix-style AST analysis is available these
  # patterns should come for free.
  builtWithEmbedExtras = pkgs.mkGoPkgs {
    src = fixture;
    extras = [ "^cmd/example/templates/.*$" ];
    testExtras = [ "^cmd/example/fixtures/.*$" ];
  };

  # #36: a producer that itself depends on cross-flake Go modules
  # SHOULD attach its goFlakeInputs as passthru on both outputs so
  # downstream consumers' bridge inherits them at depth-1.
  passthruInputs = {
    "github.com/inherited/dep1" = {
      src = "/nix/store/dep1";
      subPath = "go";
    };
    "github.com/inherited/dep2" = "/nix/store/dep2";
  };
  builtWithPassthru = pkgs.mkGoPkgs {
    src = fixture;
    goFlakeInputs = passthruInputs;
  };
  builtNoPassthru = pkgs.mkGoPkgs { src = fixture; }; # control

  # #49: name override + go.mod inference.
  # The fixture is a runCommand derivation, which has `.name =
  # "mk-go-pkgs-fixture"`. With no `name` override, `src.name`
  # precedence wins → "mk-go-pkgs-fixture-go-pkgs". To exercise the
  # go.mod inference branch (the typical adopter case where
  # `src = self + "/go"` is a string with no `.name`), coerce the
  # fixture to a string via interpolation.
  builtWithExplicitName = pkgs.mkGoPkgs {
    src = fixture;
    name = "madder";
  };
  builtFromString = pkgs.mkGoPkgs {
    src = "${fixture}"; # string-coerced — no .name attribute
  };

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";

  inherit (pkgs.lib) isDerivation;

  prodTopFiles = builtins.attrNames (builtins.readDir built.go-pkgs);
  prodHasNested = builtins.pathExists "${built.go-pkgs}/internal/foo/foo.go";
  # testdata directories are always preserved (the empty-directory
  # leakthrough documented in goSourceFilter); what MUST be filtered is
  # the specific files inside them.
  prodHasRootTestdataFile = builtins.pathExists "${built.go-pkgs}/testdata/golden.txt";
  prodHasNestedTestdataFile =
    builtins.pathExists "${built.go-pkgs}/internal/foo/testdata/cases.json";
  prodHasMainTest = builtins.pathExists "${built.go-pkgs}/cmd/example/main_test.go";

  # Sub-module workspace files (#47).
  prodHasSubModuleGoMod = builtins.pathExists "${built.go-pkgs}/libs/dewey/go.mod";
  prodHasSubModuleGoSum = builtins.pathExists "${built.go-pkgs}/libs/dewey/go.sum";
  prodHasSubModuleGo = builtins.pathExists "${built.go-pkgs}/libs/dewey/dewey.go";

  # Testdata-resident go.mod fixture MUST stay out of prod (#47 negative).
  prodHasTestdataGoMod =
    builtins.pathExists "${built.go-pkgs}/internal/foo/testdata/fixturemod/go.mod";

  # version.env kept in both outputs by basename, dropped under testdata (#31).
  prodHasRootVersionEnv = builtins.pathExists "${built.go-pkgs}/version.env";
  prodHasSubVersionEnv = builtins.pathExists "${built.go-pkgs}/libs/dewey/version.env";
  prodHasTestdataVersionEnv =
    builtins.pathExists "${built.go-pkgs}/internal/foo/testdata/version.env";
  testHasRootVersionEnv = builtins.pathExists "${built.go-pkgs-test}/version.env";
  testHasSubVersionEnv = builtins.pathExists "${built.go-pkgs-test}/libs/dewey/version.env";

  testTopFiles = builtins.attrNames (builtins.readDir built.go-pkgs-test);
  testHasMainTest = builtins.pathExists "${built.go-pkgs-test}/cmd/example/main_test.go";
  testHasNestedTestdata = builtins.pathExists "${built.go-pkgs-test}/internal/foo/testdata/cases.json";
  testHasRootTestdata = builtins.pathExists "${built.go-pkgs-test}/testdata/golden.txt";

  extrasProdHasReadme = builtins.pathExists "${builtWithExtras.go-pkgs}/README.md";
  extrasTestHasReadme = builtins.pathExists "${builtWithExtras.go-pkgs-test}/README.md";

  # #60: default mkGoPkgs drops //go:embed assets — they only survive
  # when the caller supplies a matching `extras` / `testExtras` regex.
  defaultProdHasEmbedTmpl =
    builtins.pathExists "${built.go-pkgs}/cmd/example/templates/hello.tmpl";
  defaultTestHasEmbedJson =
    builtins.pathExists "${built.go-pkgs-test}/cmd/example/fixtures/cases.json";

  # #60: manual extras for //go:embed — the recommended workaround
  # while go2nix-style AST scanning is out of scope.
  embedExtrasProdHasTmpl =
    builtins.pathExists "${builtWithEmbedExtras.go-pkgs}/cmd/example/templates/hello.tmpl";
  embedExtrasProdHasTestJson =
    builtins.pathExists "${builtWithEmbedExtras.go-pkgs}/cmd/example/fixtures/cases.json";
  embedExtrasTestHasTmpl =
    builtins.pathExists "${builtWithEmbedExtras.go-pkgs-test}/cmd/example/templates/hello.tmpl";
  embedExtrasTestHasJson =
    builtins.pathExists "${builtWithEmbedExtras.go-pkgs-test}/cmd/example/fixtures/cases.json";
in
pkgs.runCommand "mk-go-pkgs-tests"
  {
    _ignored = [
      # Schema-acceptance regression: both outputs must be real
      # derivations so they pass `nix flake check` (cf. #38, #44).
      (assert' "type: go-pkgs is a derivation" (isDerivation built.go-pkgs))
      (assert' "type: go-pkgs-test is a derivation" (isDerivation built.go-pkgs-test))

      # go-pkgs keeps the prod surface.
      (assert' "prod: keeps go.mod" (builtins.elem "go.mod" prodTopFiles))
      (assert' "prod: keeps go.sum" (builtins.elem "go.sum" prodTopFiles))
      (assert' "prod: keeps go.work" (builtins.elem "go.work" prodTopFiles))
      (assert' "prod: keeps go.work.sum" (builtins.elem "go.work.sum" prodTopFiles))
      (assert' "prod: keeps gomod2nix.toml" (builtins.elem "gomod2nix.toml" prodTopFiles))
      (assert' "prod: keeps cmd/example/main.go" prodHasNested)

      # #47: sub-module workspace files must be kept.
      (assert' "prod: keeps libs/dewey/go.mod (#47)" prodHasSubModuleGoMod)
      (assert' "prod: keeps libs/dewey/go.sum (#47)" prodHasSubModuleGoSum)
      (assert' "prod: keeps libs/dewey/dewey.go" prodHasSubModuleGo)

      # go-pkgs drops the test surface (file contents — directories
      # may persist empty as a goSourceFilter-shared leakthrough).
      (assert' "prod: drops cmd/example/main_test.go" (! prodHasMainTest))
      (assert' "prod: drops testdata/golden.txt" (! prodHasRootTestdataFile))
      (assert' "prod: drops testdata/cases.json" (! prodHasNestedTestdataFile))
      # #47 negative: testdata-resident go.mod must NOT be promoted.
      (assert' "prod: drops testdata/fixturemod/go.mod (#47 negative)"
        (! prodHasTestdataGoMod))
      (assert' "prod: drops README.md (no extras)"
        (! (builtins.elem "README.md" prodTopFiles)))

      # #31: version.env kept in both outputs (so a self-consuming
      # producer's buildGoApplication auto-read finds the package-local
      # file), but a testdata fixture's version.env must not reach prod.
      (assert' "#31: prod keeps root version.env" prodHasRootVersionEnv)
      (assert' "#31: prod keeps libs/dewey/version.env" prodHasSubVersionEnv)
      (assert' "#31: prod drops testdata/version.env" (! prodHasTestdataVersionEnv))
      (assert' "#31: test keeps root version.env" testHasRootVersionEnv)
      (assert' "#31: test keeps libs/dewey/version.env" testHasSubVersionEnv)

      # go-pkgs-test is a superset.
      (assert' "test: keeps cmd/example/main_test.go" testHasMainTest)
      (assert' "test: keeps nested testdata/cases.json" testHasNestedTestdata)
      (assert' "test: keeps root testdata/golden.txt" testHasRootTestdata)
      (assert' "test: still keeps go.mod" (builtins.elem "go.mod" testTopFiles))
      (assert' "test: drops README.md (no extras)"
        (! (builtins.elem "README.md" testTopFiles)))

      # extras applies to BOTH outputs.
      (assert' "extras: prod gets README.md when in extras" extrasProdHasReadme)
      (assert' "extras: test gets README.md when in extras" extrasTestHasReadme)

      # #60: default mkGoPkgs drops //go:embed assets just like any
      # other non-Go file — adopters MUST supply extras explicitly
      # until go2nix-style AST scanning can derive them.
      (assert' "#60: prod drops //go:embed asset without extras"
        (! defaultProdHasEmbedTmpl))
      (assert' "#60: test drops //go:embed asset without testExtras"
        (! defaultTestHasEmbedJson))

      # #60: manual extras pattern — prod embeds route through `extras`
      # (kept in both outputs); test-only embeds route through
      # `testExtras` (kept only in go-pkgs-test).
      (assert' "#60: extras keep prod //go:embed asset in go-pkgs"
        embedExtrasProdHasTmpl)
      (assert' "#60: testExtras do NOT leak test embed asset into go-pkgs"
        (! embedExtrasProdHasTestJson))
      (assert' "#60: extras keep prod //go:embed asset in go-pkgs-test (superset)"
        embedExtrasTestHasTmpl)
      (assert' "#60: testExtras keep test //go:embed asset in go-pkgs-test"
        embedExtrasTestHasJson)

      # #36: producer-side passthru attachment. The bridge reads this
      # at depth-1 on each direct producer; covered end-to-end in
      # internals-merge-test.nix.
      (assert' "#36: go-pkgs carries passthru.goFlakeInputs"
        (builtWithPassthru.go-pkgs.passthru.goFlakeInputs == passthruInputs))
      (assert' "#36: go-pkgs-test carries same passthru.goFlakeInputs"
        (builtWithPassthru.go-pkgs-test.passthru.goFlakeInputs == passthruInputs))
      (assert' "#36: omitting goFlakeInputs leaves passthru without the attr"
        (! builtNoPassthru.go-pkgs.passthru ? goFlakeInputs))

      # #49: name override + go.mod inference + src.name fallthrough.
      # Precedence: explicit `name` → `src.name` → go.mod inferred → "source".
      #
      # With derivation src (has .name = "mk-go-pkgs-fixture"):
      #   src.name path wins.
      (assert' "name: src.name wins when present (#49)"
        (built.go-pkgs.name == "mk-go-pkgs-fixture-go-pkgs"))
      # With explicit override:
      (assert' "name: explicit override wins over inference (#49)"
        (builtWithExplicitName.go-pkgs.name == "madder-go-pkgs"))
      (assert' "name: explicit override applies to test variant too (#49)"
        (builtWithExplicitName.go-pkgs-test.name == "madder-go-pkgs-test"))
      # With string src (no .name attr), go.mod inference kicks in.
      # Fixture's go.mod declares `module example.com/x`; last path
      # element is "x".
      (assert' "name: go.mod inference yields last module-path element (#49)"
        (builtFromString.go-pkgs.name == "x-go-pkgs"))
      (assert' "name: go.mod inference on test variant (#49)"
        (builtFromString.go-pkgs-test.name == "x-go-pkgs-test"))
    ];
  }
  "touch $out"
