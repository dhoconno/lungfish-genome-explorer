#!/usr/bin/env python3
"""Choose, check and prove the Developer ID Application certificate that signs a release.

Apple's original Developer ID Certification Authority (the G1 Sub-CA) expires on 2027-02-01 22:12:15 UTC and every
certificate it issued stops working then. Certificates from the G2 Sub-CA replace it. While an old and a new
certificate are both installed they share one common name, so `codesign -s NAME` is ambiguous and a release must
sign by SHA-1. This module reads the keychain only with `security find-identity` and `security find-certificate`.
The `verify` command also signs a throwaway bundle in a new temporary folder and deletes it. Nothing here creates,
imports, exports or deletes a certificate or key, and nothing touches a release artifact.

    python3 scripts/release/developer_id.py show   [--profile PATH]
    python3 scripts/release/developer_id.py verify [--profile PATH] [--certificate-sha1 SHA1]

The runbook is docs/development/developer-id.md.
"""
from __future__ import annotations

import argparse
import base64
import binascii
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import hashlib
import math
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Callable, Iterable

try:
    from bounded_process import run_bounded
    from release_profiles import NEWEST_G2_POLICY, ProfileError, default_profile_path, load_release_profile
    from release_repository import RepositoryIdentityError, resolve_repository_identity
except ModuleNotFoundError:
    from scripts.release.bounded_process import run_bounded
    from scripts.release.release_profiles import NEWEST_G2_POLICY, ProfileError, default_profile_path, load_release_profile
    from scripts.release.release_repository import RepositoryIdentityError, resolve_repository_identity


RUNBOOK = "docs/development/developer-id.md"
APPLICATION_PREFIX = "Developer ID Application"
DEVELOPER_ID_CA = "Developer ID Certification Authority"
APPLE_ROOT_CA = "Apple Root CA"
G1_ORGANIZATIONAL_UNIT = "Apple Certification Authority"
G2_ORGANIZATIONAL_UNIT = "G2"
G1_SUB_CA_EXPIRY = datetime(2027, 2, 1, 22, 12, 15, tzinfo=timezone.utc)
WARNING_WINDOW = timedelta(days=60)
# The designated requirement of a shipped build without its bundle identifier. A signature that satisfies it
# satisfies the requirement Sparkle checks an update against, whichever Developer ID Sub-CA issued it.
DEVELOPER_ID_REQUIREMENT = (
    "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
    " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    ' and certificate leaf[subject.OU] = "{team}"'
)
SYSTEM_TOOLS = {"security": "/usr/bin/security", "codesign": "/usr/bin/codesign", "spctl": "/usr/sbin/spctl"}
PROBE_SOURCE = Path("/usr/bin/true")
PROBE_NAME = "LungfishSigningProbe"
COMMAND_TIMEOUT_SECONDS = 120

Runner = Callable[[list[str]], subprocess.CompletedProcess]


class SigningIdentityError(ValueError):
    """An actionable failure that names every candidate it saw."""


class CertificateError(SigningIdentityError):
    """A certificate the keychain returned could not be decoded."""


@dataclass(frozen=True)
class Identity:
    sha1: str
    name: str
    valid: bool
    problem: str | None = None


@dataclass(frozen=True)
class Certificate:
    sha1: str
    subject_cn: str | None
    subject_ou: str | None
    issuer_cn: str | None
    issuer_ou: str | None
    not_before: datetime
    not_after: datetime

    @property
    def sub_ca(self) -> str | None:
        """G1 for the original Developer ID Sub-CA, G2 for its replacement, None for any other issuer."""
        if self.issuer_cn != DEVELOPER_ID_CA:
            return None
        if self.issuer_ou in (None, G1_ORGANIZATIONAL_UNIT):
            return "G1"
        return self.issuer_ou

    def issuer_label(self) -> str:
        if self.sub_ca == "G1":
            return f"{DEVELOPER_ID_CA} (original Sub-CA, expires {G1_SUB_CA_EXPIRY:%Y-%m-%d})"
        if self.sub_ca is not None:
            return f"{DEVELOPER_ID_CA} ({self.sub_ca})"
        issuer = self.issuer_cn or "an unnamed issuer"
        return f"{issuer} ({self.issuer_ou})" if self.issuer_ou else issuer


@dataclass(frozen=True)
class Selection:
    identity: Identity
    certificate: Certificate
    reason: str


@dataclass(frozen=True)
class Assessment:
    status: str
    detail: str


# --- security find-identity -------------------------------------------------------------------------------------

_IDENTITY_ROW = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.*)"(?:\s+\(([^()]*)\))?\s*$')


def parse_identities(text: str) -> list[Identity]:
    """Rows of `security find-identity -p codesigning`, valid when listed under "Valid identities only".

    Output without section headings (the `-v` form) marks a row valid when it carries no trust problem.
    """
    listed: dict[str, tuple[str, str | None]] = {}
    valid: set[str] = set()
    sections = in_valid = False
    for line in text.splitlines():
        heading = line.strip().lower()
        if heading.startswith("valid identities only"):
            sections = in_valid = True
            continue
        if heading.startswith("matching identities"):
            sections, in_valid = True, False
            continue
        match = _IDENTITY_ROW.match(line)
        if match is None:
            continue
        sha1, name, problem = match.group(1).upper(), match.group(2), match.group(3)
        if in_valid:
            valid.add(sha1)
        listed.setdefault(sha1, (name, problem))
    if not sections:
        valid = {sha1 for sha1, (_, problem) in listed.items() if problem is None}
    return [Identity(sha1, name, sha1 in valid, problem) for sha1, (name, problem) in listed.items()]


# --- security find-certificate -p: a minimal DER reader for the fields a release checks -------------------------

_PEM = re.compile(r"-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----", re.DOTALL)
_NAME_OIDS = {bytes.fromhex("550403"): "CN", bytes.fromhex("55040b"): "OU"}


def _element(data: bytes, offset: int, limit: int) -> tuple[int, int, int]:
    if offset + 2 > limit:
        raise CertificateError("certificate DER is truncated")
    tag, length = data[offset], data[offset + 1]
    if tag & 0x1F == 0x1F:
        raise CertificateError("certificate DER uses an unsupported tag")
    start = offset + 2
    if length & 0x80:
        count = length & 0x7F
        if not 1 <= count <= 4 or start + count > limit:
            raise CertificateError("certificate DER has an invalid length")
        length = int.from_bytes(data[start:start + count], "big")
        start += count
    end = start + length
    if end > limit:
        raise CertificateError("certificate DER is truncated")
    return tag, start, end


def _children(data: bytes, start: int, end: int) -> list[tuple[int, int, int]]:
    items = []
    while start < end:
        item = _element(data, start, end)
        items.append(item)
        start = item[2]
    return items


def _text(tag: int, raw: bytes) -> str:
    try:
        if tag == 0x0C:
            return raw.decode("utf-8")
        if tag in (0x13, 0x16, 0x1A):
            return raw.decode("ascii")
        if tag == 0x14:
            return raw.decode("latin-1")
        if tag == 0x1E:
            return raw.decode("utf-16-be")
        if tag == 0x1C:
            return raw.decode("utf-32-be")
    except UnicodeDecodeError as error:
        raise CertificateError("certificate name is not valid text") from error
    raise CertificateError("certificate name uses an unsupported string type")


def _name(data: bytes, start: int, end: int) -> dict[str, str]:
    values: dict[str, str] = {}
    for set_tag, set_start, set_end in _children(data, start, end):
        if set_tag != 0x31:
            raise CertificateError("certificate name is not a sequence of sets")
        for pair_tag, pair_start, pair_end in _children(data, set_start, set_end):
            pair = _children(data, pair_start, pair_end)
            if pair_tag != 0x30 or len(pair) != 2 or pair[0][0] != 0x06:
                raise CertificateError("certificate name attribute is malformed")
            key = _NAME_OIDS.get(data[pair[0][1]:pair[0][2]])
            if key is not None and key not in values:
                values[key] = _text(pair[1][0], data[pair[1][1]:pair[1][2]])
    return values


def _time(tag: int, raw: bytes) -> datetime:
    try:
        text = raw.decode("ascii")
        if tag == 0x17 and re.fullmatch(r"\d{12}Z", text):
            year = int(text[:2])
            text = str(year + (1900 if year >= 50 else 2000)) + text[2:]
        elif tag != 0x18 or not re.fullmatch(r"\d{14}Z", text):
            raise ValueError(text)
        return datetime.strptime(text, "%Y%m%d%H%M%SZ").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise CertificateError("certificate validity time is malformed") from error


def parse_certificate(der: bytes) -> Certificate:
    """Read the SHA-1, subject, issuer and validity of one X.509 certificate."""
    tag, start, end = _element(der, 0, len(der))
    if tag != 0x30 or end != len(der):
        raise CertificateError("certificate is not one DER sequence")
    tbs_tag, tbs_start, tbs_end = _element(der, start, end)
    if tbs_tag != 0x30:
        raise CertificateError("certificate has no to-be-signed sequence")
    fields = _children(der, tbs_start, tbs_end)
    if fields and fields[0][0] == 0xA0:
        fields = fields[1:]
    if len(fields) < 5 or [field[0] for field in fields[:5]] != [0x02, 0x30, 0x30, 0x30, 0x30]:
        raise CertificateError("certificate fields are not in X.509 order")
    issuer, validity, subject = fields[2], fields[3], fields[4]
    times = _children(der, validity[1], validity[2])
    if len(times) != 2:
        raise CertificateError("certificate validity is malformed")
    issuer_name, subject_name = _name(der, issuer[1], issuer[2]), _name(der, subject[1], subject[2])
    return Certificate(
        sha1=hashlib.sha1(der).hexdigest().upper(),
        subject_cn=subject_name.get("CN"), subject_ou=subject_name.get("OU"),
        issuer_cn=issuer_name.get("CN"), issuer_ou=issuer_name.get("OU"),
        not_before=_time(times[0][0], der[times[0][1]:times[0][2]]),
        not_after=_time(times[1][0], der[times[1][1]:times[1][2]]),
    )


def parse_certificates(text: str) -> dict[str, Certificate]:
    """Every PEM certificate of `security find-certificate -a -p`, keyed by the SHA-1 of its DER bytes."""
    certificates: dict[str, Certificate] = {}
    for block in _PEM.findall(text):
        try:
            der = base64.b64decode("".join(block.split()), validate=True)
            certificate = parse_certificate(der)
        except (binascii.Error, CertificateError):
            continue
        certificates[certificate.sha1] = certificate
    return certificates


# --- selection and expiry ---------------------------------------------------------------------------------------

def _moment(value: datetime) -> str:
    return value.strftime("%Y-%m-%d %H:%M:%S UTC")


def describe(identity: Identity, certificates: dict[str, Certificate]) -> str:
    certificate = certificates.get(identity.sha1)
    parts = []
    if certificate is None:
        parts.append("certificate details unavailable")
    else:
        parts += [f"issued by {certificate.issuer_label()}", f"expires {_moment(certificate.not_after)}"]
    if not identity.valid:
        parts.append(f"not trusted: {identity.problem or 'not listed as valid'}")
    return f"{identity.sha1} ({', '.join(parts)})"


def _inventory(name: str, named: list[Identity], certificates: dict[str, Certificate]) -> str:
    if not named:
        return f'no code signing identity is named "{name}"'
    return f'identities named "{name}": ' + "; ".join(describe(identity, certificates) for identity in named)


def _trust_hint(identity: Identity) -> str:
    problem = (identity.problem or "").upper()
    if "EXPIRED" in problem:
        return "it has expired"
    if "NOT_TRUSTED" in problem or "INCOMPLETE" in problem or not problem:
        return (f"macOS cannot build its chain, so install the issuing Developer ID intermediate "
                f"(the G2 one for a G2 certificate) as {RUNBOOK} describes")
    return "macOS does not trust it"


def _usable(identity: Identity, certificates: dict[str, Certificate], reason: str) -> Selection:
    if not identity.valid:
        raise SigningIdentityError(f'{identity.sha1} "{identity.name}" is installed but not valid '
                                   f"({identity.problem or 'not listed as valid'}); {_trust_hint(identity)}")
    certificate = certificates.get(identity.sha1)
    if certificate is None:
        raise SigningIdentityError(f"security find-certificate did not return certificate {identity.sha1}, "
                                   "so its issuer and expiry cannot be checked")
    return Selection(identity, certificate, reason)


def select_identity(identities: Iterable[Identity], certificates: dict[str, Certificate], *, name: str,
                    certificate_sha1: str | None = None, policy: str | None = None) -> Selection:
    """Pick the identity a release signs with, or fail naming every candidate.

    A SHA-1 wins. The newest-g2 policy picks the most recently issued valid G2 identity of the name. Without
    either, the name must match exactly one valid identity, because codesign cannot choose between two.
    """
    identities = list(identities)
    named = [identity for identity in identities if identity.name == name]
    if certificate_sha1 and policy:
        raise SigningIdentityError("set a certificate SHA-1 or a certificate policy, not both")
    if certificate_sha1:
        wanted = certificate_sha1.upper()
        match = next((identity for identity in identities if identity.sha1 == wanted), None)
        if match is None:
            raise SigningIdentityError(f"requested Developer ID signing identity is unavailable: certificate SHA-1 "
                                       f"{wanted} is not an installed code signing identity; "
                                       + _inventory(name, named, certificates))
        if match.name != name:
            raise SigningIdentityError(f'selected certificate fingerprint {wanted} does not match the Developer ID '
                                       f'identity: it belongs to "{match.name}", not "{name}"')
        return _usable(match, certificates, "certificate SHA-1 set in the release profile")
    if policy == NEWEST_G2_POLICY:
        g2 = [identity for identity in named if identity.valid and identity.sha1 in certificates
              and certificates[identity.sha1].sub_ca == G2_ORGANIZATIONAL_UNIT]
        if not g2:
            raise SigningIdentityError("the release profile asks for the newest G2 identity, but no valid identity "
                                       f'named "{name}" was issued by the G2 Developer ID Sub-CA; '
                                       + _inventory(name, named, certificates) + f". Create one as {RUNBOOK} describes")
        chosen = max(g2, key=lambda identity: (certificates[identity.sha1].not_before,
                                               certificates[identity.sha1].not_after, identity.sha1))
        return _usable(chosen, certificates, "newest G2 identity of the team")
    if policy is not None:
        raise SigningIdentityError(f"unknown certificate policy {policy!r}")
    valid = [identity for identity in named if identity.valid]
    if len(valid) > 1:
        raise SigningIdentityError(
            f'{len(valid)} valid identities are named "{name}", so signing by name is ambiguous: '
            + "; ".join(describe(identity, certificates) for identity in valid)
            + ". Choose one in the release profile with release.py configure-machine --replace and either "
            f"--certificate-sha1 SHA1 or --certificate-policy {NEWEST_G2_POLICY} ({RUNBOOK})")
    if valid:
        return _usable(valid[0], certificates, "the only valid identity with this name")
    if named:
        raise SigningIdentityError("requested Developer ID signing identity is installed but not valid: "
                                   + "; ".join(describe(identity, certificates) for identity in named)
                                   + f"; {_trust_hint(named[0])}")
    raise SigningIdentityError(f'requested Developer ID signing identity is unavailable: no valid identity is named "{name}"')


def assess(certificate: Certificate, now: datetime) -> Assessment:
    """PASS, WARN within 60 days of expiry or for the expiring G1 Sub-CA, FAIL once expired or past its cutoff."""
    remaining = certificate.not_after - now
    days = math.floor(remaining.total_seconds() / 86400)
    detail = (f"{certificate.sha1} issued by {certificate.issuer_label()}, valid "
              f"{_moment(certificate.not_before)} to {_moment(certificate.not_after)}")
    if certificate.sub_ca is None:
        return Assessment("FAIL", f"{detail}; it was not issued by a {DEVELOPER_ID_CA}")
    if now < certificate.not_before:
        return Assessment("FAIL", f"{detail}; it is not valid yet")
    if now >= certificate.not_after:
        return Assessment("FAIL", f"{detail}; it has expired, so create a Developer ID Application certificate "
                                  f"from the G2 Sub-CA ({RUNBOOK})")
    if certificate.sub_ca == "G1" and now >= G1_SUB_CA_EXPIRY:
        return Assessment("FAIL", f"{detail}; the original Developer ID Sub-CA expired on "
                                  f"{_moment(G1_SUB_CA_EXPIRY)}, so select a G2 certificate ({RUNBOOK})")
    warnings = []
    if certificate.sub_ca == "G1":
        warnings.append(f"the original Developer ID Sub-CA expires on {_moment(G1_SUB_CA_EXPIRY)}, "
                        "so create a G2 certificate and select it")
    if remaining <= WARNING_WINDOW:
        warnings.append("it expires within 60 days, so renew it")
    if warnings:
        return Assessment("WARN", f"{detail} ({days} days left); " + " and ".join(warnings) + f" ({RUNBOOK})")
    return Assessment("PASS", f"{detail} ({days} days left)")


def query_keychain(run: Runner, *, name_filter: str, keychain: str | None = None,
                   security: str = "security") -> tuple[list[Identity], dict[str, Certificate]]:
    """Read-only: code signing identities, and the certificates whose label contains name_filter."""
    find_identity = [security, "find-identity", "-p", "codesigning"]
    find_certificate = [security, "find-certificate", "-a", "-c", name_filter, "-p"]
    if keychain:
        find_identity.append(keychain)
        find_certificate.append(keychain)
    listed = run(find_identity)
    if listed.returncode != 0:
        raise SigningIdentityError("security find-identity failed; the keychain is missing, locked or unreadable")
    identities = parse_identities(listed.stdout or "")
    certificates: dict[str, Certificate] = {}
    if any(name_filter in identity.name for identity in identities):
        found = run(find_certificate)
        if found.returncode == 0:
            certificates = parse_certificates(found.stdout or "")
    return identities, certificates


def select_from_keychain(run: Runner, *, name: str, certificate_sha1: str | None = None, policy: str | None = None,
                         keychain: str | None = None, security: str = "security") -> Selection:
    identities, certificates = query_keychain(run, name_filter=name, keychain=keychain, security=security)
    return select_identity(identities, certificates, name=name, certificate_sha1=certificate_sha1, policy=policy)


# --- the throwaway verification ---------------------------------------------------------------------------------

def build_probe_bundle(directory: Path, source: Path = PROBE_SOURCE) -> Path:
    """A minimal app bundle around a copy of a system executable. Only its signature matters."""
    bundle = directory / f"{PROBE_NAME}.app"
    executable = bundle / "Contents" / "MacOS" / PROBE_NAME
    executable.parent.mkdir(parents=True)
    shutil.copyfile(source, executable)
    executable.chmod(0o755)
    with (bundle / "Contents" / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleExecutable": PROBE_NAME, "CFBundleIdentifier": "bio.lungfish.developer-id-probe",
                       "CFBundleName": PROBE_NAME, "CFBundlePackageType": "APPL",
                       "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"}, stream)
    return bundle


def _output(result: subprocess.CompletedProcess) -> str:
    return (result.stdout or "") + (result.stderr or "")


def _last_line(result: subprocess.CompletedProcess) -> str:
    lines = [line.strip() for line in _output(result).splitlines() if line.strip()]
    return lines[-1] if lines else f"exit {result.returncode}"


def verify_signing(selection: Selection, *, team_id: str, run: Runner, keychain: str | None = None,
                   tools: dict[str, str] = SYSTEM_TOOLS, emit: Callable[[str], None] = print,
                   temporary_root: Path | None = None) -> None:
    """Sign a throwaway bundle in a new temporary folder exactly as a release signs code, then check it.

    The folder is deleted afterwards. The command takes no artifact path, so it cannot touch a release.
    """
    sha1, name = selection.identity.sha1, selection.identity.name
    with tempfile.TemporaryDirectory(prefix="lungfish-developer-id-probe-", dir=temporary_root) as directory:
        bundle = str(build_probe_bundle(Path(directory)))

        def step(label: str, passed: bool, detail: str) -> None:
            emit(f"{'PASS' if passed else 'FAIL'} {label}: {detail}")
            if not passed:
                raise SigningIdentityError(f"Developer ID verification failed at {label}: {detail}")

        command = [tools["codesign"], "--force", "--sign", sha1, "--timestamp", "--options", "runtime"]
        if keychain:
            command += ["--keychain", keychain]
        signed = run([*command, bundle])
        step("sign", signed.returncode == 0,
             f"signed a throwaway app with {sha1}, a secure timestamp and the hardened runtime"
             if signed.returncode == 0 else f"codesign could not sign with {sha1}: {_last_line(signed)}")
        verified = run([tools["codesign"], "--verify", "--strict", "--verbose=2", bundle])
        step("verify", verified.returncode == 0, "codesign --verify --strict accepts the signature"
             if verified.returncode == 0 else _last_line(verified))
        shown = run([tools["codesign"], "--display", "--verbose=4", bundle])
        lines = [line.strip() for line in _output(shown).splitlines()]
        chain = [line.split("=", 1)[1] for line in lines if line.startswith("Authority=")]
        step("chain", shown.returncode == 0 and chain == [name, DEVELOPER_ID_CA, APPLE_ROOT_CA],
             " > ".join(chain) + f", issued by {selection.certificate.issuer_label()}" if chain
             else "codesign --display shows no certificate chain")
        step("team", f"TeamIdentifier={team_id}" in lines, f"TeamIdentifier={team_id}"
             if f"TeamIdentifier={team_id}" in lines else f"the signature does not carry TeamIdentifier={team_id}")
        stamp = next((line for line in lines if line.startswith("Timestamp=")), None)
        step("timestamp", stamp is not None, f"secure timestamp {stamp}" if stamp
             else "no secure timestamp, so Apple's timestamp service did not answer")
        flags = re.search(r"flags=0x[0-9a-fA-F]+\(([^)]*)\)", _output(shown))
        runtime = flags is not None and "runtime" in flags.group(1).split(",")
        step("hardened runtime", runtime, "the runtime flag is set" if runtime else "the runtime flag is missing")
        requirement = DEVELOPER_ID_REQUIREMENT.format(team=team_id)
        satisfied = run([tools["codesign"], "--verify", "-R", "=" + requirement, bundle])
        step("requirement", satisfied.returncode == 0,
             "satisfies the Developer ID requirement that shipped builds and Sparkle updates check"
             if satisfied.returncode == 0 else _last_line(satisfied))
        assessed = run([tools["spctl"], "--assess", "--type", "execute", "-vvv", bundle])
        gatekeeper = _output(assessed)
        origin = f"origin={name}" in [line.strip() for line in gatekeeper.splitlines()]
        accepted = assessed.returncode == 0 or "source=Unnotarized Developer ID" in gatekeeper
        step("Gatekeeper", origin and accepted,
             f"spctl sees origin={name}" + ("" if assessed.returncode == 0 else
                                            " and source=Unnotarized Developer ID, as expected for a probe that is not notarized")
             if origin and accepted else "spctl did not recognize a Developer ID signature: "
             + " | ".join(line.strip() for line in gatekeeper.splitlines() if line.strip()))
    emit(f"Developer ID verification passed for {sha1}. The temporary folder is deleted and no release artifact was touched.")


# --- command line -----------------------------------------------------------------------------------------------

def _run(argv: list[str]) -> subprocess.CompletedProcess:
    result = run_bounded(argv, timeout=COMMAND_TIMEOUT_SECONDS)
    if result.timed_out:
        raise SigningIdentityError(f"{Path(argv[0]).name} exceeded {COMMAND_TIMEOUT_SECONDS} seconds")
    return result


def _profile(args: argparse.Namespace, *, required: bool = True):
    if args.profile is not None:
        path = args.profile.expanduser().absolute()
    else:
        try:
            repository = resolve_repository_identity(args.repo.expanduser().resolve(), "origin").github_repository
        except RepositoryIdentityError as error:
            raise SigningIdentityError(str(error)) from error
        path = default_profile_path(repository)
    if not path.exists():
        if not required:
            return path, None
        raise SigningIdentityError(f"no release profile at {path}; create it with release.py configure-machine")
    try:
        return path, load_release_profile(path)
    except ProfileError as error:
        raise SigningIdentityError(f"release profile {path} is unusable: {error}") from error


def show(args: argparse.Namespace, run: Runner = _run, now: datetime | None = None) -> int:
    path, profile = _profile(args, required=False)
    if profile is None:
        print(f"Release profile: none at {path}, so no identity is selected")
    else:
        choice = (f"SHA-1 {profile.certificate_sha1}" if profile.certificate_sha1 else
                  f"policy {profile.certificate_policy}" if profile.certificate_policy else "none, so the name must be unique")
        print(f"Release profile: {path}")
        print(f"Profile identity: {profile.signing_identity}")
        print(f"Profile certificate choice: {choice}")
    identities, certificates = query_keychain(run, name_filter=APPLICATION_PREFIX,
                                              keychain=profile.signing_keychain if profile else None,
                                              security=SYSTEM_TOOLS["security"])
    listed = [identity for identity in identities if identity.name.startswith(APPLICATION_PREFIX)]
    print(f"{APPLICATION_PREFIX} identities in the keychain: {len(listed)}")
    for identity in listed:
        print(f"  {identity.name}")
        print(f"    {describe(identity, certificates)}")
    if profile is None:
        return 0
    selection = select_identity(identities, certificates, name=profile.signing_identity,
                                certificate_sha1=profile.certificate_sha1, policy=profile.certificate_policy)
    print(f"Selected: {selection.identity.sha1} ({selection.reason})")
    assessment = assess(selection.certificate, now or datetime.now(timezone.utc))
    print(f"{assessment.status} signing certificate: {assessment.detail}")
    return 1 if assessment.status == "FAIL" else 0


def verify(args: argparse.Namespace, run: Runner = _run, now: datetime | None = None) -> int:
    _, profile = _profile(args)
    sha1 = args.certificate_sha1 or profile.certificate_sha1
    if sha1 is not None and re.fullmatch(r"[0-9A-Fa-f]{40}", sha1) is None:
        raise SigningIdentityError("--certificate-sha1 must be 40 hexadecimal characters")
    selection = select_from_keychain(run, name=profile.signing_identity, certificate_sha1=sha1,
                                     policy=None if sha1 else profile.certificate_policy,
                                     keychain=profile.signing_keychain, security=SYSTEM_TOOLS["security"])
    print(f"Selected: {selection.identity.sha1} ({'certificate SHA-1 given on the command line' if args.certificate_sha1 else selection.reason})")
    assessment = assess(selection.certificate, now or datetime.now(timezone.utc))
    print(f"{assessment.status} signing certificate: {assessment.detail}")
    if assessment.status == "FAIL":
        return 1
    verify_signing(selection, team_id=profile.team_id, run=run, keychain=profile.signing_keychain)
    return 0


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = value.add_subparsers(dest="command", required=True)
    shown = commands.add_parser("show", help="list Developer ID identities, the profile's choice and its expiry")
    checked = commands.add_parser("verify", help="sign a throwaway bundle in a temporary folder and verify it")
    checked.add_argument("--certificate-sha1", help="check this identity instead of the profile's choice")
    for command in (shown, checked):
        command.add_argument("--profile", type=Path, help="release profile (default: the one release.py reads)")
        command.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    return value


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        return show(args) if args.command == "show" else verify(args)
    except (SigningIdentityError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
