#!/bin/bash
# Run the MacTR test suite.
#
# swift-testing ships inside the Command Line Tools, but SwiftPM does not put
# its framework or library directories on the search paths. A bare `swift test`
# therefore fails with "no such module 'Testing'", and once that is fixed it
# fails again at run time with a dlopen error for lib_TestingInterop.dylib,
# which lives in a different directory from the framework itself. Supply both.
#
# A full Xcode install needs none of this, so the flags are added only when the
# selected developer directory is the Command Line Tools.

set -euo pipefail

cd "$(dirname "$0")/.."

CLT_DEVELOPER="/Library/Developer/CommandLineTools/Library/Developer"

if [[ "$(xcode-select -p)" == *CommandLineTools* \
      && -d "${CLT_DEVELOPER}/Frameworks/Testing.framework" ]]; then
    exec swift test \
        -Xswiftc -F"${CLT_DEVELOPER}/Frameworks" \
        -Xlinker -F"${CLT_DEVELOPER}/Frameworks" \
        -Xlinker -rpath -Xlinker "${CLT_DEVELOPER}/Frameworks" \
        -Xlinker -rpath -Xlinker "${CLT_DEVELOPER}/usr/lib" \
        "$@"
fi

exec swift test "$@"
