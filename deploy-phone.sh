#!/bin/bash
#
# Build the iOS app and deploy it to a physical iPhone — no Xcode UI needed.
#
#   ./deploy-phone.sh                      # debug build → first paired iPhone → launch
#   ./deploy-phone.sh --release            # release build
#   ./deploy-phone.sh --device "dna iPhone17"  # pick a device by name or UDID
#   ./deploy-phone.sh --demo               # launch straight into the sample-data charts
#   ./deploy-phone.sh --console            # stream the app's stdout/stderr after launch
#   ./deploy-phone.sh --team ABCDE12345    # override the signing team
#   ./deploy-phone.sh --no-launch          # install only
#   ./deploy-phone.sh --build-only         # compile, don't touch the device
#
# USB or the same Wi-Fi as this Mac both work. The phone must already be
# paired (plug it in once and tap Trust) with Developer Mode on
# (Settings ▸ Privacy & Security ▸ Developer Mode). To pair over the network:
#   xcrun devicectl manage pair --device <ip-address>
#
# The widget extension ships inside the app, so both bundle ids and the
# group.hu.randart.EonUsage App Group have to exist on the signing team —
# -allowProvisioningUpdates registers them the first time.

set -euo pipefail

PROJECT="EonUsage.xcodeproj"
SCHEME="EonUsage"
BUNDLE_ID="hu.randart.EonUsage"
DERIVED_DATA="build/phone"

CONFIGURATION="Debug"
DEVICE_QUERY=""
TEAM=""
LAUNCH=1
INSTALL=1
CONSOLE=0
DEMO=0

while [ $# -gt 0 ]; do
	case "$1" in
		--release)    CONFIGURATION="Release" ;;
		--debug)      CONFIGURATION="Debug" ;;
		--device)     DEVICE_QUERY="${2:-}"; shift ;;
		--team)       TEAM="${2:-}"; shift ;;
		--demo)       DEMO=1 ;;
		--console)    CONSOLE=1 ;;
		--no-launch)  LAUNCH=0 ;;
		--build-only) LAUNCH=0; INSTALL=0 ;;
		-h|--help)    sed -n '2,/^[^#]/p' "$0" | sed -e '$d' -e 's/^#//' -e 's/^ //'; exit 0 ;;
		*)            echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
	esac
	shift
done

cd "$(dirname "$0")"

command -v xcodebuild >/dev/null || { echo "xcodebuild not found — install Xcode." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found (expected at /usr/bin/jq on macOS 15+)." >&2; exit 1; }

# ---- Pick the iPhone ---------------------------------------------------------

DEVICES_JSON="$(mktemp -t eon-devices)"
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null

# name<TAB>udid for every paired iPhone, optionally narrowed by --device.
MATCHES="$(jq -r --arg q "$DEVICE_QUERY" '
	.result.devices[]
	| select(.hardwareProperties.platform == "iOS")
	| select(.hardwareProperties.deviceType == "iPhone")
	| select(.connectionProperties.pairingState == "paired")
	| select($q == "" or .deviceProperties.name == $q or .identifier == $q)
	| "\(.deviceProperties.name)\t\(.identifier)"
' "$DEVICES_JSON")"

if [ -z "$MATCHES" ]; then
	if [ -n "$DEVICE_QUERY" ]; then
		echo "No paired iPhone matching '$DEVICE_QUERY'. Known devices:" >&2
	else
		echo "No paired iPhone found. Known devices:" >&2
	fi
	xcrun devicectl list devices >&2
	exit 1
fi

if [ "$(echo "$MATCHES" | wc -l)" -gt 1 ]; then
	echo "Multiple iPhones paired — pass --device <name>:" >&2
	echo "$MATCHES" | cut -f 1 | sed 's/^/  /' >&2
	exit 1
fi

DEVICE_NAME="$(echo "$MATCHES" | cut -f 1)"
DEVICE_ID="$(echo "$MATCHES" | cut -f 2)"

# ---- Build -------------------------------------------------------------------

echo "==> Building $SCHEME ($CONFIGURATION) for $DEVICE_NAME"

BUILD_ARGS=(
	-project "$PROJECT"
	-scheme "$SCHEME"
	-configuration "$CONFIGURATION"
	-destination "id=$DEVICE_ID"
	-derivedDataPath "$DERIVED_DATA"
	-allowProvisioningUpdates
)
[ -n "$TEAM" ] && BUILD_ARGS+=("DEVELOPMENT_TEAM=$TEAM")

xcodebuild "${BUILD_ARGS[@]}" build

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/$SCHEME.app"
[ -d "$APP" ] || { echo "Build succeeded but $APP is missing." >&2; exit 1; }

if [ "$INSTALL" -eq 0 ]; then
	echo "==> Built $APP"
	exit 0
fi

# ---- Install & launch --------------------------------------------------------

echo "==> Installing on $DEVICE_NAME"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

if [ "$LAUNCH" -eq 1 ]; then
	echo "==> Launching $BUNDLE_ID"

	LAUNCH_ARGS=(device process launch --device "$DEVICE_ID" --terminate-existing)
	[ "$CONSOLE" -eq 1 ] && LAUNCH_ARGS+=(--console)
	LAUNCH_ARGS+=("$BUNDLE_ID")
	# Trailing arguments reach the app; --demo skips sign-in and loads sample data.
	[ "$DEMO" -eq 1 ] && LAUNCH_ARGS+=(--demo)

	xcrun devicectl "${LAUNCH_ARGS[@]}"
fi
