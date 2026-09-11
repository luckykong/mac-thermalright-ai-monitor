#!/bin/bash
# Run the MacTR test suite.
#
# swift-testing ships inside the Command Line Tools under
# Library/Developer/Frameworks. SwiftPM before Swift 6.4 did not put that
# directory on the search paths: a bare `swift test` failed with "no such
# module 'Testing'", and once that was fixed it failed again at run time with a
# dlopen error for lib_TestingInterop.dylib, which lives in a different
# directory from the framework itself. Both are supplied for those toolchains.
#
# SwiftPM 6.4 (Command Line Tools 27) finds the framework itself, but its
# macro plugin is another matter: resolving `TestingMacros` through the
# `-plugin-path` search list fails intermittently there — measured on one
# machine, forced recompiles of the test target failed 5 times out of 8 with
# "plugin for module 'TestingMacros' not found", with SDKROOT set or not,
# serial or parallel — while loading the dylib explicitly with
# -load-plugin-library never failed in the same trials. So under the Command
# Line Tools the plugin is loaded explicitly whenever it is present.
#
# A full Xcode install needs none of this.
#
set -euo pipefail

cd "$(dirname "$0")/.."

# Command Line Tools 27 need an older SDK for SwiftUI; see the helper.
source scripts/sdk-env.sh

CLT_DEVELOPER="/Library/Developer/CommandLineTools/Library/Developer"

CLT_ROOT="/Library/Developer/CommandLineTools"
TESTING_MACROS="${CLT_ROOT}/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

# "6.4" from "Apple Swift version 6.4 (...)"; empty if the pattern changes.
SWIFT_VERSION="$(swift --version 2>/dev/null \
    | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -n 1)"

using_clt() { [[ "$(xcode-select -p)" == *CommandLineTools* ]]; }
swift_before_6_4() {
    [[ -n "${SWIFT_VERSION}" ]] || return 1
    [[ "$(printf '%s\n' "${SWIFT_VERSION}" 6.4 | sort -V | head -n 1)" != 6.4 ]]
}

FLAGS=()
if using_clt; then
    if [[ -f "${TESTING_MACROS}" ]]; then
        FLAGS+=(-Xswiftc -load-plugin-library -Xswiftc "${TESTING_MACROS}")
    fi
    if swift_before_6_4 && [[ -d "${CLT_DEVELOPER}/Frameworks/Testing.framework" ]]; then
        FLAGS+=(
            -Xswiftc -F"${CLT_DEVELOPER}/Frameworks"
            -Xlinker -F"${CLT_DEVELOPER}/Frameworks"
            -Xlinker -rpath -Xlinker "${CLT_DEVELOPER}/Frameworks"
            -Xlinker -rpath -Xlinker "${CLT_DEVELOPER}/usr/lib"
        )
    fi
fi

exec swift test "${FLAGS[@]}" "$@"
