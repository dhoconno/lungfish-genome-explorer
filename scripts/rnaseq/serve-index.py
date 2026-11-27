#!/usr/bin/env python3
"""Zip a published salmon index for serving and print the catalog row's fields (2026-11-27).

`docs/plans/2026-11-27-rnaseq-served-salmon-index.md`, step 2. The archive holds the key folder's `index/` and
`index-key.json` and nothing else, since `provenance/` and `uses/` name the building Mac's paths. Every entry has a
fixed time and mode, so the same index always gives the same archive bytes. After writing, it reads every entry back
and checks its sha256 against the published file, and checks that no entry names a path of this Mac.

    python3 -I scripts/rnaseq/serve-index.py --storage-root ROOT --set SET_ID --out DIR

Prints one JSON object: the ServedSalmonIndex fields and the large-files.tsv row. It reads the index and writes only
under DIR. Run it on galah from the locked environment's index, never upload from it.
"""

import argparse
import hashlib
import json
import os
import sys
import zipfile

PUBLIC_WEBDAV = "https://dholk.primate.wisc.edu/_webdav/dho/public/lge/%40files/"
REMOTE_FOLDER = "databases/rnaseq-index"
FIXED_TIME = (1980, 1, 1, 0, 0, 0)
CHUNK = 8 * 1024 * 1024
LOCAL_MARKERS = (b"/Volumes/", b"/Users/", b"/private/var/", b".creating-")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def key_folder(storage_root, set_id, k, decoys):
    folder = os.path.join(storage_root, "rnaseq-index-cache", set_id)
    suffix = f"-k{k}-{decoys}"
    names = sorted(n for n in os.listdir(folder) if n.startswith("salmon-") and n.endswith(suffix))
    if len(names) != 1:
        sys.exit(f"serve-index: expected one salmon-*{suffix} folder in {folder}, found {names}")
    return os.path.join(folder, names[0])


def entries(folder):
    index = os.path.join(folder, "index")
    names = ["index-key.json"] + [f"index/{n}" for n in sorted(os.listdir(index))]
    for name in names:
        path = os.path.join(folder, name)
        if os.path.islink(path) or not os.path.isfile(path):
            sys.exit(f"serve-index: {path} is not a plain file")
    return names


def write_archive(folder, names, archive):
    os.makedirs(os.path.dirname(archive), exist_ok=True)
    partial = archive + ".partial"
    with zipfile.ZipFile(partial, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as out:
        for name in names:
            info = zipfile.ZipInfo(name, date_time=FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            info.create_system = 3
            with open(os.path.join(folder, name), "rb") as source, out.open(info, "w", force_zip64=True) as sink:
                for block in iter(lambda: source.read(CHUNK), b""):
                    sink.write(block)
    os.replace(partial, archive)


def verify(folder, names, archive):
    """Each entry reads back with the published file's sha256, and the small text entries name no local path."""
    with zipfile.ZipFile(archive) as zipped:
        listed = [i.filename for i in zipped.infolist()]
        if listed != names:
            sys.exit(f"serve-index: the archive lists {listed}, not {names}")
        for name in names:
            digest = hashlib.sha256()
            text = b""
            with zipped.open(name) as handle:
                for block in iter(lambda: handle.read(CHUNK), b""):
                    digest.update(block)
                    if name.endswith((".json", ".tsv")) and len(text) < 64 * 1024 * 1024:
                        text += block
            if digest.hexdigest() != sha256_file(os.path.join(folder, name)):
                sys.exit(f"serve-index: {name} reads back with another sha256")
            for marker in LOCAL_MARKERS:
                if marker in text:
                    sys.exit(f"serve-index: {name} names a local path ({marker.decode()})")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--storage-root", required=True)
    parser.add_argument("--set", required=True, dest="set_id")
    parser.add_argument("--out", required=True)
    parser.add_argument("--k", type=int, default=31)
    parser.add_argument("--decoys", default="genome-decoys")
    args = parser.parse_args()

    folder = key_folder(args.storage_root, args.set_id, args.k, args.decoys)
    with open(os.path.join(folder, "index-key.json"), encoding="utf-8") as handle:
        key = json.load(handle)
    if key["setID"] != args.set_id or key["k"] != args.k or key["decoys"] != args.decoys:
        sys.exit(f"serve-index: {folder}/index-key.json names another key")
    names = entries(folder)
    key_name = os.path.basename(folder)
    remote = f"{REMOTE_FOLDER}/{args.set_id}/{key_name}/{args.set_id}-{key_name}.zip"
    archive = os.path.join(args.out, remote)
    write_archive(folder, names, archive)
    verify(folder, names, archive)

    unpacked = sum(os.path.getsize(os.path.join(folder, n)) for n in names)
    archive_bytes = os.path.getsize(archive)
    archive_sha = sha256_file(archive)
    url = PUBLIC_WEBDAV + remote
    print(json.dumps({
        "archive": archive,
        "served": {
            "url": url, "archiveBytes": archive_bytes, "archiveSHA256": archive_sha, "unpackedBytes": unpacked,
            "setID": args.set_id, "salmonBuild": key["salmonBuild"], "k": key["k"], "decoys": key["decoys"],
        },
        "largeFilesRow": ["public", remote, archive_bytes, archive_sha, url],
    }, indent=2))


if __name__ == "__main__":
    main()
