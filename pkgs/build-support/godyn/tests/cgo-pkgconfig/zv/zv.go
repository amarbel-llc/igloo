// Package zv exercises the cgo flags cmd/go resolves before invoking cgo: the
// headers and library come from `#cgo pkg-config: zlib`, and GODYN_MARK must be
// defined through the builder's CGO_CFLAGS.
package zv

/*
#cgo pkg-config: zlib
#include <zlib.h>

static const char *mark(void) { return GODYN_MARK; }
static const char *mark2(void) { return GODYN_MARK2; }
*/
import "C"

// Version is zlib's runtime version string.
func Version() string { return C.GoString(C.zlibVersion()) }

// Mark is the GODYN_MARK value CGO_CFLAGS defined.
func Mark() string { return C.GoString(C.mark()) }

// Mark2 is GODYN_MARK2, defined by a quoted CGO_CFLAGS field containing a space.
func Mark2() string { return C.GoString(C.mark2()) }
