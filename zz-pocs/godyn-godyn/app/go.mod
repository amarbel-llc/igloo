module example.com/app

go 1.26

require example.com/dep v0.0.0

// Dev-time resolution for `go list`/`go build`: dep's source lives beside us. At
// nix build time the dependency is supplied differently per approach — approach 1
// bridges dep's compiled archives, approach 2 sources dep from a flake input.
replace example.com/dep => ../dep
