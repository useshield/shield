#!/bin/bash
# Build the download egress broker into Contents/Helpers (every configuration
# except UIReview, which has no downloads). Signed in a temporary directory for
# the same reason as the launcher (codesign's .cstemp under the script sandbox).
set -euo pipefail
broker="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/ShieldEgressBroker"
if [ "$CONFIGURATION" = UIReview ]; then
  test ! -e "$broker" || { echo 'Unexpected egress broker in UI Review.' >&2; exit 1; }
  exit 0
fi
test -n "${TARGET_TEMP_DIR:-}" || { echo 'Missing isolated build temporary directory.' >&2; exit 1; }
signed_dir="$TARGET_TEMP_DIR/ShieldSignedBroker"
signed="$signed_dir/ShieldEgressBroker"
mkdir -p "$signed_dir" "$(dirname "$broker")"
/usr/bin/xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 -module-cache-path "$signed_dir/ModuleCache" \
  -o "$signed" "$SRCROOT/EgressBroker/main.swift" "$SRCROOT/Kairos/EgressPolicy.swift" "$SRCROOT/Kairos/PolicyModels.swift" "$SRCROOT/Kairos/AppBlocking.swift" "$SRCROOT/Kairos/ConditionalRules.swift"
identity=-
if [ "${CODE_SIGNING_ALLOWED:-YES}" = YES ]; then
  identity=${EXPANDED_CODE_SIGN_IDENTITY:--}
fi
/usr/bin/codesign --force --sign "$identity" --timestamp=none --options runtime \
  --identifier com.kairos.Shield.EgressBroker "$signed"
/usr/bin/codesign --verify --strict "$signed"
/bin/cp -p "$signed" "$broker"
