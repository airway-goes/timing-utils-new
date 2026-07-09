#!/usr/bin/env bash
#
# Download all images referenced in a GitHub repo's issues (and optionally
# comments) and save them locally with a clear filename:
#
#   {serial}-{repo}-issue{issue_number}-{alt-text}.{ext}
#
# Requirements: gh CLI (run `gh auth login` once), jq
#
# Usage:
#   ./download_issue_images.sh owner/repo [output_dir] [--include-comments] [--debug]
#
# Examples:
#   ./download_issue_images.sh dev-badprogrammer/timing-utils
#   ./download_issue_images.sh dev-badprogrammer/timing-utils ./downloaded --include-comments
#   ./download_issue_images.sh dev-badprogrammer/timing-utils --include-comments --debug

set -uo pipefail  # (dropped -e: we want to keep going / report on individual failures)

OUT_DIR="./downloaded_images"
INCLUDE_COMMENTS=false
DEBUG=false

# --- flexible arg parsing: flags can appear anywhere ---
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --include-comments) INCLUDE_COMMENTS=true ;;
    --debug) DEBUG=true ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

REPO="${POSITIONAL[0]:-}"
[[ -n "${POSITIONAL[1]:-}" ]] && OUT_DIR="${POSITIONAL[1]}"

if [[ -z "$REPO" ]]; then
  echo "Usage: $0 owner/repo [output_dir] [--include-comments] [--debug]"
  exit 1
fi

REPO_SHORT_NAME="${REPO##*/}"
SERIAL=1
TOTAL=0

mkdir -p "$OUT_DIR"

command -v gh >/dev/null 2>&1 || { echo "Error: gh CLI not found. Install from https://cli.github.com/"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found."; exit 1; }

debug() { [[ "$DEBUG" == true ]] && echo "[debug] $*" >&2; }

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
    | cut -c1-60
}

guess_extension() {
  local url="$1" content_type="$2"
  local path_no_query="${url%%\?*}"
  local ext="${path_no_query##*.}"
  if [[ "$ext" != "$path_no_query" && ${#ext} -le 5 ]]; then
    echo ".$ext"
    return
  fi
  case "$content_type" in
    *jpeg*) echo ".jpg" ;;
    *png*)  echo ".png" ;;
    *gif*)  echo ".gif" ;;
    *webp*) echo ".webp" ;;
    *svg*)  echo ".svg" ;;
    *)      echo ".png" ;;
  esac
}

download_image() {
  local url="$1" dest_no_ext="$2"
  local headers_file
  headers_file="$(mktemp)"

  if ! curl -sSL -D "$headers_file" -o "${dest_no_ext}.tmp" "$url"; then
    echo "  ! failed to download $url"
    rm -f "$headers_file" "${dest_no_ext}.tmp"
    return 1
  fi

  local content_type
  content_type="$(grep -i '^content-type:' "$headers_file" | tail -1 | cut -d':' -f2- | tr -d '\r\n ' || true)"
  rm -f "$headers_file"

  if [[ ! -s "${dest_no_ext}.tmp" ]]; then
    echo "  ! downloaded empty file for $url"
    rm -f "${dest_no_ext}.tmp"
    return 1
  fi

  local ext
  ext="$(guess_extension "$url" "$content_type")"
  mv "${dest_no_ext}.tmp" "${dest_no_ext}${ext}"
  echo "${dest_no_ext}${ext}"
}

# Extracts "alt<TAB>url" lines from a block of text, covering:
#   1) markdown images:  ![alt](url)
#   2) html img tags:    <img ... src="url" ... alt="alt" ...>
#   3) bare attachment/asset URLs not wrapped in either of the above
extract_images() {
  local text="$1"
  local seen=$'\n'

  # 1. Markdown images
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local alt url
    alt="$(echo "$line" | sed -E 's/!\[([^]]*)\]\(([^)]+)\)/\1/')"
    url="$(echo "$line" | sed -E 's/!\[([^]]*)\]\(([^)]+)\)/\2/')"
    [[ -z "$url" ]] && continue
    case "$seen" in *$'\n'"$url"$'\n'*) continue ;; esac
    seen="${seen}${url}"$'\n'
    printf '%s\t%s\n' "${alt:-image}" "$url"
  done < <(echo "$text" | grep -oE '!\[[^]]*\]\([^)]+\)' || true)

  # 2. HTML <img> tags
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    local url alt
    url="$(echo "$tag" | grep -oE 'src="[^"]+"' | head -1 | sed 's/src="//;s/"$//')"
    alt="$(echo "$tag" | grep -oE 'alt="[^"]*"' | head -1 | sed 's/alt="//;s/"$//')"
    [[ -z "$url" ]] && continue
    case "$seen" in *$'\n'"$url"$'\n'*) continue ;; esac
    seen="${seen}${url}"$'\n'
    printf '%s\t%s\n' "${alt:-image}" "$url"
  done < <(echo "$text" | grep -oE '<img[^>]*>' || true)

  # 3. Bare GitHub attachment/asset URLs not already captured above
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    case "$seen" in *$'\n'"$url"$'\n'*) continue ;; esac
    seen="${seen}${url}"$'\n'
    printf '%s\t%s\n' "image" "$url"
  done < <(echo "$text" | grep -oE 'https://[^[:space:]"()<>]*(user-attachments/assets|githubusercontent\.com)[^[:space:]"()<>]*' || true)
}

echo "Fetching issues for $REPO ..."

PAGE=1
while true; do
  ISSUES_JSON="$(gh api "repos/$REPO/issues?state=all&per_page=100&page=$PAGE" 2>&1)"
  if ! echo "$ISSUES_JSON" | jq -e . >/dev/null 2>&1; then
    echo "Error calling GitHub API. Response was:"
    echo "$ISSUES_JSON"
    break
  fi

  COUNT="$(echo "$ISSUES_JSON" | jq 'length')"
  debug "page $PAGE: $COUNT item(s)"
  if [[ "$COUNT" -eq 0 ]]; then
    break
  fi

  while IFS=$'\t' read -r issue_num body_b64 comments_url is_pr; do
    if [[ "$is_pr" == "true" ]]; then
      continue
    fi

    body="$(echo "$body_b64" | base64 -d 2>/dev/null || true)"
    debug "issue #$issue_num body length: ${#body} chars"

    ALL_MATCHES="$(extract_images "$body")"

    if [[ "$INCLUDE_COMMENTS" == true && -n "$comments_url" && "$comments_url" != "null" ]]; then
      COMMENTS_JSON="$(gh api "$comments_url" 2>/dev/null || echo "[]")"
      NUM_COMMENTS="$(echo "$COMMENTS_JSON" | jq 'length' 2>/dev/null || echo 0)"
      debug "issue #$issue_num has $NUM_COMMENTS comment(s)"
      while IFS= read -r cbody_b64; do
        [[ -z "$cbody_b64" ]] && continue
        cbody="$(echo "$cbody_b64" | base64 -d 2>/dev/null || true)"
        c_matches="$(extract_images "$cbody")"
        [[ -n "$c_matches" ]] && ALL_MATCHES="${ALL_MATCHES}${ALL_MATCHES:+$'\n'}${c_matches}"
      done < <(echo "$COMMENTS_JSON" | jq -r '.[] | (.body // "" | @base64)' 2>/dev/null)
    fi

    [[ -z "$ALL_MATCHES" ]] && continue

    while IFS=$'\t' read -r alt url; do
      [[ -z "$url" ]] && continue
      alt_slug="$(slugify "${alt:-image}")"
      [[ -z "$alt_slug" ]] && alt_slug="image"

      filename_no_ext="$(printf "%03d-%s-issue%s-%s" "$SERIAL" "$REPO_SHORT_NAME" "$issue_num" "$alt_slug")"
      dest_no_ext="$OUT_DIR/$filename_no_ext"

      printf "[%03d] issue #%s: %s\n" "$SERIAL" "$issue_num" "$url"
      if saved_path="$(download_image "$url" "$dest_no_ext")"; then
        echo "      -> $saved_path"
        SERIAL=$((SERIAL + 1))
        TOTAL=$((TOTAL + 1))
      fi
    done <<< "$ALL_MATCHES"

  done < <(echo "$ISSUES_JSON" | jq -r '.[] | [.number, (.body // "" | @base64), (.comments_url // ""), (has("pull_request"))] | @tsv')

  PAGE=$((PAGE + 1))
done

echo ""
echo "Done. Downloaded $TOTAL image(s) into $OUT_DIR/"
