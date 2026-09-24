"""Withdraw a bad Sparkle release from the live feed (REL-04).

Each publish overwrites the mutable per-channel appcast asset
(``sparkle-beta``/``appcast-beta.xml`` or ``sparkle-stable``/``appcast-stable.xml``)
with a fresh, single-item appcast for the commit just published
(``build-notarized-dmg.sh`` ~1016-1060). There is no supported way to pull a
bad release back: the build-number floor gate (``check-sparkle-build-number.py``)
refuses to republish anything at or below the live build, so simply
re-running ``package``/``publish`` for the previous commit is rejected by the
gate that exists specifically to prevent history rewrites.

This module is a PLAN PRINTER, not an executor. ``plan_yank`` computes what a
yank would do -- which appcast it would fetch, which retained prior item it
would restore, and which GitHub calls it would make -- and returns a
``YankPlan`` that can be printed or compared in a test. Nothing in this
module calls ``gh``, writes to a remote asset, or otherwise mutates release
state. The `release.py yank` subcommand is dry-run by default; the
`--execute` flag exists in the CLI surface for a future round once a human
has reviewed the plan output on a real appcast, and currently refuses with a
clear message rather than performing the withdrawal, per this round's
instruction not to execute any release/publish action.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import xml.etree.ElementTree as ET


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE_VERSION_TAG = f"{{{SPARKLE_NS}}}version"
SPARKLE_SHORT_VERSION_TAG = f"{{{SPARKLE_NS}}}shortVersionString"


class YankError(RuntimeError):
    """Raised when a yank plan cannot be computed from the given inputs."""


@dataclass(frozen=True)
class AppcastItem:
    """One <item> from a Sparkle appcast, with just the fields a yank needs."""

    title: str
    sparkle_version: int
    short_version: str | None
    raw_xml: str  # the exact serialized <item>...</item>, byte-preserving where possible


@dataclass(frozen=True)
class YankPlan:
    """Everything a yank of one channel would do, computed but not executed."""

    channel: str
    sparkle_release: str
    appcast_filename: str
    bad_item: AppcastItem
    restored_item: AppcastItem
    steps: list[str] = field(default_factory=list)

    def render(self) -> str:
        lines = [
            f"Yank plan for channel={self.channel!r} (mutable release {self.sparkle_release!r}, "
            f"feed {self.appcast_filename!r}):",
            f"  Currently published (to withdraw): sparkle:version={self.bad_item.sparkle_version} "
            f"({self.bad_item.short_version or 'unknown short version'})",
            f"  Will restore: sparkle:version={self.restored_item.sparkle_version} "
            f"({self.restored_item.short_version or 'unknown short version'})",
            "  Steps:",
        ]
        lines.extend(f"    {index + 1}. {step}" for index, step in enumerate(self.steps))
        return "\n".join(lines)


def parse_appcast_items(appcast_xml: bytes | str) -> list[AppcastItem]:
    """Parses every <item> in a Sparkle appcast into AppcastItem records."""
    root = ET.fromstring(appcast_xml)
    items = []
    for item_element in root.iter("item"):
        version_element = item_element.find(SPARKLE_VERSION_TAG)
        if version_element is None or not (version_element.text or "").strip().isdigit():
            raise YankError("appcast <item> is missing a numeric sparkle:version")
        short_version_element = item_element.find(SPARKLE_SHORT_VERSION_TAG)
        title_element = item_element.find("title")
        items.append(
            AppcastItem(
                title=(title_element.text or "").strip() if title_element is not None else "",
                sparkle_version=int(version_element.text.strip()),
                short_version=(short_version_element.text or "").strip() if short_version_element is not None else None,
                raw_xml=ET.tostring(item_element, encoding="unicode"),
            )
        )
    if not items:
        raise YankError("appcast contains no <item> elements")
    return items


def plan_yank(
    *,
    channel: str,
    sparkle_release: str,
    appcast_filename: str,
    live_appcast_xml: bytes | str,
    restore_appcast_xml: bytes | str,
) -> YankPlan:
    """Computes a YankPlan from the live (bad) appcast and a retained prior one.

    ``restore_appcast_xml`` is the appcast that was live before the bad
    release -- for example a copy retained under
    ``build/Release/<channel>/<commit>/`` from that release's own publish, or
    one regenerated offline from that release's DMG and EdDSA signature with
    the same ``generate_appcast`` tool used at publish time. This function
    does not fetch or regenerate it; the caller supplies both appcasts so the
    computation is pure and independently testable.
    """
    live_items = parse_appcast_items(live_appcast_xml)
    restore_items = parse_appcast_items(restore_appcast_xml)

    if len(live_items) != 1:
        raise YankError(
            f"expected exactly one <item> in the live {channel} appcast (each publish "
            f"overwrites the mutable feed with a fresh single-item appcast); found {len(live_items)}"
        )
    if len(restore_items) != 1:
        raise YankError(
            f"expected exactly one <item> in the appcast to restore for {channel}; "
            f"found {len(restore_items)}"
        )

    bad_item = live_items[0]
    restored_item = restore_items[0]

    if restored_item.sparkle_version >= bad_item.sparkle_version:
        raise YankError(
            "the appcast to restore is not older than the live one "
            f"(restore sparkle:version={restored_item.sparkle_version} >= "
            f"live sparkle:version={bad_item.sparkle_version}); refusing to yank forward"
        )

    steps = [
        f"Download the currently published appcast for {sparkle_release!r} and keep it as evidence "
        f"(sparkle:version={bad_item.sparkle_version}).",
        f"Confirm the restore target's DMG asset still exists on its GitHub release tag "
        f"(digest-verify before upload).",
        f"Upload the restore appcast to the mutable release {sparkle_release!r} asset "
        f"{appcast_filename!r} (and its legacy bridge copy, if this channel has one).",
        f"Mark the withdrawn GitHub release (sparkle:version={bad_item.sparkle_version}) with a "
        f"'Withdrawn' title prefix; keep its tag.",
        f"Record docs/release-notes/<withdrawn-version>.withdrawn.md noting the withdrawal reason "
        f"and the forward-fix version.",
        f"Run the Sparkle build-number floor gate in --yank mode, which must accept equality with "
        f"the restored build ({restored_item.sparkle_version}) rather than requiring strictly greater.",
    ]

    return YankPlan(
        channel=channel,
        sparkle_release=sparkle_release,
        appcast_filename=appcast_filename,
        bad_item=bad_item,
        restored_item=restored_item,
        steps=steps,
    )


def execute_yank(plan: YankPlan) -> None:
    """Performs the withdrawal described by ``plan``.

    Deliberately unimplemented in this round: the implementer brief for this
    package prohibits running any release, publish, or GitHub-mutating
    command. ``release.py yank`` only ever calls ``plan_yank`` and prints the
    result; ``--execute`` is accepted as a CLI flag for forward-compatibility
    but raises immediately so it can never be reached by accident. A future
    round should replace this body with the steps in ``plan.steps``, run by
    a human with release credentials.
    """
    raise NotImplementedError(
        "sparkle_yank.execute_yank is intentionally not implemented in this round. "
        "Run 'release.py yank' without --execute to see the plan, then perform the "
        "withdrawal by hand following docs/release/sparkle-updates.md's yank runbook."
    )


def load_appcast_bytes(path: Path) -> bytes:
    if not path.is_file():
        raise YankError(f"appcast file not found: {path}")
    return path.read_bytes()
