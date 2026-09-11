// Package user depends on lib; its tests need lib compiled under the tag.
package user

import "example.com/tags/lib"

func Use() string { return "uses " + lib.Name() }
