#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/app/android"

fail=0
note() { printf '\n== %s ==\n' "$*"; }
ok() { printf '  OK   %s\n' "$*"; }
bad() {
  printf '  FAIL %s\n' "$*"
  fail=1
}
warning() { printf '  WARN %s\n' "$*"; }

work_dir="$(mktemp -d)"
fake_keystore="$work_dir/release.jks"
key_properties="key.properties"
cleanup() {
  rm -f "$key_properties"
  rm -rf "$work_dir"
}
trap cleanup EXIT

# Encodes KEY=VALUE pairs the same way the Flutter tool encodes
# `-Pdart-defines=`: comma-separated, each item individually base64'd.
encode_dart_defines() {
  local out="" item
  for item in "$@"; do
    local encoded
    encoded="$(printf '%s' "$item" | base64 | tr -d '\n')"
    out="${out:+$out,}$encoded"
  done
  printf '%s' "$out"
}

gradle_fails_with() {
  # gradle_fails_with <description> <expected-substring> -- <gradle-args...>
  local desc="$1" expected="$2" out
  shift 2
  [ "$1" = "--" ] && shift
  if out="$(gradle "$@" --console=plain 2>&1)"; then
    bad "$desc: expected BUILD FAILED, got BUILD SUCCESSFUL"
    return
  fi
  if printf '%s' "$out" | grep -qF "$expected"; then
    ok "$desc"
  else
    printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
    bad "$desc: build failed, but not with the expected message ($expected)"
  fi
}

gradle_succeeds() {
  # gradle_succeeds <description> -- <gradle-args...>
  local desc="$1" out
  shift
  [ "$1" = "--" ] && shift
  if out="$(gradle "$@" --console=plain 2>&1)"; then
    ok "$desc"
  else
    printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
    bad "$desc: expected BUILD SUCCESSFUL, got BUILD FAILED"
  fi
}

note "F05/P0-09: release signing fails closed without key.properties/env vars"
rm -f "$key_properties"
# Valid dart-defines are supplied so the earlier APP_ENV/Maps-key gates
# pass and the failure isolates to the missing signing config.
signing_probe_defines="$(encode_dart_defines 'APP_ENV=production' 'GOOGLE_MAPS_API_KEY=AIzaFAKEKEYFORVERIFICATIONONLY1234')"
gradle_fails_with \
  "assembleRelease with no signing config configured" \
  "Refusing to fall back to debug signing" \
  -- :app:assembleRelease "-Pdart-defines=$signing_probe_defines"

note "F05/P0-09: signingReport never resolves release to the debug keystore"
out="$(gradle :app:signingReport --console=plain 2>&1)" || {
  printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
  bad "signingReport failed to run"
}
release_signing_block="$(printf '%s\n' "$out" | sed -n '/^Variant: release$/,/^----------$/p')"
if printf '%s' "$release_signing_block" | grep -q "Store: /Users/.*debug.keystore\|Store: .*\.android/debug\.keystore"; then
  bad "release variant is still signed with the debug keystore"
else
  ok "release variant is not signed with the debug keystore (unsigned until key.properties/env vars supply one)"
fi

note "F05/P0-09: release signing succeeds once key.properties supplies real values"
keytool -genkeypair -v \
  -keystore "$fake_keystore" -alias releasekey -keyalg RSA -keysize 2048 -validity 3650 \
  -storepass testpass123 -keypass testpass123 \
  -dname "CN=Test, OU=Test, O=Test, L=Test, ST=Test, C=US" >/dev/null 2>&1
cat >"$key_properties" <<EOF
storeFile=$fake_keystore
storePassword=testpass123
keyAlias=releasekey
keyPassword=testpass123
EOF
out="$(gradle :app:signingReport --console=plain 2>&1)" || {
  printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
  bad "signingReport failed to run with key.properties present"
}
release_signing_block="$(printf '%s\n' "$out" | sed -n '/^Variant: release$/,/^----------$/p')"
if printf '%s' "$release_signing_block" | grep -qF "$fake_keystore"; then
  ok "release variant signs with the configured key.properties keystore"
else
  printf '%s\n' "$release_signing_block" | sed 's/^/       /'
  bad "release variant did not pick up key.properties"
fi

note "F06: release build without any dart-defines fails (no silent test-flavor default)"
# Signing is present here (key.properties written above), so the only gate
# left is the dart-defines one: forgetting --dart-define-from-file must not
# default APP_ENV to 'test' and ship a signed release with the sentinel key.
gradle_fails_with \
  "assembleRelease --dry-run, signing present, no -Pdart-defines" \
  "Release builds require Flutter dart-defines with an explicit APP_ENV" \
  -- :app:assembleRelease --dry-run

note "F06: release build with explicit APP_ENV=test dart-define is still allowed"
test_release_defines="$(encode_dart_defines 'APP_ENV=test')"
gradle_succeeds \
  "assembleRelease --dry-run, explicit APP_ENV=test + real signing" \
  -- :app:assembleRelease --dry-run "-Pdart-defines=$test_release_defines"

note "F06: release build fails closed on a missing Maps key for a non-test flavor"
prod_defines="$(encode_dart_defines 'APP_ENV=production')"
gradle_fails_with \
  "assembleRelease, APP_ENV=production, no Maps key" \
  "GOOGLE_MAPS_API_KEY is missing for a release build" \
  -- :app:assembleRelease "-Pdart-defines=$prod_defines"

note "F06: release build rejects the test-only Maps key placeholder outside the test flavor"
prod_with_placeholder_defines="$(encode_dart_defines 'APP_ENV=production' 'GOOGLE_MAPS_API_KEY=TEST_ONLY_MAPS_KEY_NOT_FOR_PRODUCTION')"
gradle_fails_with \
  "assembleRelease, APP_ENV=production, test-only placeholder key" \
  "test-only Maps key placeholder cannot be used" \
  -- :app:assembleRelease "-Pdart-defines=$prod_with_placeholder_defines"

note "F06: release build with a real Maps key + real signing clears the fail-closed gate"
prod_ok_defines="$(encode_dart_defines 'APP_ENV=production' 'GOOGLE_MAPS_API_KEY=AIzaFAKEKEYFORVERIFICATIONONLY1234')"
gradle_succeeds \
  "assembleRelease --dry-run, APP_ENV=production, real key + real signing" \
  -- :app:assembleRelease --dry-run "-Pdart-defines=$prod_ok_defines"

note "F06: test flavor with no Maps key resolves to the explicit sentinel, never a blank string"
test_defines="$(encode_dart_defines 'APP_ENV=test')"
gradle :app:generateDebugResValues --console=plain "-Pdart-defines=$test_defines" >/dev/null 2>&1
resvalues_file="$(find ../build -path '*resValues/debug/values/gradleResValues.xml' 2>/dev/null | head -1)"
if [ -z "$resvalues_file" ]; then
  bad "could not locate generated resValues XML after generateDebugResValues"
elif grep -q '<string name="google_maps_api_key" translatable="false">TEST_ONLY_MAPS_KEY_NOT_FOR_PRODUCTION</string>' "$resvalues_file"; then
  ok "test flavor Maps key resolves to the explicit sentinel"
elif grep -q '<string name="google_maps_api_key" translatable="false"></string>' "$resvalues_file"; then
  bad "test flavor Maps key resolved to an empty string, not the explicit sentinel"
else
  bad "unexpected google_maps_api_key resValue: $(grep google_maps_api_key "$resvalues_file")"
fi

note "F49: product identity — app_name resource and manifest label"
strings_xml="app/src/main/res/values/strings.xml"
manifest="app/src/main/AndroidManifest.xml"
if grep -q '<string name="app_name">我公車呢</string>' "$strings_xml"; then
  ok "strings.xml app_name == 我公車呢"
else
  bad "strings.xml app_name is missing or not 我公車呢"
fi
if grep -q 'android:label="@string/app_name"' "$manifest"; then
  ok "AndroidManifest.xml android:label references @string/app_name"
else
  bad "AndroidManifest.xml android:label does not reference @string/app_name"
fi

note "Kotlin unit tests still pass (debug build, unaffected by release fail-closed gate)"
rm -f "$key_properties"
if gradle :app:testDebugUnitTest --console=plain >/tmp/check-android-release-testDebugUnitTest.log 2>&1; then
  ok ":app:testDebugUnitTest"
elif grep -q "google-services.json is missing" /tmp/check-android-release-testDebugUnitTest.log; then
  warning ":app:testDebugUnitTest could not run — app/android/app/google-services.json is absent in this environment (pre-existing, gitignored, unrelated to this change); run this check on a machine/CI with Firebase credentials configured"
else
  tail -30 /tmp/check-android-release-testDebugUnitTest.log | sed 's/^/       /'
  bad ":app:testDebugUnitTest failed"
fi
rm -f /tmp/check-android-release-testDebugUnitTest.log

printf '\n'
if [ "$fail" -eq 0 ]; then
  echo "RESULT: GREEN — Android release fail-closed checks and product identity all pass."
else
  echo "RESULT: RED — see FAIL lines above."
fi
exit "$fail"
