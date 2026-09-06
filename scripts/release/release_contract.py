#!/usr/bin/env python3
"""Strict loader and command-line access for the Lungfish release contract."""

import argparse
from dataclasses import dataclass, field
import json
from pathlib import Path
import re
import unicodedata
from types import MappingProxyType
from typing import Any, Mapping, NoReturn

try:
    from release_identity import PublicIdentity, legacy_identity, validate_runtime_contract
except ModuleNotFoundError:
    from scripts.release.release_identity import PublicIdentity, legacy_identity, validate_runtime_contract


CONTRACT_PATH = Path(__file__).resolve().parents[2] / "config" / "release-contract.json"
CHANNEL_NAMES = frozenset({"preview", "stable"})
BUILD_PROFILE_NAMES = frozenset({"debug"})
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
BUILD_PROFILE_FIELDS = frozenset(
    {
        "appBundleFilename",
        "displayName",
        "bundleName",
        "bundleIdentifier",
        "releaseChannel",
        "isRelease",
        "publishable",
        "updaterEnabled",
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
GATE_FIELDS = frozenset({"focusedReleaseTests", "channels", "appSmokeTests", "appSmokeAccount"})
GATE_STEP_FIELDS = frozenset({"tier", "requireTools"})


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
class BuildProfileContract:
    appBundleFilename: str
    displayName: str
    bundleName: str
    bundleIdentifier: str
    releaseChannel: str
    isRelease: bool
    publishable: bool
    updaterEnabled: bool

    def to_dict(self) -> dict[str, Any]:
        return {field: getattr(self, field) for field in BUILD_PROFILE_FIELDS}


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
class GateStep:
    tier: str
    requireTools: bool

    def to_dict(self) -> dict[str, Any]:
        return {"tier": self.tier, "requireTools": self.requireTools}


@dataclass(frozen=True)
class GateContract:
    focusedReleaseTests: tuple[str, ...]
    channels: Mapping[str, tuple[GateStep, ...]]
    appSmokeTests: tuple[str, ...]
    appSmokeAccount: str
    dependencyPolicy: str = "installed"
    appSmokeRequired: bool = True

    def for_channel(self, name: str) -> tuple[GateStep, ...]:
        try:
            return self.channels[name]
        except KeyError as error:
            raise ValueError(f"unknown release gate channel: {name}") from error

    def to_dict(self) -> dict[str, Any]:
        return {
            "focusedReleaseTests": list(self.focusedReleaseTests),
            "appSmokeTests": list(self.appSmokeTests),
            "appSmokeAccount": self.appSmokeAccount,
            "dependencyPolicy": self.dependencyPolicy,
            "appSmokeRequired": self.appSmokeRequired,
            "channels": {
                name: [step.to_dict() for step in steps]
                for name, steps in self.channels.items()
            },
        }


@dataclass(frozen=True)
class ReleaseContract:
    schemaVersion: int
    channels: Mapping[str, ChannelContract]
    buildProfiles: Mapping[str, BuildProfileContract]
    toolchain: ToolchainContract
    gates: GateContract
    identity: PublicIdentity = field(default_factory=legacy_identity)
    sourceRoot: Path | None = None

    def channel(self, name: str) -> ChannelContract:
        try:
            return self.channels[name]
        except KeyError as error:
            raise ValueError(f"unknown release channel: {name}") from error

    def profile(self, name: str) -> BuildProfileContract:
        try:
            return self.buildProfiles[name]
        except KeyError as error:
            raise ValueError(f"unknown build profile: {name}") from error

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": self.schemaVersion,
            "identity": self.identity.to_dict(),
            "channels": {
                name: channel.to_dict() for name, channel in self.channels.items()
            },
            "buildProfiles": {
                name: profile.to_dict() for name, profile in self.buildProfiles.items()
            },
            "toolchain": self.toolchain.to_dict(),
            "gates": self.gates.to_dict(),
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


def _require_leaf_filename(value: str, suffix: str, location: str) -> None:
    if (not value or value != value.strip() or len(value.encode()) > 255
            or any(character in "/\\:" or unicodedata.category(character) in {"Cc", "Cf"} for character in value)
            or value in {".", ".."} or not value.endswith(suffix) or len(value) <= len(suffix)):
        raise ValueError(f"{location} must be a safe leaf filename ending in {suffix}")


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
        raise ValueError(f"channel {name}.releaseChannel must equal its channel name")
    if bool(value["legacyBridgeRelease"]) != bool(value["legacyBridgeAppcastFilename"]):
        raise ValueError(
            f"channel {name} legacy bridge release and filename must both be set or empty"
        )
    _require_leaf_filename(value["appBundleFilename"], ".app", f"channel {name}.appBundleFilename")
    _require_leaf_filename(value["appcastFilename"], ".xml", f"channel {name}.appcastFilename")
    if value["legacyBridgeAppcastFilename"]:
        _require_leaf_filename(value["legacyBridgeAppcastFilename"], ".xml", f"channel {name}.legacyBridgeAppcastFilename")
    return ChannelContract(**value)


def _parse_build_profile(name: str, raw: Any) -> BuildProfileContract:
    value = _require_object(raw, f"build profile {name}")
    _require_fields(value, BUILD_PROFILE_FIELDS, f"build profile {name}")
    for field in BUILD_PROFILE_FIELDS - {"isRelease", "publishable", "updaterEnabled"}:
        _require_type(value[field], str, f"build profile {name}.{field}")
        if not value[field]:
            raise ValueError(f"build profile {name}.{field} must not be empty")
        if "\n" in value[field] or "\r" in value[field]:
            raise ValueError(f"build profile {name}.{field} must be one line")
    for field in ("isRelease", "publishable", "updaterEnabled"):
        _require_type(value[field], bool, f"build profile {name}.{field}")
        if value[field]:
            raise ValueError(f"build profile {name}.{field} must be false")
    if value["releaseChannel"] != name:
        raise ValueError(
            f"build profile {name}.releaseChannel must equal its profile name"
        )
    _require_leaf_filename(value["appBundleFilename"], ".app", f"build profile {name}.appBundleFilename")
    return BuildProfileContract(**value)


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


def _parse_gates(raw: Any) -> GateContract:
    value = _require_object(raw, "gates")
    _require_fields(value, GATE_FIELDS | (set(value) & {"dependencyPolicy", "appSmokeRequired"}), "gates")
    modules = value["focusedReleaseTests"]
    if not isinstance(modules, list) or not modules:
        raise ValueError("gates.focusedReleaseTests must be a nonempty array")
    focused: list[str] = []
    for index, module in enumerate(modules):
        _require_type(module, str, f"gates.focusedReleaseTests[{index}]")
        if re.fullmatch(r"scripts\.tests\.test_[a-z0-9_]+", module) is None:
            raise ValueError("focused release test module is unsafe")
        focused.append(module)
    if len(focused) != len(set(focused)):
        raise ValueError("duplicate focused release test module")

    raw_channels = _require_object(value["channels"], "gates.channels")
    if set(raw_channels) != CHANNEL_NAMES:
        raise ValueError("invalid release gate channels")
    channels: dict[str, tuple[GateStep, ...]] = {}
    for name in sorted(CHANNEL_NAMES):
        raw_steps = raw_channels[name]
        if not isinstance(raw_steps, list) or not raw_steps:
            raise ValueError(f"release gate channel {name} must be nonempty")
        steps: list[GateStep] = []
        for index, raw_step in enumerate(raw_steps):
            step = _require_object(raw_step, f"gate {name}[{index}]")
            _require_fields(step, GATE_STEP_FIELDS, f"gate {name}[{index}]")
            _require_type(step["tier"], str, f"gate {name}[{index}].tier")
            _require_type(
                step["requireTools"], bool, f"gate {name}[{index}].requireTools"
            )
            if step["tier"] not in {"unit", "integration", "full", "conformance", "release", "quick", "headless", "tool-conformance"}:
                raise ValueError(f"unknown release gate tier: {step['tier']}")
            if step["tier"] == "conformance" and not step["requireTools"]:
                raise ValueError("conformance release gate must set requireTools")
            steps.append(GateStep(**step))
        tiers = [step.tier for step in steps]
        if len(tiers) != len(set(tiers)):
            raise ValueError(f"duplicate release gate tier for {name}")
        channels[name] = tuple(steps)
    app_smoke = value["appSmokeTests"]
    if not isinstance(app_smoke, list) or not app_smoke or any(
        not isinstance(test, str) or re.fullmatch(r"LungfishXCUITests/[A-Za-z0-9_]+/test[A-Za-z0-9_]+", test) is None
        for test in app_smoke
    ) or len(set(app_smoke)) != len(app_smoke):
        raise ValueError("app smoke must select unique explicit XCTest methods")
    account = value["appSmokeAccount"]
    if not isinstance(account, str) or re.fullmatch(r"[a-z][a-z0-9-]{0,30}", account) is None:
        raise ValueError("app smoke requires an explicit disposable account name")
    dependency_policy = value.get("dependencyPolicy", "installed")
    if dependency_policy not in {"installed", "manifest"}:
        raise ValueError("unknown dependency policy")
    app_smoke_required = value.get("appSmokeRequired", True)
    _require_type(app_smoke_required, bool, "gates.appSmokeRequired")
    return GateContract(tuple(focused), MappingProxyType(channels), tuple(app_smoke), account, dependency_policy, app_smoke_required)


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
        root,
        frozenset({"schemaVersion", "channels", "buildProfiles", "toolchain", "gates"}) | ({"identity"} if "identity" in root else set()),
        "top-level",
    )
    _require_type(root["schemaVersion"], int, "schemaVersion")
    if root["schemaVersion"] != 1:
        raise ValueError(f"unsupported schemaVersion: {root['schemaVersion']}")

    raw_channels = _require_object(root["channels"], "channels")
    actual_channels = set(raw_channels)
    if actual_channels != CHANNEL_NAMES:
        missing = sorted(CHANNEL_NAMES - actual_channels)
        extra = sorted(actual_channels - CHANNEL_NAMES)
        raise ValueError(f"invalid channels: missing {missing}, extra {extra}")
    channels = {
        name: _parse_channel(name, raw_channels[name]) for name in sorted(CHANNEL_NAMES)
    }
    raw_profiles = _require_object(root["buildProfiles"], "buildProfiles")
    actual_profiles = set(raw_profiles)
    if actual_profiles != BUILD_PROFILE_NAMES:
        missing = sorted(BUILD_PROFILE_NAMES - actual_profiles)
        extra = sorted(actual_profiles - BUILD_PROFILE_NAMES)
        raise ValueError(f"invalid build profiles: missing {missing}, extra {extra}")
    profiles = {
        name: _parse_build_profile(name, raw_profiles[name])
        for name in sorted(BUILD_PROFILE_NAMES)
    }
    _reject_duplicates(channels)
    channel_wrappers = {channel.appBundleFilename for channel in channels.values()}
    profile_wrappers = {profile.appBundleFilename for profile in profiles.values()}
    if channel_wrappers & profile_wrappers:
        raise ValueError("duplicate build profile appBundleFilename")
    identity = PublicIdentity.parse(root["identity"]) if "identity" in root else legacy_identity()
    validate_runtime_contract(identity, channels, profiles)
    return ReleaseContract(
        schemaVersion=root["schemaVersion"],
        channels=MappingProxyType(channels),
        buildProfiles=MappingProxyType(profiles),
        toolchain=_parse_toolchain(root["toolchain"]),
        gates=_parse_gates(root["gates"]),
        identity=identity,
        sourceRoot=path.resolve().parent.parent,
    )


def channel(name: str) -> ChannelContract:
    """Load and return a channel from the repository release contract."""
    return load_contract(CONTRACT_PATH).channel(name)


def profile(name: str) -> BuildProfileContract:
    """Load and return a non-release build profile from the repository contract."""
    return load_contract(CONTRACT_PATH).profile(name)


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
        ("PREVIEW_LEGACY_SPARKLE_RELEASE", preview.legacyBridgeRelease),
        ("PREVIEW_LEGACY_APPCAST_FILENAME", preview.legacyBridgeAppcastFilename),
        ("DEPLOYMENT_TARGET", contract.toolchain.deploymentTarget),
    ]


def _profile_shell_values(
    contract: ReleaseContract, name: str
) -> list[tuple[str, Any]]:
    selected = contract.profile(name)
    return [
        ("APP_BUNDLE_FILENAME", selected.appBundleFilename),
        ("APP_DISPLAY_NAME", selected.displayName),
        ("APP_SHORT_NAME", selected.bundleName),
        ("APP_BUNDLE_IDENTIFIER", selected.bundleIdentifier),
        ("RELEASE_CHANNEL", selected.releaseChannel),
        ("IS_RELEASE", selected.isRelease),
        ("PUBLISHABLE", selected.publishable),
        ("UPDATER_ENABLED", selected.updaterEnabled),
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
    describe_profile_parser = subparsers.add_parser("describe-profile")
    describe_profile_parser.add_argument("--profile", required=True)
    shell_profile_parser = subparsers.add_parser("shell-profile")
    shell_profile_parser.add_argument("--profile", required=True)
    return parser


def _fail(message: str) -> NoReturn:
    raise SystemExit(message)


def main() -> int:
    args = _parser().parse_args()
    try:
        contract = load_contract(args.contract)
        if args.command in {"describe-profile", "shell-profile"}:
            selected = contract.profile(args.profile)
        else:
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
    elif args.command == "describe-profile":
        print(json.dumps(selected.to_dict(), sort_keys=True, separators=(",", ":")))
    elif args.command == "shell-profile":
        for key, value in _profile_shell_values(contract, args.profile):
            rendered = _render_scalar(value)
            if "\n" in rendered or "\r" in rendered:
                _fail(f"contract field for {key} is not shell-safe")
            print(f"{key}={rendered}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
