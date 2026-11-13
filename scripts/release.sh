#!/bin/bash
# Signs with Developer ID, notarizes, staples and zips Paella for a GitHub release.
# Needs: SIGN_ID=<Developer ID cert SHA-1 from `security find-identity -v -p codesigning`> (names with accents may not match) and a notarytool profile (default "paella"):
#   xcrun notarytool store-credentials paella --apple-id … --team-id … --password <app-specific>
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGN_ID:?set SIGN_ID to your Developer ID Application identity}"
export VERSION="${VERSION:?set VERSION, e.g. 1.0.0}"
ZIP="dist/Paella-$VERSION.zip"

scripts/bundle.sh
ditto -c -k --keepParent dist/Paella.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE:-paella}" --wait
xcrun stapler staple dist/Paella.app
rm "$ZIP"; ditto -c -k --keepParent dist/Paella.app "$ZIP"  # re-zip with the ticket
spctl -a -vv dist/Paella.app
echo "$ZIP"; shasum -a 256 "$ZIP"
