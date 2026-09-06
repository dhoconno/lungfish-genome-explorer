"""Public, committed product identity; never contains machine credentials."""

from dataclasses import asdict, dataclass
import base64
import copy
import re
import hashlib
import os
from pathlib import Path
import plistlib
import tempfile
import unicodedata
from urllib.parse import urlsplit


UPSTREAM_REPOSITORY = "dhoconno/lungfish-genome-explorer"
UPSTREAM_PUBLIC_KEY = "FtnZIDTqGTwkglQR0z8iSgVvxvT26a05QB3cI4xQw/c="


@dataclass(frozen=True)
class PublicIdentity:
    repository: str
    sparklePublicEdKey: str
    runtimeNamespace: str | None
    websiteURL: str
    documentationURL: str
    releaseHistoryURL: str

    @classmethod
    def parse(cls, value):
        if not isinstance(value, dict) or set(value) != set(cls.__dataclass_fields__):
            raise ValueError("public release identity has missing or unknown fields")
        for key, item in value.items():
            if key == "runtimeNamespace" and item is None:
                continue
            if not isinstance(item, str) or not item or any(unicodedata.category(c) in {"Cc", "Cf"} for c in item):
                raise ValueError(f"invalid public identity {key}")
        repository = value["repository"].lower()
        if re.fullmatch(r"[a-z0-9-]+/[a-z0-9._-]+", repository) is None:
            raise ValueError("public identity repository must be OWNER/REPOSITORY")
        try:
            key = base64.b64decode(value["sparklePublicEdKey"], validate=True)
        except (ValueError, TypeError) as error:
            raise ValueError("Sparkle public key must be base64 Ed25519") from error
        if len(key) != 32 or base64.b64encode(key).decode() != value["sparklePublicEdKey"]:
            raise ValueError("Sparkle public key must encode exactly 32 bytes")
        namespace = value["runtimeNamespace"]
        if namespace is None:
            if repository != UPSTREAM_REPOSITORY:
                raise ValueError("forks require an isolated runtime namespace")
        elif (re.fullmatch(r"[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*)+", namespace) is None
              or len((namespace + ".preview").encode()) > 180
              or any(namespace == item or namespace.startswith(item + ".") for item in ("com.lungfish", "org.lungfish"))):
            raise ValueError("fork runtime namespace must be a unique reverse-DNS identifier")
        for field in ("websiteURL", "documentationURL", "releaseHistoryURL"):
            url = urlsplit(value[field])
            if (len(value[field].encode()) > 2048 or url.scheme != "https" or not url.hostname
                    or url.username is not None or url.password is not None):
                raise ValueError(f"public identity {field} must be credential-free HTTPS")
        if value["releaseHistoryURL"] != f"https://github.com/{repository}/releases":
            raise ValueError("release history URL must match the configured repository")
        return cls(**{**value, "repository": repository})

    def to_dict(self):
        return asdict(self)


def valid_product_name(value):
    return (isinstance(value, str) and bool(value) and value == value.strip()
            and len(value.encode()) <= 200 and "$(" not in value and "${" not in value
            and not any(unicodedata.category(c) in {"Cc", "Cf"} for c in value))


def validate_runtime_contract(identity, channels, profiles):
    for name, selected in {**channels, **profiles}.items():
        if not valid_product_name(selected.displayName) or not valid_product_name(selected.bundleName):
            raise ValueError("product names must satisfy runtime identity constraints")
        if identity.runtimeNamespace is not None:
            expected = identity.runtimeNamespace + ("" if name == "stable" else "." + name)
            if selected.bundleIdentifier != expected:
                raise ValueError("fork bundle identifiers must derive from their runtime namespace and channel")
            if name in channels and selected.legacyBridgeRelease:
                raise ValueError("forks cannot publish upstream legacy migration feeds")
        else:
            suffix = "" if name == "stable" else " " + name.title()
            expected = ("Lungfish Genome Explorer" + suffix, "Lungfish" + suffix,
                        "com.lungfish.browser" + ("" if name == "stable" else "." + name))
            if (selected.displayName, selected.bundleName, selected.bundleIdentifier) != expected:
                raise ValueError("upstream runtime identity requires its exact names and bundle identifier; configure a namespace for forks")


def legacy_identity():
    return PublicIdentity(UPSTREAM_REPOSITORY, UPSTREAM_PUBLIC_KEY, None,
                          "https://lungfish.bio", "https://lungfish.bio/docs/",
                          f"https://github.com/{UPSTREAM_REPOSITORY}/releases")


def identity_plist(contract, channel):
    selected = contract.profile(channel) if channel == "debug" else contract.channel(channel)
    identity = contract.identity
    metadata = {
        "CFBundleDisplayName": selected.displayName,
        "CFBundleName": selected.bundleName,
        "CFBundleIdentifier": selected.bundleIdentifier,
        "LungfishReleaseChannel": channel,
        "LungfishWebsiteURL": identity.websiteURL,
        "LungfishDocumentationURL": identity.documentationURL,
        "LungfishReleaseHistoryURL": identity.releaseHistoryURL,
    }
    if identity.runtimeNamespace is not None:
        metadata.update(LungfishIdentitySchemaVersion=1, LungfishRuntimeNamespace=identity.runtimeNamespace)
    return metadata


def prepare_identity_plist(root, contract, channel):
    """Reconstruct reproducible link inputs for package AND later verification."""
    data = plistlib.dumps(identity_plist(contract, channel), sort_keys=True)
    digest = hashlib.sha256(data).hexdigest()
    directory = Path(root) / ".build" / "release-inputs" / digest
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "cli-identity.plist"
    if path.is_symlink() or directory.is_symlink():
        raise ValueError("identity input path must not be a symlink")
    if path.exists():
        if path.read_bytes() != data:
            raise ValueError("identity input contents do not match their digest")
    else:
        with path.open("xb") as output:
            output.write(data)
    return path


def apply_app_identity(app, contract, channel):
    app = Path(app)
    if app.suffix != ".app" or not app.is_dir() or app.is_symlink():
        raise ValueError("identity target must be an app directory")
    info = app / "Contents/Info.plist"
    value = plistlib.loads(info.read_bytes())
    value.update(identity_plist(contract, channel))
    if contract.identity.runtimeNamespace is None:
        value.pop("LungfishIdentitySchemaVersion", None)
        value.pop("LungfishRuntimeNamespace", None)
    if contract.identity.runtimeNamespace is not None:
        help_name = value["CFBundleDisplayName"] + " Help"
        value["CFBundleHelpBookName"] = help_name
        for help_info in (app / "Contents/Resources").glob("*.help/Contents/Info.plist"):
            help_value = plistlib.loads(help_info.read_bytes())
            help_value.update(CFBundleIdentifier=value["CFBundleIdentifier"] + ".help",
                              CFBundleName=help_name, HPDBookTitle=help_name)
            help_info.write_bytes(plistlib.dumps(help_value))
    info.write_bytes(plistlib.dumps(value))


def fork_contract(original, identity_value, product_name):
    identity = PublicIdentity.parse(identity_value)
    if identity.runtimeNamespace is None:
        raise ValueError("fork configuration requires a runtime namespace")
    if (not valid_product_name(product_name) or len((product_name + " Preview").encode()) > 200
            or any(c in '/\\:' for c in product_name)):
        raise ValueError("product name must be a short, safe visible name")
    result = copy.deepcopy(original)
    result["identity"] = identity.to_dict()
    for channel, value in result["channels"].items():
        name = product_name + (" Preview" if channel == "preview" else "")
        value.update(appBundleFilename=name + ".app", displayName=name, bundleName=name,
                     bundleIdentifier=identity.runtimeNamespace + (".preview" if channel == "preview" else ""),
                     dmgVolumeName=name, legacyBridgeRelease="", legacyBridgeAppcastFilename="")
    name = product_name + " Debug"
    result["buildProfiles"]["debug"].update(appBundleFilename=name + ".app", displayName=name,
                                             bundleName=name, bundleIdentifier=identity.runtimeNamespace + ".debug")
    return result
