# Large files outside git

Some LGE work produces files that must be kept and shared but do not belong in git: screencast renders and raw takes, large test or demo inputs, exported packages, review captures. They live in the LGE LabKey folder and are reached over WebDAV.

- Folder: https://dholk.primate.wisc.edu/dho/public/lge/project-begin.view
- WebDAV root: `https://dholk.primate.wisc.edu/_webdav/dho/public/lge/%40files/`
- Tool: `scripts/lge-files/lge-files.sh` (`ls`, `mkdir`, `put`, `sync`, `get`, `url`, `rm`)

The folder is public: anyone can download a file from its URL without signing in. Writing needs the LabKey API key.

## Rules

1. **Never commit large binaries.** Anything over about 5 MB that is generated, recorded or downloaded (videos, ProRes takes, DMGs, archives, BAM and FASTQ beyond small test fixtures) goes to the LabKey folder, not git. Check `.gitignore` before `git add` on any folder that holds such files.
2. **Use the tool, never raw credentials.** `lge-files.sh` reads `LABKEY_APIKEY` from `~/.env` at run time and gives it to `curl` on stdin. Agents and scripts must not print, log, copy, commit or otherwise read the key into a transcript, and must not pass it on a command line. Only variable names may be inspected.
3. **Organise by area and topic.** Top-level folders name the area, for example `screencasts/<video-slug>/renders/`, `screencasts/<video-slug>/takes/`. Create subfolders freely with `mkdir` or `put`.
4. **Record what was stored.** Every upload that the repository depends on is listed in a committed manifest next to the work that uses it (for example `screencasts/<video-slug>/large-files.tsv`) with the remote path, size in bytes, SHA-256 and download URL. Anyone can then fetch and verify the files with `lge-files.sh get` and `shasum -a 256`.
5. **Public by default.** Do not upload anything that is private: credentials, unpublished or identifiable human data, the owner's personal paths or data. Scan renders and screenshots for home-folder paths first.
6. **Deletion needs a person.** `rm` is for files an agent uploaded by mistake in the same task, or when the owner asks. Replace a file by uploading the new version under a new name or version folder, then update the manifest.

## Usage

```bash
scripts/lge-files/lge-files.sh ls screencasts
scripts/lge-files/lge-files.sh sync screencasts/01-lge-overview/out screencasts/01-lge-overview/renders
scripts/lge-files/lge-files.sh url screencasts/01-lge-overview/renders/01-lge-overview-v2-wide.mp4
```

`sync` skips files already present with the same size, so it can be rerun after an interruption. `put` checks the remote size after every upload.

## Limits

- The LabKey MCP server configured for agents points at labkey.org, not at dholk.primate.wisc.edu, so it cannot see this folder. Use the tool.
- `LABKEY_WEBDAV_URL` in `~/.env` points at a different folder; the tool ignores it and uses the LGE root above (override with `LGE_FILES_WEBDAV`).
