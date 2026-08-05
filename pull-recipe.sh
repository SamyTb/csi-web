#!/usr/bin/env bash
#
# Download a Workato recipe by ID into recipes/<name>.recipe.json
#
# Usage:
#   ./pull-recipe.sh <recipe_id>
#
# Auth: set WORKATO_API_TOKEN in .env (next to this script) or in your environment.
# Optional: WORKATO_BASE_URL (defaults to https://www.workato.com)

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# Load token from .env if present
if [ -f "$DIR/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$DIR/.env"
  set +a
fi

: "${WORKATO_API_TOKEN:?WORKATO_API_TOKEN is not set. Add it to $DIR/.env or export it.}"
RECIPE_ID="${1:?Usage: pull-recipe.sh <recipe_id>}"
BASE_URL="${WORKATO_BASE_URL:-https://www.workato.com}"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

HTTP_CODE=$(curl -s -w '%{http_code}' -o "$TMP" \
  -H "Authorization: Bearer $WORKATO_API_TOKEN" \
  "$BASE_URL/api/recipes/$RECIPE_ID")

if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: HTTP $HTTP_CODE fetching recipe $RECIPE_ID" >&2
  cat "$TMP" >&2
  exit 1
fi

mkdir -p "$DIR/recipes"

OUT=$(TMP="$TMP" OUTDIR="$DIR/recipes" python3 <<'EOF'
import json, os, re

raw = json.load(open(os.environ["TMP"]))

# Expand the embedded recipe code string into real JSON for readable diffs
if isinstance(raw.get("code"), str):
    raw["code"] = json.loads(raw["code"])

slug = re.sub(r"[^a-z0-9]+", "_", raw["name"].lower()).strip("_")
out = os.path.join(os.environ["OUTDIR"], f"{slug}.recipe.json")

with open(out, "w") as f:
    json.dump(raw, f, indent=2)
    f.write("\n")

print(out)
EOF
)

echo "Recipe $RECIPE_ID downloaded:"
echo "  $OUT"
