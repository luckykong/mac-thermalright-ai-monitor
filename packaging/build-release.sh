#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.4.0"
BUILD_NUMBER="140"
MIN_MACOS="15.0"
ARCH="arm64"
LIBUSB_VERSION="1.0.30"
LIBUSB_SHA256="fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf"
LIBUSB_URL="https://github.com/libusb/libusb/releases/download/v${LIBUSB_VERSION}/libusb-${LIBUSB_VERSION}.tar.bz2"

WORK_DIR="${ROOT_DIR}/.build/release-package"
DOWNLOAD_DIR="${WORK_DIR}/downloads"
SOURCE_DIR="${WORK_DIR}/sources"
DEPS_PREFIX="${WORK_DIR}/deps"
SWIFT_BUILD_DIR="${WORK_DIR}/swift-build"
APP_DIR="${WORK_DIR}/MacTR.app"
DIST_DIR="${ROOT_DIR}/dist/v${VERSION}"
ICONSET_DIR="${WORK_DIR}/AppIcon.iconset"
ICON_PREVIEW="${WORK_DIR}/app-icon.png"
ARCHIVE="${DOWNLOAD_DIR}/libusb-${LIBUSB_VERSION}.tar.bz2"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "${DOWNLOAD_DIR}" "${SOURCE_DIR}" "${DIST_DIR}"

if [[ ! -f "${ARCHIVE}" ]]; then
    curl --fail --location --retry 3 "${LIBUSB_URL}" --output "${ARCHIVE}"
fi

printf "%s  %s\n" "${LIBUSB_SHA256}" "${ARCHIVE}" | shasum -a 256 --check

rm -rf "${SOURCE_DIR}/libusb-${LIBUSB_VERSION}" "${DEPS_PREFIX}"
tar -xjf "${ARCHIVE}" -C "${SOURCE_DIR}"

pushd "${SOURCE_DIR}/libusb-${LIBUSB_VERSION}" >/dev/null
env \
    MACOSX_DEPLOYMENT_TARGET="${MIN_MACOS}" \
    SDKROOT="${SDK_PATH}" \
    CC="$(xcrun --find clang)" \
    CFLAGS="-arch ${ARCH} -O2 -isysroot ${SDK_PATH} -mmacosx-version-min=${MIN_MACOS}" \
    LDFLAGS="-arch ${ARCH} -isysroot ${SDK_PATH} -mmacosx-version-min=${MIN_MACOS}" \
    ./configure \
        --disable-dependency-tracking \
        --disable-static \
        --enable-shared \
        --prefix="${DEPS_PREFIX}"
make -j"$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
make install
popd >/dev/null

LIBUSB_DYLIB="${DEPS_PREFIX}/lib/libusb-1.0.0.dylib"
install_name_tool -id "@rpath/libusb-1.0.0.dylib" "${LIBUSB_DYLIB}"

rm -rf "${SWIFT_BUILD_DIR}"
env \
    MACOSX_DEPLOYMENT_TARGET="${MIN_MACOS}" \
    SDKROOT="${SDK_PATH}" \
    PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig" \
    PKG_CONFIG_LIBDIR="${DEPS_PREFIX}/lib/pkgconfig" \
    swift build \
        --configuration release \
        --arch "${ARCH}" \
        --scratch-path "${SWIFT_BUILD_DIR}"

EXECUTABLE="${SWIFT_BUILD_DIR}/${ARCH}-apple-macosx/release/MacTR"
if [[ ! -x "${EXECUTABLE}" ]]; then
    printf "Release executable not found: %s\n" "${EXECUTABLE}" >&2
    exit 1
fi

rm -rf "${APP_DIR}" "${ICONSET_DIR}"
mkdir -p \
    "${APP_DIR}/Contents/MacOS" \
    "${APP_DIR}/Contents/Frameworks" \
    "${APP_DIR}/Contents/Resources/Licenses"

cp "${EXECUTABLE}" "${APP_DIR}/Contents/MacOS/MacTR"
cp "${LIBUSB_DYLIB}" "${APP_DIR}/Contents/Frameworks/libusb-1.0.0.dylib"
cp "${ROOT_DIR}/Sources/MacTR/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "${ROOT_DIR}/LICENSE" "${APP_DIR}/Contents/Resources/LICENSE.txt"
cp "${ROOT_DIR}/packaging/THIRD_PARTY_NOTICES.md" \
    "${APP_DIR}/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "${SOURCE_DIR}/libusb-${LIBUSB_VERSION}/COPYING" \
    "${APP_DIR}/Contents/Resources/Licenses/libusb-COPYING"

plutil -replace CFBundleShortVersionString -string "${VERSION}" \
    "${APP_DIR}/Contents/Info.plist"
plutil -replace CFBundleVersion -string "${BUILD_NUMBER}" \
    "${APP_DIR}/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "${MIN_MACOS}" \
    "${APP_DIR}/Contents/Info.plist"

xcrun swift "${ROOT_DIR}/packaging/generate-app-icon.swift" \
    "${ICONSET_DIR}" "${ICON_PREVIEW}"
iconutil --convert icns "${ICONSET_DIR}" \
    --output "${APP_DIR}/Contents/Resources/AppIcon.icns"

if ! otool -l "${APP_DIR}/Contents/MacOS/MacTR" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "${APP_DIR}/Contents/MacOS/MacTR"
fi

# SwiftPM may add an Xcode-toolchain fallback rpath. It is unnecessary on
# macOS 15+ and must not leak a developer-machine path into the release.
while IFS= read -r rpath; do
    case "${rpath}" in
        /Applications/Xcode.app/*|/Library/Developer/*|"${WORK_DIR}"*)
            install_name_tool -delete_rpath "${rpath}" \
                "${APP_DIR}/Contents/MacOS/MacTR"
            ;;
    esac
done < <(
    otool -l "${APP_DIR}/Contents/MacOS/MacTR" \
        | awk '/cmd LC_RPATH/ { getline; getline; print $2 }'
)

strip -x "${APP_DIR}/Contents/MacOS/MacTR"

if otool -L "${APP_DIR}/Contents/MacOS/MacTR" | tail -n +2 \
    | grep -E "/opt/homebrew|${WORK_DIR}|\\.build/" >/dev/null
then
    printf "Error: release executable contains a developer-machine dependency.\n" >&2
    otool -L "${APP_DIR}/Contents/MacOS/MacTR" >&2
    exit 1
fi
if otool -l "${APP_DIR}/Contents/MacOS/MacTR" | tail -n +2 \
    | grep -E "/opt/homebrew|${WORK_DIR}|\\.build/|/Applications/Xcode|/Library/Developer" >/dev/null
then
    printf "Error: release executable contains a developer-machine rpath.\n" >&2
    exit 1
fi

codesign --force --sign - --timestamp=none \
    "${APP_DIR}/Contents/Frameworks/libusb-1.0.0.dylib"
codesign --force --deep --sign - --timestamp=none \
    "${APP_DIR}"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

ZIP_PATH="${DIST_DIR}/MacTR-v${VERSION}-macos-${ARCH}.zip"
DMG_PATH="${DIST_DIR}/MacTR-v${VERSION}-macos-${ARCH}.dmg"
ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${ZIP_PATH}"

DMG_SOURCE="${WORK_DIR}/dmg"
rm -rf "${DMG_SOURCE}"
mkdir -p "${DMG_SOURCE}"
cp -R "${APP_DIR}" "${DMG_SOURCE}/MacTR.app"
ln -s /Applications "${DMG_SOURCE}/Applications"
cp "${ROOT_DIR}/packaging/FIRST_RUN.txt" "${DMG_SOURCE}/FIRST_RUN.txt"
hdiutil create \
    -volname "MacTR ${VERSION}" \
    -srcfolder "${DMG_SOURCE}" \
    -format UDZO \
    -ov \
    "${DMG_PATH}"

cp "${APP_DIR}/Contents/Resources/AppIcon.icns" "${DIST_DIR}/AppIcon.icns"
cp "${ICON_PREVIEW}" "${DIST_DIR}/app-icon.png"

pushd "${DIST_DIR}" >/dev/null
shasum -a 256 \
    "$(basename "${DMG_PATH}")" \
    "$(basename "${ZIP_PATH}")" \
    > SHA256SUMS.txt
popd >/dev/null

printf "\nRelease artifacts:\n"
find "${DIST_DIR}" -maxdepth 1 -type f -print | sort
