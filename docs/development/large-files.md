# Large files outside git

Some LGE work produces files that must be kept and shared but do not belong in git: screencast renders and raw takes, large test or demo inputs, exported packages, review captures. They live in the LGE LabKey folder and are reached over WebDAV.

There are two areas:

| Area | Folder | WebDAV root | Who can read |
|---|---|---|---|
| public (default) | https://dholk.primate.wisc.edu/dho/public/lge/project-begin.view | `https://dholk.primate.wisc.edu/_webdav/dho/public/lge/%40files/` | anyone, no sign-in |
| internal | https://dholk.primate.wisc.edu/dho/public/lge/internal/project-begin.view | `https://dholk.primate.wisc.edu/_webdav/dho/public/lge/internal/%40files/` | signed-in members only (anonymous requests get 401) |

Tool: `scripts/lge-files/lge-files.sh [--internal] <ls|mkdir|put|sync|get|url|rm>`. Without `--internal` (or `LGE_FILES_AREA=internal`) it uses the public area. Writing to either area needs the LabKey API key.

## Rules

1. **Never commit large binaries.** Anything over about 5 MB that is generated, recorded or downloaded (videos, ProRes takes, DMGs, archives, BAM and FASTQ beyond small test fixtures) goes to the LabKey folder, not git. Check `.gitignore` before `git add` on any folder that holds such files.
2. **Use the tool, never raw credentials.** `lge-files.sh` reads `LABKEY_APIKEY` from `~/.env` at run time and gives it to `curl` on stdin. Agents and scripts must not print, log, copy, commit or otherwise read the key into a transcript, and must not pass it on a command line. Only variable names may be inspected.
3. **Organise by area and topic.** Top-level folders name the area, for example `screencasts/<video-slug>/renders/`, `screencasts/<video-slug>/takes/`. Create subfolders freely with `mkdir` or `put`.
4. **Record what was stored.** Every upload that the repository depends on is listed in a committed manifest next to the work that uses it (for example `screencasts/<video-slug>/large-files.tsv`) with the area, remote path, size in bytes, SHA-256 and download URL. Anyone can then fetch and verify the files with `lge-files.sh get` and `shasum -a 256`.
5. **Choose the area deliberately.** The public area is for files meant to be shared: finished renders, posters, demo data, release media. Anything that shows the owner's personal paths, folders or accounts, unpublished results, raw captures or working material goes to the internal area with `--internal`. Scan renders and screenshots for home-folder paths before using the public area. Never upload credentials or identifiable human data to either area.
6. **The public area holds only what users should see.** Keep one current version of each item there under a plain name (for a screencast, the wide render `<slug>.mp4` and its poster, no square cuts and no earlier cuts). When a newer version replaces it, overwrite it under the same name and update the manifest. Earlier versions, alternative cuts and raw material go to the internal area or stay local.
7. **Deletion needs a person.** `rm` is for files an agent uploaded by mistake in the same task, or when the owner asks. In the internal area, replace a file by uploading the new version under a new name or version folder; in the public area, follow rule 6. Update the manifest either way.

## Usage

```bash
scripts/lge-files/lge-files.sh ls screencasts
scripts/lge-files/lge-files.sh put screencasts/01-lge-overview/out/01-lge-overview-v2-wide.mp4 screencasts/01-lge-overview/renders/01-lge-overview.mp4
scripts/lge-files/lge-files.sh url screencasts/01-lge-overview/renders/01-lge-overview.mp4
scripts/lge-files/lge-files.sh --internal sync screencasts/01-lge-overview/takes-v2 screencasts/01-lge-overview/takes-v2
```

`sync` skips files already present with the same size, so it can be rerun after an interruption. `put` checks the remote size after every upload.

## Limits

- The LabKey MCP server configured for agents points at labkey.org, not at dholk.primate.wisc.edu, so it cannot see this folder. Use the tool.
- `LABKEY_WEBDAV_URL` in `~/.env` points at a different folder; the tool ignores it and uses the LGE root above (override with `LGE_FILES_WEBDAV`).
