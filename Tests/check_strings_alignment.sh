#!/bin/bash
# Verifies the three Localizable.strings files define the same key sets.
# A key present in one language but missing in another renders the source
# key string (e.g. "cleaner.history_total") in the UI, so alignment is a
# release gate, not a nicety.
# Written for macOS's stock bash 3.2: no associative arrays, no mkshisms.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0

extract_keys() {
  # Strip comments and pull the leading quoted key from each definition.
  grep -oE '^"[^"]+"' "$1" | tr -d '"' | sort -u
}

KEYS_ZH="$(extract_keys "$ROOT/ThreeOneOSSix/zh-Hans.lproj/Localizable.strings")"
KEYS_EN="$(extract_keys "$ROOT/ThreeOneOSSix/en.lproj/Localizable.strings")"
KEYS_VI="$(extract_keys "$ROOT/ThreeOneOSSix/vi.lproj/Localizable.strings")"

echo "zh-Hans: $(echo "$KEYS_ZH" | grep -c . || true) keys"
echo "en: $(echo "$KEYS_EN" | grep -c . || true) keys"
echo "vi: $(echo "$KEYS_VI" | grep -c . || true) keys"

# Pairwise comparison against zh-Hans (the authoring language).
for PAIR in "en:$KEYS_EN" "vi:$KEYS_VI"; do
  LANG_NAME="${PAIR%%:*}"
  OTHER="${PAIR#*:}"
  MISSING=$(comm -23 <(echo "$KEYS_ZH") <(echo "$OTHER") || true)
  EXTRA=$(comm -13 <(echo "$KEYS_ZH") <(echo "$OTHER") || true)
  if [[ -n "$MISSING" ]]; then
    echo "FAIL: $LANG_NAME missing keys:" >&2
    echo "$MISSING" | sed 's/^/  /' >&2
    FAILED=1
  fi
  if [[ -n "$EXTRA" ]]; then
    echo "FAIL: $LANG_NAME has extra keys:" >&2
    echo "$EXTRA" | sed 's/^/  /' >&2
    FAILED=1
  fi
done

if [[ "$FAILED" -eq 0 ]]; then
  echo "PASS: localization keys aligned across zh-Hans / en / vi"
fi
exit "$FAILED"
