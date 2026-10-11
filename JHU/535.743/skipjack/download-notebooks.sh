#!/usr/bin/env bash
# Download the Jupyter notebooks whose names start with "(535_743)_" from
#   https://github.com/mhrafiei/contents/tree/main/JHU/535.743/codes
# into ./535743_notebooks using wget.
# Run: bash get_535743_notebooks.sh

set -Eeuo pipefail

OWNER="mhrafiei"
REPO="contents"
BRANCH="main"
FOLDER="JHU/535.743/codes"
OUT_DIR="535743_notebooks"
PREFIX="(535_743)_"   # only notebooks whose file name starts with this

API_URL="https://api.github.com/repos/$OWNER/$REPO/contents/$FOLDER?ref=$BRANCH"

if ! command -v wget >/dev/null 2>&1; then
    echo "STOP: wget is not installed." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

# 1) Ask GitHub for the folder's file list and keep only the .ipynb download links
#    whose (decoded) file name starts with PREFIX.
echo "Listing notebooks in $OWNER/$REPO/$FOLDER..."
listing="$(wget -q -O - --header="Accept: application/vnd.github+json" "$API_URL")" || {
    echo "STOP: Could not reach the GitHub API (offline, or rate-limited: 60 requests/hour)." >&2
    exit 1
}

mapfile -t all_urls < <(
    printf '%s\n' "$listing" \
    | grep -o '"download_url": *"[^"]*\.ipynb"' \
    | sed -E 's/^"download_url": *"(.*)"$/\1/'
)

urls=()
for url in "${all_urls[@]}"; do
    encoded_name="${url##*/}"
    name="$(printf '%b' "${encoded_name//%/\\x}")"   # decode %28 -> ( etc.
    if [[ "$name" == "$PREFIX"* ]]; then
        urls+=("$url")
    fi
done

if (( ${#urls[@]} == 0 )); then
    echo "STOP: No notebooks starting with $PREFIX found in the folder listing." >&2
    exit 1
fi
echo "Found ${#urls[@]} notebooks starting with $PREFIX (of ${#all_urls[@]} notebooks in the folder)."

# 2) Download each notebook into OUT_DIR, keeping its original file name.
ok=0
failed=()
for url in "${urls[@]}"; do
    encoded_name="${url##*/}"
    name="$(printf '%b' "${encoded_name//%/\\x}")"   # decode %28 -> ( etc.
    echo "Downloading: $name"
    if wget -q --tries=3 -O "$OUT_DIR/$name" "$url"; then
        ok=$((ok + 1))
    else
        rm -f "$OUT_DIR/$name"
        failed+=("$name")
    fi
done

echo
echo "Saved $ok of ${#urls[@]} notebooks to: $(cd "$OUT_DIR" && pwd)"
if (( ${#failed[@]} > 0 )); then
    echo "Failed:" >&2
    printf '  %s\n' "${failed[@]}" >&2
    exit 1
fi