#!/bin/bash
# Sign the unconfined DEVELOPMENT-ONLY launcher in a declared temporary output
# directory, not inside the app. Xcode user-script sandbox otherwise denies
# codesign's adjacent .cstemp file. Copy the already signed bytes into the
# declared app output; Xcode then seals the app in its normal CodeSign phase.
# Release builds get a contained-only variant instead: it starts nothing but
# /usr/bin/sandbox-exec -f <profile> (contained downloads, StudyContainment).
set -euo pipefail
launcher="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/StudyToolLauncher"
case "$CONFIGURATION" in
  Debug) variant=(); identifier=com.kairos.ShieldDevelopment.ToolFixtureLauncher; runtime=() ;;
  Release) variant=(-DSHIELD_CONTAINED_ONLY); identifier=com.kairos.Shield.StudyToolLauncher; runtime=(--options runtime) ;;
  *) test ! -e "$launcher" || { echo 'Unexpected tool launcher in this configuration.' >&2; exit 1; }
     exit 0 ;;
esac
test -n "${TARGET_TEMP_DIR:-}" || { echo 'Missing isolated build temporary directory.' >&2; exit 1; }
signed_dir="$TARGET_TEMP_DIR/ShieldSignedLauncher"
signed="$signed_dir/StudyToolLauncher"
mkdir -p "$signed_dir" "$(dirname "$launcher")"
/usr/bin/xcrun clang -O2 -Wall -Werror -arch arm64 -arch x86_64 ${variant[@]+"${variant[@]}"} \
  "$SRCROOT/scripts/study_tool_launcher.c" -o "$signed"
identity=-
if [ "${CODE_SIGNING_ALLOWED:-YES}" = YES ]; then
  identity=${EXPANDED_CODE_SIGN_IDENTITY:-}
  test -n "$identity" || { echo 'Xcode did not resolve launcher signing identity.' >&2; exit 1; }
fi
# Neither variant has entitlement exceptions. The unconfined Debug fixture is
# NEVER included in distributable packages (package_release_candidate.sh checks).
/usr/bin/codesign --force --sign "$identity" --timestamp=none ${runtime[@]+"${runtime[@]}"} \
  --identifier "$identifier" "$signed"
/usr/bin/codesign --verify --strict "$signed"
/bin/cp -p "$signed" "$launcher"
/usr/bin/codesign --verify --strict "$launcher"
