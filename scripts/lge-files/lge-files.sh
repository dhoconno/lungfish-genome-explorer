#!/usr/bin/env bash
# lge-files.sh - store and serve LGE files that do not belong in git.
#
# Files live in the LGE LabKey folder (https://dholk.primate.wisc.edu/dho/public/lge/project-begin.view),
# reached over WebDAV. See docs/development/large-files.md for the contract.
#
#   lge-files.sh ls    [remote-dir]          list a folder (default: the root)
#   lge-files.sh mkdir <remote-dir>          create a folder and any missing parents
#   lge-files.sh put   <local-file> <remote-path>   upload (creates parent folders, verifies size)
#   lge-files.sh sync  <local-dir> <remote-dir>     upload every file under a directory, skipping
#                                                   files already present with the same size
#   lge-files.sh get   <remote-path> <local-file>   download
#   lge-files.sh url   <remote-path>         print the browser/download URL
#   lge-files.sh rm    <remote-path>         delete one file (only when a person asked for it)
#
# The API key is read from LABKEY_APIKEY in ~/.env (override the file with LGE_FILES_ENV) at run
# time, inside this process only, and handed to curl on stdin, so it never appears in a command
# line, the process list, logs or output. LGE_FILES_WEBDAV overrides the folder's WebDAV root.

set -euo pipefail

ROOT="${LGE_FILES_WEBDAV:-https://dholk.primate.wisc.edu/_webdav/dho/public/lge/%40files}"
ROOT="${ROOT%/}"
ENV_FILE="${LGE_FILES_ENV:-$HOME/.env}"

die() { echo "lge-files: $*" >&2; exit 1; }

load_key() {
  [[ -r "$ENV_FILE" ]] || die "cannot read $ENV_FILE"
  # Read only the one variable, without sourcing the rest of the file.
  LGE_KEY="$(sed -nE 's/^(export[[:space:]]+)?LABKEY_APIKEY=//p' "$ENV_FILE" | tail -1)"
  LGE_KEY="${LGE_KEY%\"}"; LGE_KEY="${LGE_KEY#\"}"; LGE_KEY="${LGE_KEY%\'}"; LGE_KEY="${LGE_KEY#\'}"
  [[ -n "$LGE_KEY" ]] || die "LABKEY_APIKEY is not set in $ENV_FILE"
}

# curl with the key supplied as a config file on stdin (never on the command line).
lk() {
  printf 'user = "apikey:%s"\n' "$LGE_KEY" | curl -sS -K - --fail-with-body "$@"
}

# Percent-encode each path segment, keeping the slashes.
enc() {
  python3 -c 'import sys, urllib.parse; print("/".join(urllib.parse.quote(p) for p in sys.argv[1].strip("/").split("/") if p))' "$1"
}

remote_url() { local p; p="$(enc "$1")"; [[ -n "$p" ]] && echo "$ROOT/$p" || echo "$ROOT"; }

cmd_ls() {
  local url; url="$(remote_url "${1:-}")/"
  lk -X PROPFIND -H "Depth: 1" "$url" | python3 -c '
import sys, re, urllib.parse
xml = sys.stdin.read()
for resp in re.findall(r"<response>(.*?)</response>", xml, re.S):
    href = urllib.parse.unquote(re.search(r"<href>([^<]+)", resp).group(1))
    size = re.search(r"<getcontentlength>(\d+)", resp)
    folder = "<collection" in resp
    print(("dir " if folder else "file"), (size.group(1) if size else "-").rjust(12), href.split("@files", 1)[-1] or "/")
'
}

remote_size() {
  lk -X PROPFIND -H "Depth: 0" "$(remote_url "$1")" 2>/dev/null | sed -nE 's/.*<getcontentlength>([0-9]+)<.*/\1/p' | head -1
}

cmd_mkdir() {
  local path="" seg
  IFS='/' read -r -a segs <<< "${1#/}"
  for seg in "${segs[@]}"; do
    [[ -z "$seg" ]] && continue
    path="$path/$seg"
    if ! lk -o /dev/null -X PROPFIND -H "Depth: 0" "$(remote_url "$path")/" 2>/dev/null; then
      lk -o /dev/null -X MKCOL "$(remote_url "$path")/" || die "could not create $path"
    fi
  done
}

cmd_put() {
  local file="$1" dest="$2"
  [[ -f "$file" ]] || die "no such file: $file"
  cmd_mkdir "$(dirname "$dest")"
  lk -o /dev/null -T "$file" "$(remote_url "$dest")" || die "upload failed: $dest"
  local want got
  want="$(wc -c < "$file" | tr -d " ")"; got="$(remote_size "$dest")"
  [[ "$want" == "$got" ]] || die "size mismatch after upload of $dest (local $want, remote ${got:-none})"
  echo "put $dest ($want bytes)"
}

cmd_sync() {
  local src="${1%/}" dest="${2%/}" rel size
  [[ -d "$src" ]] || die "no such directory: $src"
  while IFS= read -r -d '' f; do
    rel="${f#"$src"/}"
    size="$(wc -c < "$f" | tr -d " ")"
    if [[ "$(remote_size "$dest/$rel")" == "$size" ]]; then echo "skip $dest/$rel"; continue; fi
    cmd_put "$f" "$dest/$rel"
  done < <(find "$src" -type f ! -name '.DS_Store' -print0 | sort -z)
}

cmd_get() { lk -o "$2" "$(remote_url "$1")" && echo "got $1"; }
cmd_url() { remote_url "$1"; }
cmd_rm()  { lk -o /dev/null -X DELETE "$(remote_url "$1")" && echo "deleted $1"; }

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    url) [[ $# -eq 1 ]] || die "usage: url <remote-path>"; cmd_url "$1"; return ;;
    ls|mkdir|put|sync|get|rm) ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
  esac
  load_key
  case "$cmd" in
    ls) cmd_ls "${1:-}" ;;
    mkdir) [[ $# -eq 1 ]] || die "usage: mkdir <remote-dir>"; cmd_mkdir "$1" ;;
    put) [[ $# -eq 2 ]] || die "usage: put <local-file> <remote-path>"; cmd_put "$1" "$2" ;;
    sync) [[ $# -eq 2 ]] || die "usage: sync <local-dir> <remote-dir>"; cmd_sync "$1" "$2" ;;
    get) [[ $# -eq 2 ]] || die "usage: get <remote-path> <local-file>"; cmd_get "$1" "$2" ;;
    rm) [[ $# -eq 1 ]] || die "usage: rm <remote-path>"; cmd_rm "$1" ;;
  esac
}

main "$@"
