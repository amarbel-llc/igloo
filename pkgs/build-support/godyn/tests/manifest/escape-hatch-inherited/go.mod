module example.com/manifest

go 1.26

require (
	example.com/dep v0.0.0-00010101000000-000000000000
	example.com/inherited v0.0.0-00010101000000-000000000000
	github.com/google/go-cmp v0.7.0
)

replace example.com/dep => /nix/store/qjh8li0mm81m79q05921f3n35n7kmlf3-cross/dep

replace example.com/inherited => /nix/store/00000000000000000000000000000000-inherited-go-pkgs
