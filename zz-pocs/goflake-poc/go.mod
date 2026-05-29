module github.com/amarbel-llc/goflake-poc

go 1.23

require github.com/poc/lib v0.0.0-00010101000000-000000000000

replace github.com/poc/lib => ./.flake-inputs/poc-lib
