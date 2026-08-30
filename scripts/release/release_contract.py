#!/usr/bin/env python3
"""Strict loader and command-line access for the Lungfish release contract."""

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
from types import MappingProxyType
from typing import Any, Mapping, NoReturn


CONTRACT_PATH = Path(__file__).resolve().parents[2] / "config" / "release-contract.json"
CHANNEL_NAMES = frozenset({"preview", "stable"})
CHANNEL_FIELDS = frozenset(
    {
        "appBundleFilename",
        "displayName",
        "bundleName",
        "bundleIdentifier",
        "releaseChannel",
        "sparkleRelease",
        "appcastFilename",
        "githubPrerelease",
        "dmgVolumeName",
        "legacyBridgeRelease",
        "legacyBridgeAppcastFilename",
    }
)
TOOLCHAIN_FIELDS = frozenset(
    {
        "xcodeMinimum",
        "xcodeMaximumExclusive",
        "swiftMinimum",
        "swiftMaximumExclusive",
        "sdkMajor",
        "deploymentTarget",
        "architecture",
        "minimumFreeDiskGiB",
    }
)


@dataclass(frozen=True)
class ChannelContract:
    appBundleFilename: str
    displayName: str
    bundleName: str
    bundleIdentifier: str
    releaseChannel: str
    sparkleRelease: str
    appcastFilename: str
    githubPrerelease: bool
    dmgVolumeName: str
    legacyBridgeRelease: str
    legacyBridgeAppcastFilename: str

    def to_dict(self) -> dict[str, Any]:
        return {field: getattr(self, field) for field in CHANNEL_FIELDS}


@dataclass(frozen=True)
class ToolchainContract:
    xcodeMinimum: str
    xcodeMaximumExclusive: str
    swiftMinimum: str
    swiftMaximumExclusive: str
    sdkMajor: int
    deploymentTarget: str
    architecture: str
    minimumFreeDiskGiB: int

    def to_dict(self) -> dict[str, Any]:
        return {field: getattr(self, field) for field in TOOLCHAIN_FIELDS}


@dataclass(frozen=True)
class ReleaseContract:
    schemaVersion: int
    channels: Mapping[str, ChannelContract]
    toolchain: ToolchainContract

    def channel(self, name: str) -> ChannelContract:
        try:
            return self.channels[name]
        except KeyError as error:
            raise ValueError(f"unknown release channel: {name}") from error

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": self.schemaVersion,
            "channels": {
                name: channel.to_dict() for name, channel in self.channels.items()
            },
            "toolchain": self.toolchain.to_dict(),
        }


def _require_object(value: Any, location: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{location} must be a JSON object")
    return value


def _require_fields(
    value: Mapping[str, Any], expected: frozenset[str], location: str
) -> None:
    actual = set(value)
    if actual == expected:
        return
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    details = []
    if missing:
        details.append(f"missing {missing}")
    if extra:
        details.append(f"extra {extra}")
    raise ValueError(f"invalid {location} fields: {', '.join(details)}")


def _require_type(value: Any, expected_type: type, location: str) -> None:
    if type(value) is not expected_type:
        raise ValueError(f"{location} must be {expected_type.__name__}")


def _parse_channel(name: str, raw: Any) -> ChannelContract:
    value = _require_object(raw, f"channel {name}")
    _require_fields(value, CHANNEL_FIELDS, f"channel {name}")
    for field in CHANNEL_FIELDS - {"githubPrerelease"}:
        _require_type(value[field], str, f"channel {name}.{field}")
    _require_type(value["githubPrerelease"], bool, f"channel {name}.githubPrerelease")
    for field in CHANNEL_FIELDS - {
        "githubPrerelease",
        "legacyBridgeRelease",
        "legacyBridgeAppcastFilename",
    }:
        if not value[field]:
            raise ValueError(f"channel {name}.{field} must not be empty")
        if "\n" in value[field] or "\r" in value[field]:
            raise ValueError(f"channel {name}.{field} must be one line")
    if value["releaseChannel"] != name:
        raise ValueError(
            f"channel {name}.releaseChannel must equal its channel name"
        )
    if bool(value["legacyBridgeRelease"]) != bool(
        value["legacyBridgeAppcastFilename"]
    ):
        raise ValueError(
            f"channel {name} legacy bridge release and filename must both be set or empty"
        )
    return ChannelContract(**value)


def _parse_toolchain(raw: Any) -> ToolchainContract:
    value = _require_object(raw, "toolchain")
    _require_fields(value, TOOLCHAIN_FIELDS, "toolchain")
    for field in TOOLCHAIN_FIELDS - {"sdkMajor", "minimumFreeDiskGiB"}:
        _require_type(value[field], str, f"toolchain.{field}")
        if not value[field]:
            raise ValueError(f"toolchain.{field} must not be empty")
    for field in ("sdkMajor", "minimumFreeDiskGiB"):
        _require_type(value[field], int, f"toolchain.{field}")
        if value[field] <= 0:
            raise ValueError(f"toolchain.{field} must be positive")
    return ToolchainContract(**value)


def _reject_duplicates(channels: Mapping[str, ChannelContract]) -> None:
    for field in ("appBundleFilename", "sparkleRelease"):
        values = [getattr(channel, field) for channel in channels.values()]
        if len(values) != len(set(values)):
            raise ValueError(f"duplicate channel {field}")

    appcast_filenames = []
    feed_paths = []
    for channel in channels.values():
        appcast_filenames.append(channel.appcastFilename)
        feed_paths.append((channel.sparkleRelease, channel.appcastFilename))
        if channel.legacyBridgeRelease:
            appcast_filenames.append(channel.legacyBridgeAppcastFilename)
            feed_paths.append(
                (
                    channel.legacyBridgeRelease,
                    channel.legacyBridgeAppcastFilename,
                )
            )
    if len(appcast_filenames) != len(set(appcast_filenames)):
        raise ValueError("duplicate channel appcast filename")
    if len(feed_paths) != len(set(feed_paths)):
        raise ValueError("duplicate channel feed")


def load_contract(path: Path) -> ReleaseContract:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot load release contract {path}: {error}") from error
    root = _require_object(raw, "release contract")
    _require_fields(
        root, frozenset({"schemaVersion", "channels", "toolchain"}), "top-level"
    )
    _require_type(root["schemaVersion"], int, "schemaVersion")
    if root["schemaVersion"] != 1:
        raise ValueError(f"unsupported schemaVersion: {root['schemaVersion']}")

    raw_channels = _require_object(root["channels"], "channels")
    actual_channels = set(raw_channels)
    if actual_channels != CHANNEL_NAMES:
        missing = sorted(CHANNEL_NAMES - actual_channels)
        extra = sorted(actual_channels - CHANNEL_NAMES)
        raise ValueError(
            f"invalid channels: missing {missing}, extra {extra}"
        )
    channels = {
        name: _parse_channel(name, raw_channels[name]) for name in sorted(CHANNEL_NAMES)
    }
    _reject_duplicates(channels)
    return ReleaseContract(
        schemaVersion=root["schemaVersion"],
        channels=MappingProxyType(channels),
        toolchain=_parse_toolchain(root["toolchain"]),
    )


def channel(name: str) -> ChannelContract:
    """Load and return a channel from the repository release contract."""
    return load_contract(CONTRACT_PATH).channel(name)


def _render_scalar(value: Any) -> str:
    if isinstance(value, bool):
        return json.dumps(value)
    return str(value)


def _shell_values(contract: ReleaseContract, name: str) -> list[tuple[str, Any]]:
    selected = contract.channel(name)
    preview = contract.channel("preview")
    return [
        ("APP_BUNDLE_FILENAME", selected.appBundleFilename),
        ("APP_DISPLAY_NAME", selected.displayName),
        ("APP_SHORT_NAME", selected.bundleName),
        ("APP_BUNDLE_IDENTIFIER", selected.bundleIdentifier),
        ("RELEASE_CHANNEL", selected.releaseChannel),
        ("SPARKLE_PUBLISH_RELEASE", selected.sparkleRelease),
        ("SPARKLE_APPCAST_FILENAME", selected.appcastFilename),
        ("GITHUB_PRERELEASE", selected.githubPrerelease),
        ("DMG_VOLUME_NAME", selected.dmgVolumeName),
        ("SPARKLE_BRIDGE_PUBLISH_RELEASE", selected.legacyBridgeRelease),
        ("SPARKLE_BRIDGE_APPCAST_FILENAME", selected.legacyBridgeAppcastFilename),
        ("PREVIEW_SPARKLE_RELEASE", preview.sparkleRelease),
        ("PREVIEW_APPCAST_FILENAME", preview.appcastFilename),
    ]


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, default=CONTRACT_PATH)
    subparsers = parser.add_subparsers(dest="command", required=True)
    get_parser = subparsers.add_parser("get")
    get_parser.add_argument("--channel", required=True)
    get_parser.add_argument("--field", required=True, choices=sorted(CHANNEL_FIELDS))
    describe_parser = subparsers.add_parser("describe")
    describe_parser.add_argument("--channel", required=True)
    shell_parser = subparsers.add_parser("shell")
    shell_parser.add_argument("--channel", required=True)
    return parser


def _fail(message: str) -> NoReturn:
    raise SystemExit(message)


def main() -> int:
    args = _parser().parse_args()
    try:
        contract = load_contract(args.contract)
        selected = contract.channel(args.channel)
    except ValueError as error:
        _fail(str(error))

    if args.command == "get":
        print(_render_scalar(getattr(selected, args.field)))
    elif args.command == "describe":
        print(json.dumps(selected.to_dict(), sort_keys=True, separators=(",", ":")))
    elif args.command == "shell":
        for key, value in _shell_values(contract, args.channel):
            rendered = _render_scalar(value)
            if "\n" in rendered or "\r" in rendered:
                _fail(f"contract field for {key} is not shell-safe")
            print(f"{key}={rendered}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
