# The default -A of godyn-go and godyn-test (RFC 0003, igloo#92): given the
# attrset at the flake's packages.<system>, `go-module` when the flake exposes
# the canonical module output, else `default` so pre-RFC flakes keep working.
# A pure function, so its table is a flake check (godyn-cli-pick-attr-test)
# and both CLIs evaluate the same expression.
packages: if packages ? go-module then "go-module" else "default"
