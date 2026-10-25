// Package vetxtests is clean under vet, and so is its in-package test file;
// only its EXTERNAL test package (pkg_ext_test.go, package vetxtests_test)
// carries a finding (igloo#90, second half). The flake checks assert the
// external-test run reports it while the package's run and its in-package
// variant stay green.
package vetxtests

// Name is what the tests check.
func Name() string { return "vetxtests" }
