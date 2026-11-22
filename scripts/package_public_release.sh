#!/bin/bash
# Shield public release: builds the installer people download. Never installs.
#   bash scripts/package_public_release.sh <output-dir> [signing identity]
# The identity defaults to the self-signed "Shield Release Signing" certificate.
# Builds from a copy in /private/tmp/shield-build, so no home-folder path ends
# up inside the app. Updates: the app checks github.com/useshield/shield
# releases with the public key below (override with SHIELD_UPDATE_FEED and
# SHIELD_UPDATE_PUBLIC_KEY); set SHIELD_UPDATE_KEY_FILE to also sign the
# package for the updater. Release sequence = 1000 + commit count (always above
# earlier development builds' numbers, and rising with every public commit).
set -euo pipefail
umask 022
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo 'Usage: package_public_release.sh <output-dir> [identity]' >&2; exit 64; }
output=$(cd "$1" && pwd -P)
identity=${2:-Shield Release Signing}
repo=$(cd "$(dirname "$0")/.." && pwd -P)
case "$output" in "$repo"|"$repo"/*) echo 'Output must be outside the source folder.' >&2; exit 64;; esac
[ "$(uname -m)" = arm64 ] || { echo 'Requires Apple Silicon' >&2; exit 64; }
[ -z "$(git -C "$repo" status --porcelain)" ] || { echo 'Commit your changes first.' >&2; exit 64; }
# Self-signed, so macOS lists it as "not trusted": look it up without -v and
# sign by its exact fingerprint (never a similarly named certificate).
matches=$(security find-identity -p codesigning | sed -n "s/^ *[0-9]*) \([0-9A-F]\{40\}\) \"$identity\".*/\1/p" | sort -u)
[ "$(printf '%s\n' "$matches" | awk 'NF' | wc -l | tr -d ' ')" = 1 ] || { echo "Need exactly one code-signing identity named \"$identity\"." >&2; exit 64; }
fingerprint=$matches
# Public update settings (the public key is safe to publish; the private key
# stays offline and is used only when SHIELD_UPDATE_KEY_FILE is set).
SHIELD_UPDATE_FEED=${SHIELD_UPDATE_FEED:-https://api.github.com/repos/useshield/shield/releases/latest}
SHIELD_UPDATE_PUBLIC_KEY=${SHIELD_UPDATE_PUBLIC_KEY:-dnJa4RkpkwhwIoORz63mE7eSfcYl2XBMbUsxMo4C3QM=}
commit=$(git -C "$repo" rev-parse HEAD)
sequence=$((1000 + $(git -C "$repo" rev-list --count HEAD)))
# The version people see and the updater compares (SHIELD_VERSION=1.2 for the next one).
version=${SHIELD_VERSION:-1.1}
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "Bad version: $version" >&2; exit 64; }
work=/private/tmp/shield-build
rm -rf "$work"; mkdir -p "$work/src"
git -C "$repo" archive "$commit" | tar -x -C "$work/src"
cd "$work/src"
build="$work/out"; payload="$build/payload"; scripts="$build/install-scripts"
authority="$payload/Library/Application Support/ShieldAuthority"
mkdir -p "$payload/Library/PrivilegedHelperTools" "$payload/Library/LaunchDaemons" "$payload/Applications" "$scripts"
mkdir -m 700 -p "$authority/state"
common=(Kairos/PolicyModels.swift Kairos/PolicyServices.swift Kairos/ReconciliationCore.swift
  Kairos/KairosConfig.swift Kairos/ShieldRuntime.swift Kairos/FixtureBackend.swift Kairos/FixtureBackendXPC.swift
  Kairos/ServiceGapEvidence.swift Kairos/AppBlocking.swift Kairos/AppEnforcement.swift Kairos/ConditionalRules.swift)
service="$payload/Library/PrivilegedHelperTools/com.kairos.ShieldAuthority"
xcrun swiftc -O -D SHIELD_AUTHORITY_SERVICE -framework Security -o "$service" "${common[@]}" AuthorityService/*.swift
sign=(--force --sign "$fingerprint" --options runtime)
codesign "${sign[@]}" --identifier com.kairos.ShieldAuthority "$service"
service_requirement=$(bash scripts/signing_requirement.sh "$service" com.kairos.ShieldAuthority)
# The main build has no downloads; the Video Library is an add-on.
xcodebuild build -project Kairos.xcodeproj -scheme Kairos -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$build/Derived" SWIFT_ACTIVE_COMPILATION_CONDITIONS=SHIELD_RC PRODUCT_NAME=Shield \
  PRODUCT_BUNDLE_IDENTIFIER=com.kairos.ShieldRC CURRENT_PROJECT_VERSION="$sequence" MARKETING_VERSION="$version" \
  CODE_SIGNING_ALLOWED=NO
app="$payload/Applications/Shield.app"
ditto "$build/Derived/Build/Products/Release/Shield.app" "$app"
for helper in StudyToolLauncher:com.kairos.Shield.StudyToolLauncher ShieldEgressBroker:com.kairos.Shield.EgressBroker; do
  file="$app/Contents/Helpers/${helper%%:*}"
  if [ -e "$file" ]; then codesign "${sign[@]}" --identifier "${helper#*:}" "$file"; fi
done
python3 scripts/embed_xpc_signing_requirement.py "$app/Contents/Info.plist" "$service_requirement"
if [ -n "${SHIELD_UPDATE_FEED:-}" ] && [ -n "${SHIELD_UPDATE_PUBLIC_KEY:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :ShieldUpdateFeed string $SHIELD_UPDATE_FEED" \
    -c "Add :ShieldUpdatePublicKey string $SHIELD_UPDATE_PUBLIC_KEY" "$app/Contents/Info.plist"
fi
codesign "${sign[@]}" --entitlements Configuration/ShieldLocation.entitlements "$app"
codesign --verify --deep --strict "$app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version" ] || {
  echo 'The app does not carry the release version.' >&2; exit 1; }
client_requirement=$(bash scripts/signing_requirement.sh "$app" com.kairos.ShieldRC)
# The user and time zone are filled in on the Mac it's installed on.
python3 - "$scripts/service-template.plist" "$sequence" "$client_requirement" "$commit" <<'PY'
import plistlib, sys
path, sequence, requirement, commit = sys.argv[1:]
with open(path, 'wb') as stream:
    plistlib.dump(dict(version=1, releaseSequence=int(sequence), allowedUID=0, clientRequirement=requirement,
                       sourceCommit=commit, timeZoneIdentifier='UTC'), stream)
PY
cp Configuration/AuthorityLaunchDaemon.plist "$payload/Library/LaunchDaemons/com.kairos.ShieldAuthority.plist"
cp scripts/public_install/preinstall scripts/public_install/postinstall scripts/public_install/make_service_plist.sh "$scripts/"
cp "$service" "$scripts/ShieldAuthorityPreflight"
chmod 755 "$scripts/preinstall" "$scripts/postinstall"
pkgbuild --analyze --root "$payload" "$build/components.plist"
python3 - "$build/components.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as stream: components = plistlib.load(stream)
for component in components:
    component.update(BundleIsRelocatable=False, BundleHasStrictIdentifier=True,
                     BundleIsVersionChecked=True, BundleOverwriteAction='upgrade')
with open(path, 'wb') as stream: plistlib.dump(components, stream)
PY
package="$output/Shield-$version.pkg"
pkgbuild --root "$payload" --scripts "$scripts" --component-plist "$build/components.plist" --ownership recommended \
  --identifier com.kairos.Shield --version "$version.$sequence" --install-location / "$package"
(cd "$output" && shasum -a 256 "$(basename "$package")" > SHA256SUMS)
if [ -n "${SHIELD_UPDATE_KEY_FILE:-}" ]; then
  xcrun swift "$repo/scripts/sign_update.swift" "$SHIELD_UPDATE_KEY_FILE" "$package"
fi
# Privacy check: nothing from this Mac's home folder or user name in what ships.
leaks=$(pkgutil --expand-full "$package" "$build/check" >/dev/null && \
  grep -rl -a -e "$HOME" -e "$(id -un)" "$build/check" 2>/dev/null || true)
[ -z "$leaks" ] || { echo "Personal path or name found in the package:" >&2; echo "$leaks" >&2; exit 1; }
rm -rf "$work"
echo "Package: $package"
echo "Not installed. Users open it with System Settings → Privacy & Security → Open Anyway."
