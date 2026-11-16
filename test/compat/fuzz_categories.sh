#!/usr/bin/env bash
# Run each fuzz category separately; default duration matches the release gate.
set -euo pipefail
SECONDS_PER_CATEGORY="${FUZZ_SECONDS:-600}"
for category in http json multipart rev; do
  echo "== fuzz $category (${SECONDS_PER_CATEGORY}s) =="
  FUZZ_CATEGORY="$category" FUZZ_SECONDS="$SECONDS_PER_CATEGORY" python3 test/compat/fuzz.py
done
