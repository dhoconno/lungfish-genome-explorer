"""Withdraw ("yank") a bad release from a Sparkle channel feed (REL-04, D17).

Each publish overwrites the mutable per-channel appcast asset
(``sparkle-beta/appcast-beta.xml``, ``sparkle-stable/appcast-stable.xml``)
with a fresh single-item appcast. Preview also mirrors that item into the
legacy ``sparkle-alpha/appcast-alpha.xml`` bridge. Before this module there
was no supported way to stop Sparkle offering a bad build short of a full
package and publish of a correction.

What a yank does
----------------
1. Removes the yanked version's ``<item>`` from the channel feed (and from the
   Preview bridge when it is there), so Sparkle stops offering it to clients
   that have not updated yet. Removing the item works on every Sparkle
   version, unlike channel tags or impossible minimum-OS tricks.
2. Optionally puts back the last good item from a retained appcast
   (``--restore-appcast``), after checking that its DMG is still attached to
   its GitHub release with the advertised size. Clients further behind then
   still get a known-good update.
3. Writes a ``<lge:yanked build=... version=...>`` marker into the feed's
   ``<channel>``. Sparkle ignores unknown elements outside ``<item>``, but
   ``check-sparkle-build-number.py`` counts the marker, so the live
   build-number floor never drops. The next publish must still exceed the
   yanked build, which keeps ``CFBundleVersion`` monotonic without any
   "allow equal" escape hatch in the floor gate.
4. Marks the yanked GitHub release as a prerelease, prefixes its title with
   ``Yanked:`` and prepends a note. Tag and assets stay, so anyone who already
   downloaded the DMG keeps a working, verifiable artifact and history stays
   intact.

What a yank cannot do
---------------------
Sparkle never downgrades. Clients that already installed the yanked build
stay on it until a HIGHER build ships, so every yank is followed by a normal
forward-fix ``package``/``publish``.

Safety rules
------------
* Plan-only by default. ``execute_yank`` runs only when the caller confirmed
  by typing the exact version.
* Refuses, without ``force``, to leave the channel feed with no ``<item>``
  (yanking the only item without a restore item) and to yank the current
  Stable baseline (the repository's latest full GitHub release).
* Always refuses (even with ``force``) a result that lowers the feed's build
  floor, a restore item that is not strictly older than the yanked build, and
  a restore item whose DMG is missing or has changed size.
* Idempotent. Re-running after an interruption skips feed uploads that
  already landed and a release that is already marked.

Every GitHub or network call goes through a ``YankRunner`` so tests use fakes.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
import json
import tempfile
from typing import Callable, Protocol
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"
LGE_RELEASE_NS = "urn:lungfish-genome-explorer:release"
SPARKLE_VERSION_TAG = f"{{{SPARKLE_NS}}}version"
SPARKLE_SHORT_VERSION_TAG = f"{{{SPARKLE_NS}}}shortVersionString"
YANK_MARKER_TAG = f"{{{LGE_RELEASE_NS}}}yanked"
YANKED_TITLE_PREFIX = "Yanked: "

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)
ET.register_namespace("lge", LGE_RELEASE_NS)


class YankError(RuntimeError):
    """Raised when a yank cannot be planned or must not proceed."""


# --------------------------------------------------------------------------
# Appcast parsing and the build floor
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class AppcastItem:
    """One <item> from a Sparkle appcast, with just the fields a yank needs."""

    title: str
    sparkle_version: int
    short_version: str | None
    enclosure_url: str | None
    enclosure_length: int | None


def _item_from_element(item_element: ET.Element) -> AppcastItem:
    version_element = item_element.find(SPARKLE_VERSION_TAG)
    if version_element is None or not (version_element.text or "").strip().isdigit():
        raise YankError("appcast <item> is missing a numeric sparkle:version")
    short_version_element = item_element.find(SPARKLE_SHORT_VERSION_TAG)
    title_element = item_element.find("title")
    enclosure = item_element.find("enclosure")
    length_text = enclosure.get("length", "") if enclosure is not None else ""
    return AppcastItem(
        title=(title_element.text or "").strip() if title_element is not None else "",
        sparkle_version=int(version_element.text.strip()),
        short_version=(short_version_element.text or "").strip() if short_version_element is not None else None,
        enclosure_url=enclosure.get("url") if enclosure is not None else None,
        enclosure_length=int(length_text) if length_text.isdigit() else None,
    )


def _parse_root(appcast_xml: bytes | str) -> ET.Element:
    try:
        return ET.fromstring(appcast_xml)
    except ET.ParseError as error:
        raise YankError(f"appcast is not valid XML: {error}") from error


def _channel(root: ET.Element) -> ET.Element:
    channel = root.find("channel")
    if channel is None:
        raise YankError("appcast has no <channel> element")
    return channel


def parse_appcast_items(appcast_xml: bytes | str) -> list[AppcastItem]:
    """Parses every <item> in a Sparkle appcast. An empty list is allowed."""
    return [_item_from_element(element) for element in _channel(_parse_root(appcast_xml)).findall("item")]


def yank_markers(appcast_xml: bytes | str) -> list[tuple[int, str]]:
    """Returns (build, version) for every yank marker in the appcast."""
    markers = []
    for element in _parse_root(appcast_xml).iter(YANK_MARKER_TAG):
        build = element.get("build", "")
        if not build.isdigit():
            raise YankError("yank marker is missing a numeric build attribute")
        markers.append((int(build), element.get("version", "")))
    return markers


def appcast_build_floor(appcast_xml: bytes | str) -> int | None:
    """The highest build an appcast has ever offered: items plus yank markers.

    ``check-sparkle-build-number.py`` applies the same rule, so a yank never
    lowers the floor the next publish has to clear.
    """
    builds = [item.sparkle_version for item in parse_appcast_items(appcast_xml)]
    builds.extend(build for build, _ in yank_markers(appcast_xml))
    return max(builds) if builds else None


# --------------------------------------------------------------------------
# Runner seam: every GitHub or network call goes through this
# --------------------------------------------------------------------------


class YankRunner(Protocol):
    def fetch_appcast(self, release: str, filename: str) -> bytes | None:
        """The live feed asset bytes, or None when the asset does not exist."""

    def release_info(self, tag: str) -> dict | None:
        """``gh release view --json`` fields (name, body, isPrerelease, assets), or None."""

    def latest_full_release_tag(self) -> str | None:
        """The repository's latest non-prerelease release tag (the Stable baseline)."""

    def upload_appcast(self, release: str, filename: str, content: bytes) -> None:
        """Replaces the named feed asset on the mutable release."""

    def mark_release_yanked(self, tag: str, title: str, body: str) -> None:
        """Marks the release prerelease and sets its title and notes."""


class GitHubYankRunner:
    """Real runner: public HTTPS reads, ``gh`` for authenticated calls.

    ``command_runner`` is release.py's ``SubprocessRunner`` (anything with a
    compatible ``run(command, capture=, check=)``), so ``gh`` inherits its
    repository pinning, prompt suppression and bounded timeout.
    """

    def __init__(self, repository: str, command_runner, urlopen: Callable = urllib.request.urlopen):
        self.repository = repository
        self.command_runner = command_runner
        self.urlopen = urlopen

    def fetch_appcast(self, release: str, filename: str) -> bytes | None:
        url = (
            f"https://github.com/{self.repository}/releases/download/"
            f"{urllib.parse.quote(release)}/{urllib.parse.quote(filename)}"
        )
        request = urllib.request.Request(
            url, headers={"User-Agent": "Lungfish release yank", "Cache-Control": "no-cache"}
        )
        try:
            with self.urlopen(request, timeout=30) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise YankError(f"could not fetch {url}: HTTP {error.code}") from error
        except OSError as error:
            raise YankError(f"could not fetch {url}: {error}") from error

    def release_info(self, tag: str) -> dict | None:
        result = self.command_runner.run(
            ["gh", "release", "view", tag, "--json", "tagName,name,body,isPrerelease,assets"],
            capture=True,
            check=False,
        )
        if result.returncode != 0:
            return None
        return json.loads(result.stdout)

    def latest_full_release_tag(self) -> str | None:
        result = self.command_runner.run(
            ["gh", "release", "view", "--json", "tagName"], capture=True, check=False
        )
        if result.returncode != 0:
            return None
        return json.loads(result.stdout).get("tagName") or None

    def upload_appcast(self, release: str, filename: str, content: bytes) -> None:
        with tempfile.TemporaryDirectory(prefix="lungfish-yank-") as directory:
            path = Path(directory) / filename
            path.write_bytes(content)
            self.command_runner.run(["gh", "release", "upload", release, str(path), "--clobber"])

    def mark_release_yanked(self, tag: str, title: str, body: str) -> None:
        with tempfile.TemporaryDirectory(prefix="lungfish-yank-") as directory:
            notes = Path(directory) / "notes.md"
            notes.write_text(body, encoding="utf-8")
            self.command_runner.run(
                [
                    "gh", "release", "edit", tag,
                    "--prerelease",
                    "--title", title,
                    "--notes-file", str(notes),
                ]
            )


# --------------------------------------------------------------------------
# Planning (pure)
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class FeedTarget:
    release: str
    filename: str
    primary: bool


@dataclass(frozen=True)
class FeedChange:
    target: FeedTarget
    before: bytes | None
    after: bytes | None  # None: leave this feed alone
    note: str


@dataclass(frozen=True)
class ReleaseChange:
    tag: str
    already_yanked: bool
    title: str
    body: str


@dataclass(frozen=True)
class YankPlan:
    channel: str
    version: str
    yanked_build: int
    feeds: list[FeedChange]
    release: ReleaseChange
    restored_item: AppcastItem | None
    warnings: list[str] = field(default_factory=list)

    def render(self) -> str:
        lines = [f"Yank plan for {self.channel} v{self.version} (sparkle:version {self.yanked_build}):"]
        for change in self.feeds:
            location = f"{change.target.release}/{change.target.filename}"
            lines.append(f"  Feed {location}: {change.note}")
        if self.restored_item is not None:
            lines.append(
                f"  Restores last good item: v{self.restored_item.short_version} "
                f"(sparkle:version {self.restored_item.sparkle_version})"
            )
        if self.release.already_yanked:
            lines.append(f"  GitHub release {self.release.tag}: already marked yanked, no change")
        else:
            lines.append(
                f"  GitHub release {self.release.tag}: mark prerelease, title {self.release.title!r}, "
                "prepend yank note, keep tag and assets"
            )
        lines.extend(f"  Warning: {warning}" for warning in self.warnings)
        lines.append("")
        lines.append(follow_up_text(self.channel, self.version, self.yanked_build))
        return "\n".join(lines)


def follow_up_text(channel: str, version: str, yanked_build: int) -> str:
    return (
        "Follow-up: Sparkle cannot downgrade, so clients that already installed "
        f"v{version} stay on it. Ship a corrected build through the normal "
        f"'release.py package {channel}' and 'release.py publish {channel}' path. "
        f"Its CFBundleVersion must exceed {yanked_build}, which the build-number floor enforces."
    )


def _find_item_element(channel: ET.Element, version: str) -> ET.Element | None:
    for element in channel.findall("item"):
        short = element.find(SPARKLE_SHORT_VERSION_TAG)
        if short is not None and (short.text or "").strip() == version:
            return element
    return None


def _serialize(root: ET.Element) -> bytes:
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"


def _asset_name(url: str | None) -> str | None:
    if not url:
        return None
    return urllib.parse.unquote(urllib.parse.urlparse(url).path.rsplit("/", 1)[-1]) or None


def verify_restore_item(item: AppcastItem, release_info: dict | None) -> None:
    """The restore item's DMG must still be attached to its release, same size."""
    tag = f"v{item.short_version}"
    if release_info is None:
        raise YankError(f"restore target release {tag} does not exist on GitHub")
    if (release_info.get("name") or "").startswith(YANKED_TITLE_PREFIX.strip()):
        raise YankError(f"restore target {tag} is itself yanked")
    asset_name = _asset_name(item.enclosure_url)
    if asset_name is None:
        raise YankError("restore appcast item has no enclosure URL")
    assets = {asset.get("name"): asset for asset in release_info.get("assets", [])}
    asset = assets.get(asset_name)
    if asset is None:
        raise YankError(f"restore target {tag} no longer has asset {asset_name!r}")
    if item.enclosure_length is None or asset.get("size") != item.enclosure_length:
        raise YankError(
            f"restore target {tag} asset {asset_name!r} size {asset.get('size')} does not match "
            f"the appcast enclosure length {item.enclosure_length}"
        )


def _yank_note(channel: str, version: str, reason: str, today: str) -> str:
    return (
        f"> **Yanked on {today}.** v{version} was withdrawn from the {channel} update feed. "
        f"Reason: {reason}\n"
        ">\n"
        "> Sparkle no longer offers this build. The assets stay attached so existing downloads "
        "remain verifiable. Install the newest release instead.\n"
    )


def plan_yank(
    *,
    channel: str,
    version: str,
    targets: list[FeedTarget],
    live_feeds: dict[FeedTarget, bytes | None],
    release_info: dict | None,
    latest_full_release_tag: str | None,
    restore_appcast_xml: bytes | str | None = None,
    restore_release_info: dict | None = None,
    reason: str = "withdrawn by the release owner",
    force: bool = False,
    today: str | None = None,
) -> YankPlan:
    """Computes the yank from already-fetched state. Pure and deterministic."""
    today = today or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    tag = f"v{version}"
    if release_info is None:
        raise YankError(f"GitHub release {tag} does not exist")

    restored_item = None
    restore_element = None
    if restore_appcast_xml is not None:
        restore_channel = _channel(_parse_root(restore_appcast_xml))
        restore_elements = restore_channel.findall("item")
        if len(restore_elements) != 1:
            raise YankError(
                f"the restore appcast must contain exactly one <item>; found {len(restore_elements)}"
            )
        restore_element = restore_elements[0]
        restored_item = _item_from_element(restore_element)
        if not restored_item.short_version:
            raise YankError("restore appcast item has no sparkle:shortVersionString")
        verify_restore_item(restored_item, restore_release_info)

    warnings: list[str] = []
    feeds: list[FeedChange] = []
    yanked_build = None

    for target in targets:
        before = live_feeds.get(target)
        if before is None:
            if target.primary:
                raise YankError(f"live feed {target.release}/{target.filename} does not exist")
            feeds.append(FeedChange(target, None, None, "absent, nothing to change"))
            continue

        root = _parse_root(before)
        channel_element = _channel(root)
        element = _find_item_element(channel_element, version)
        already_marked = [build for build, marked in yank_markers(before) if marked == version]

        if element is None:
            if already_marked:
                yanked_build = yanked_build or already_marked[0]
                feeds.append(FeedChange(target, before, None, "already yanked, no change"))
                continue
            if target.primary:
                raise YankError(
                    f"v{version} is not offered by {target.release}/{target.filename}; "
                    "there is nothing for Sparkle to stop offering"
                )
            feeds.append(FeedChange(target, before, None, f"does not offer v{version}, no change"))
            continue

        item = _item_from_element(element)
        if yanked_build is not None and yanked_build != item.sparkle_version:
            raise YankError(
                f"feeds disagree on the build for v{version}: {yanked_build} and {item.sparkle_version}"
            )
        yanked_build = item.sparkle_version
        floor_before = appcast_build_floor(before)

        channel_element.remove(element)
        if restored_item is not None:
            if restored_item.sparkle_version >= item.sparkle_version:
                raise YankError(
                    f"restore item sparkle:version {restored_item.sparkle_version} is not older than "
                    f"the yanked build {item.sparkle_version}"
                )
            present = {entry.sparkle_version for entry in parse_appcast_items(ET.tostring(root))}
            if restored_item.sparkle_version not in present:
                channel_element.append(restore_element)

        remaining = channel_element.findall("item")
        if not remaining and not force:
            raise YankError(
                f"yanking v{version} would leave {target.release}/{target.filename} with no <item>. "
                "Pass --restore-appcast with the last good release's retained appcast, "
                "or --force to publish an empty feed"
            )
        if not remaining:
            warnings.append(f"{target.release}/{target.filename} will offer no update at all")

        marker = ET.SubElement(channel_element, YANK_MARKER_TAG)
        marker.set("build", str(item.sparkle_version))
        marker.set("version", version)
        marker.set("date", today)

        after = _serialize(root)
        floor_after = appcast_build_floor(after)
        if floor_before is not None and (floor_after is None or floor_after < floor_before):
            raise YankError(
                f"internal check failed: yank would lower the {target.filename} build floor "
                f"from {floor_before} to {floor_after}"
            )
        note = f"remove v{version} item (build {item.sparkle_version}), add yank marker"
        if restored_item is not None and restore_element in remaining:
            note += f", restore v{restored_item.short_version}"
        feeds.append(FeedChange(target, before, after, note))

    assert yanked_build is not None  # the primary feed either had the item or a marker

    if latest_full_release_tag == tag and not force:
        raise YankError(
            f"{tag} is the current Stable baseline (the latest full GitHub release). "
            "Yanking it changes the baseline for the next Stable notes. Pass --force if that is intended"
        )
    if latest_full_release_tag == tag:
        warnings.append(f"{tag} is the current Stable baseline; the previous full release becomes the baseline")

    title = release_info.get("name") or tag
    already_yanked = title.startswith(YANKED_TITLE_PREFIX) and bool(release_info.get("isPrerelease"))
    new_title = title if title.startswith(YANKED_TITLE_PREFIX) else YANKED_TITLE_PREFIX + title
    body = release_info.get("body") or ""
    if not already_yanked:
        body = _yank_note(channel, version, reason, today) + ("\n---\n\n" + body if body else "")

    return YankPlan(
        channel=channel,
        version=version,
        yanked_build=yanked_build,
        feeds=feeds,
        release=ReleaseChange(tag=tag, already_yanked=already_yanked, title=new_title, body=body),
        restored_item=restored_item,
        warnings=warnings,
    )


# --------------------------------------------------------------------------
# Execution
# --------------------------------------------------------------------------


def confirm_version(version: str, prompt: Callable[[str], str]) -> None:
    """Requires the operator to type the exact version before any mutation."""
    try:
        typed = prompt(f"Type the version to yank ({version}) to confirm: ")
    except EOFError as error:
        raise YankError("confirmation was not provided; nothing was changed") from error
    if typed.strip() != version:
        raise YankError(f"confirmation {typed.strip()!r} does not match {version!r}; nothing was changed")


def execute_yank(plan: YankPlan, runner: YankRunner, evidence_dir: Path) -> None:
    """Applies ``plan``: feeds first (that stops the exposure), then the release.

    Evidence (live and new feed bytes, the release body before the edit, the
    rendered plan) is written to ``evidence_dir`` before anything changes.
    """
    evidence_dir.mkdir(parents=True, exist_ok=True)
    (evidence_dir / "plan.txt").write_text(plan.render() + "\n", encoding="utf-8")
    for change in plan.feeds:
        stem = f"{change.target.release}-{change.target.filename}"
        if change.before is not None:
            (evidence_dir / f"{stem}.before.xml").write_bytes(change.before)
        if change.after is not None:
            (evidence_dir / f"{stem}.after.xml").write_bytes(change.after)

    for change in plan.feeds:
        if change.after is None:
            continue
        runner.upload_appcast(change.target.release, change.target.filename, change.after)
        live = runner.fetch_appcast(change.target.release, change.target.filename)
        if live is None or _find_item_element(_channel(_parse_root(live)), plan.version) is not None:
            raise YankError(
                f"uploaded {change.target.filename} but the live feed still offers v{plan.version} "
                "(possibly a download cache). Re-run the same yank command, it resumes safely"
            )

    if not plan.release.already_yanked:
        info = runner.release_info(plan.release.tag)
        (evidence_dir / "release.before.json").write_text(json.dumps(info, indent=2), encoding="utf-8")
        runner.mark_release_yanked(plan.release.tag, plan.release.title, plan.release.body)


def load_appcast_bytes(path: Path) -> bytes:
    if not path.is_file():
        raise YankError(f"appcast file not found: {path}")
    return path.read_bytes()
