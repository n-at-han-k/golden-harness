// Stand-in for the header CMake generates at build time.
//
// `src/libsync/*.h` includes "libsync/opencloudsynclib.h" for its export
// macro, which only exists in a configured build tree. Without it libclang
// stops at the include and the oracle gets no AST for the translation unit.
// The macro is empty here for the same reason 02_prepare.py strips it: an
// export annotation carries nothing into Ruby.
#pragma once

#define OPENCLOUD_SYNC_EXPORT
