#!/bin/bash
# Pick an SDK the Command Line Tools can actually compile SwiftUI against.
#
# Command Line Tools for Xcode 27.0 ships the macOS 27 SDK, in which SwiftUI's
# property wrappers (`@State` and friends) are macros implemented by a
# `SwiftUIMacros` plugin — and ships no libSwiftUIMacros.dylib to implement
# them. Every SwiftUI file then fails with "plugin for module 'SwiftUIMacros'
# not found". A full Xcode install carries the plugin; the CLT does not, so
# build against the newest 26.x SDK still on disk instead. That SDK declares
# `@State` as a plain property wrapper and needs no plugin.
#
# Source this file. It exports SDKROOT only when all of the following hold:
# the developer directory is the Command Line Tools, its default SDK is 27 or
# newer, the plugin is absent, and a 26.x SDK exists. Anything else — a full
# Xcode, a future CLT that ships the plugin, an SDKROOT set by the caller — is
# left alone.

if [[ -z "${SDKROOT:-}" ]]; then
    _clt="$(xcode-select -p 2>/dev/null || true)"
    if [[ "${_clt}" == *CommandLineTools* \
          && ! -e "${_clt}/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
        _default="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 0)"
        _major="${_default%%.*}"
        if [[ "${_major}" =~ ^[0-9]+$ ]] && (( _major >= 27 )); then
            # Apple's unversioned MacOSX26.sdk link points at the newest 26.x.
            # Without it, pick the highest minor version numerically — a glob
            # is lexical and would rank 26.10 before 26.5.
            _sdk="${_clt}/SDKs/MacOSX26.sdk"
            if [[ ! -d "${_sdk}" ]]; then
                _sdk="$(ls -d "${_clt}"/SDKs/MacOSX26.*.sdk 2>/dev/null \
                        | sort -t. -k2,2n | tail -n 1)"
            fi
            if [[ -n "${_sdk}" && -d "${_sdk}" ]]; then
                SDKROOT="$(cd "${_sdk}" && pwd -P)"
                export SDKROOT
                echo "[sdk] Command Line Tools ${_default} lack the SwiftUI macro plugin;" \
                     "building against $(basename "${SDKROOT}")" >&2
            fi
        fi
    fi
    unset _clt _default _major _sdk
fi
