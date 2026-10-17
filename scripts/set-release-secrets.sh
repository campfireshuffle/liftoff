#!/usr/bin/env bash
# Copies the release signing secrets from Bitwarden into this repo's GitHub "release" environment.
# Values go straight from the Bitwarden CLI to `gh secret set`; nothing is printed or written to disk.
set -euo pipefail

usage() {
  cat <<'EOF'
Copy Liftoff's release secrets from Bitwarden to GitHub.

Usage:
  scripts/set-release-secrets.sh [--repo owner/name] [--only NAME[,NAME…]]
  scripts/set-release-secrets.sh -h | --help

For each secret, search your vault, pick the item, then pick which part holds the value: the
password, username, notes, a custom field, an SSH key, or an attachment. Certificates and keys
are base64-encoded on the way if they aren't already. Only item and field names are shown.

Needs the Bitwarden CLI (bw) and an authenticated GitHub CLI (gh). You'll be asked for your
Bitwarden master password if the vault is locked.
EOF
}

repo="campfireshuffle/liftoff"
only=""
while (($#)); do
  case "$1" in
    --repo) repo="${2:?--repo needs owner/name}"; shift 2 ;;
    --only) only=",${2:?--only needs secret names},"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# name|search hint|encoding: "base64" values are encoded unless they already are base64.
secrets=(
  "MACOS_CERTIFICATE_P12|Developer ID certificate (.p12)|base64"
  "MACOS_CERTIFICATE_PASSWORD|Password for that .p12|plain"
  "APPLE_API_PRIVATE_KEY_P8|App Store Connect API key (.p8)|base64"
  "APPLE_API_KEY_ID|API key ID|plain"
  "APPLE_API_ISSUER_ID|API issuer ID|plain"
  "HOMEBREW_TAP_DEPLOY_KEY_B64|Deploy key for homebrew-tap (SSH private key)|base64"
)

command -v bw >/dev/null || { echo "error: install the Bitwarden CLI: brew install bitwarden-cli" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: log in to GitHub first: gh auth login" >&2; exit 1; }

if [[ "$(bw status | python3 -c 'import sys, json; print(json.load(sys.stdin)["status"])')" != "unlocked" ]]; then
  echo "Unlock Bitwarden:"
  BW_SESSION="$(bw unlock --raw)"
  export BW_SESSION
fi
bw sync >/dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Lists the parts of an item that could hold a value, one per line as "kind<TAB>key<TAB>label".
parts_of() {
  python3 -c '
import json, sys
item = json.load(sys.stdin)
login = item.get("login") or {}
if login.get("password"): print("password\t\tPassword")
if login.get("username"): print("username\t\tUsername")
if item.get("notes"): print("notes\t\tNotes")
for f in item.get("fields") or []:
    print("field\t%s\tField: %s" % (f.get("name", ""), f.get("name", "")))
if (item.get("sshKey") or {}).get("privateKey"): print("ssh\t\tSSH private key")
for a in item.get("attachments") or []:
    print("attachment\t%s\tAttachment: %s" % (a["id"], a["fileName"]))
'
}

# Writes the chosen part of an item to a file, without printing it.
extract() {
  local item_json="$1" kind="$2" key="$3" item_id="$4" out="$5"
  case "$kind" in
    attachment) bw get attachment "$key" --itemid "$item_id" --output "$out" >/dev/null ;;
    *)
      python3 -c '
import json, sys
item, kind, key = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
value = {
    "password": lambda: item["login"]["password"],
    "username": lambda: item["login"]["username"],
    "notes": lambda: item["notes"],
    "field": lambda: next(f["value"] for f in item["fields"] if f.get("name") == key),
    "ssh": lambda: item["sshKey"]["privateKey"],
}[kind]()
sys.stdout.write(value if value.endswith("\n") or kind != "ssh" else value + "\n")
' "$item_json" "$kind" "$key" > "$out"
      ;;
  esac
}

for entry in "${secrets[@]}"; do
  IFS='|' read -r name hint encoding <<< "$entry"
  [[ -z "$only" || "$only" == *",${name},"* ]] || continue
  echo
  echo "== ${name}: ${hint}"
  while true; do
    read -r -p "Search Bitwarden for: " query
    mapfile -t matches < <(bw list items --search "$query" \
      | python3 -c 'import sys, json; [print("%s\t%s" % (i["id"], i["name"])) for i in json.load(sys.stdin)]')
    ((${#matches[@]})) && break
    echo "No items match. Try again."
  done
  for i in "${!matches[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${matches[$i]#*$'\t'}"; done
  read -r -p "Item number: " pick
  item_id="${matches[$((pick - 1))]%%$'\t'*}"
  item_json="$(bw get item "$item_id")"

  mapfile -t parts < <(printf '%s' "$item_json" | parts_of)
  for i in "${!parts[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${parts[$i]##*$'\t'}"; done
  read -r -p "Which part holds ${name}? " part
  IFS=$'\t' read -r kind key _ <<< "${parts[$((part - 1))]}"

  extract "$item_json" "$kind" "$key" "$item_id" "$tmp/value"
  if [[ "$encoding" == "base64" ]] && ! python3 - "$tmp/value" <<'PY'
import base64, re, sys
data = open(sys.argv[1], "rb").read().strip()
# Already base64 text (and not a PEM block)? Then leave it alone.
ok = bool(re.fullmatch(rb"[A-Za-z0-9+/=\s]+", data)) and b"-----BEGIN" not in data
if ok:
    try:
        base64.b64decode(re.sub(rb"\s", b"", data), validate=True)
    except Exception:
        ok = False
sys.exit(0 if ok else 1)
PY
  then
    base64 -i "$tmp/value" | tr -d '\n' > "$tmp/encoded"
    mv "$tmp/encoded" "$tmp/value"
  fi
  # Plain values: drop a trailing newline that came from notes.
  [[ "$encoding" == "plain" ]] && printf '%s' "$(cat "$tmp/value")" > "$tmp/value"

  gh secret set "$name" --env release --repo "$repo" < "$tmp/value"
  rm -f "$tmp/value"
  echo "✓ ${name} set"
done

echo
echo "All set. Secrets in ${repo} (release environment):"
gh secret list --env release --repo "$repo"
