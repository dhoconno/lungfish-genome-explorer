"""Private machine selectors. No secret import, export, unlock, or rotation."""
from __future__ import annotations
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import stat
import tempfile

MAX_METADATA_BYTES = 128 * 1024


class ProfileError(ValueError):
    pass


@dataclass(frozen=True)
class ReleaseProfile:
    repository: str
    signing_identity: str
    team_id: str
    notary_profile: str
    signing_keychain: str | None = None
    certificate_sha1: str | None = None
    notary_keychain: str | None = None
    sparkle_account: str = 'ed25519'
    schema_version: int = 1


def validate_private_parent(path: Path) -> None:
    """Reject symlink/replaceable ancestors; root-owned sticky temp ancestors are OK."""
    for index, parent in enumerate((path.parent, *path.parent.parents)):
        try:
            info = parent.lstat()
        except OSError as error:
            raise ProfileError('private metadata parent is unavailable') from error
        mode = stat.S_IMODE(info.st_mode)
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise ProfileError('private metadata parent chain must not contain symlinks')
        if index == 0:
            if info.st_uid != os.geteuid() or mode != 0o700:
                raise ProfileError('private metadata parent must be owned by current user with mode 0700')
        elif info.st_uid not in (0, os.geteuid()) or (mode & 0o022 and not (info.st_uid == 0 and mode & stat.S_ISVTX)):
            raise ProfileError('private metadata parent chain has unsafe ownership or permissions')


def _path(path: Path) -> Path:
    value = path.expanduser().absolute()
    if '..' in value.parts:
        raise ProfileError('private metadata path cannot contain parent traversal')
    return value


def read_private_json(path: Path) -> dict:
    path = _path(path)
    validate_private_parent(path)
    descriptor = None
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 1:
            raise ProfileError('private metadata must be a regular non-symlink, single-link mode-0600 file owned by current user')
        if not 0 < metadata.st_size <= MAX_METADATA_BYTES:
            raise ProfileError('private metadata has invalid size')
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        opened = os.fstat(descriptor)
        if (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns, metadata.st_ctime_ns,
            metadata.st_mode, metadata.st_uid, metadata.st_nlink) != (
            opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns,
            opened.st_mode, opened.st_uid, opened.st_nlink):
            raise ProfileError('private metadata changed during open')
        raw = b''
        while len(raw) <= MAX_METADATA_BYTES:
            chunk = os.read(descriptor, min(65536, MAX_METADATA_BYTES + 1 - len(raw)))
            if not chunk: break
            raw += chunk
        final = os.fstat(descriptor)
        if len(raw) != opened.st_size or (final.st_size, final.st_mtime_ns, final.st_ctime_ns) != (opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns):
            raise ProfileError('private metadata changed during read')
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result: raise ProfileError('private metadata has duplicate JSON keys')
                result[key] = value
            return result
        result = json.loads(raw.decode('utf-8'), object_pairs_hook=unique)
        if not isinstance(result, dict): raise ProfileError('private metadata must contain a JSON object')
        return result
    except ProfileError:
        raise
    except (OSError, UnicodeError, ValueError) as error:
        raise ProfileError('private metadata is unavailable or invalid JSON') from error
    finally:
        if descriptor is not None: os.close(descriptor)


def write_private_json(path: Path, payload: dict, *, replace: bool = False) -> None:
    path = _path(path)
    missing = []
    parent = path.parent
    while not parent.exists() and not parent.is_symlink():
        missing.append(parent); parent = parent.parent
    for directory in reversed(missing):
        # Validate every existing ancestor before creating any directory.
        ancestor = directory.parent
        for item in (ancestor, *ancestor.parents):
            info = item.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.geteuid()) or (stat.S_IMODE(info.st_mode) & 0o022 and not (info.st_uid == 0 and info.st_mode & stat.S_ISVTX)):
                raise ProfileError('private metadata ancestor is unsafe')
        directory.mkdir(mode=0o700)
    validate_private_parent(path)
    if path.exists() or path.is_symlink():
        if not replace: raise ProfileError('private metadata already exists; refusing overwrite')
        read_private_json(path)
    raw = (json.dumps(payload, sort_keys=True, indent=2) + '\n').encode()
    if len(raw) > MAX_METADATA_BYTES: raise ProfileError('private metadata exceeds size limit')
    temporary = None
    try:
        fd, name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
        temporary = Path(name)
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(raw); stream.flush(); os.fsync(stream.fileno())
        validate_private_parent(path)
        if replace:
            os.replace(temporary, path); temporary = None
        else:
            os.link(temporary, path, follow_symlinks=False)
            temporary.unlink(); temporary = None
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try: os.fsync(directory_fd)
        finally: os.close(directory_fd)
    except OSError as error:
        raise ProfileError('private metadata could not be atomically written') from error
    finally:
        if temporary is not None: temporary.unlink(missing_ok=True)


def _keys(value, required, label):
    if not isinstance(value, dict) or set(value) != set(required):
        raise ProfileError(f'release profile {label} has unknown or missing keys')


def _text(value, label):
    if not isinstance(value, str) or not value or value != value.strip() or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ProfileError(f'release profile {label} contains invalid/control characters')
    return value


def _keychain(value):
    if value is None: return None
    value = _text(value, 'keychainPath')
    if not Path(value).is_absolute() or '..' in Path(value).parts:
        raise ProfileError('release profile keychainPath must be absolute without traversal')
    return value


def profile_payload(profile: ReleaseProfile) -> dict:
    if profile.schema_version == 1:
        if profile.signing_keychain or profile.certificate_sha1 or profile.notary_keychain or profile.sparkle_account != 'ed25519':
            raise ProfileError('legacy profile cannot discard v2 selectors')
        return dict(schemaVersion=1, repository=profile.repository, signingIdentity=profile.signing_identity, teamId=profile.team_id, notaryProfile=profile.notary_profile)
    return dict(schemaVersion=profile.schema_version, repository=profile.repository, signing=dict(identity=profile.signing_identity, teamId=profile.team_id, keychainPath=profile.signing_keychain, certificateSha1=profile.certificate_sha1), notary=dict(profile=profile.notary_profile, keychainPath=profile.notary_keychain), sparkle=dict(account=profile.sparkle_account))


def parse_profile(payload: dict, *, expected_repository: str | None = None) -> ReleaseProfile:
    version = payload.get('schemaVersion')
    if type(version) is not int or version not in (1, 2): raise ProfileError('release profile schemaVersion must be 1 or 2')
    if version == 1:
        _keys(payload, ('schemaVersion', 'repository', 'signingIdentity', 'teamId', 'notaryProfile'), 'v1')
        signing, team, notary = payload['signingIdentity'], payload['teamId'], payload['notaryProfile']
        signing_keychain = certificate = notary_keychain = None
        account = 'ed25519'
    else:
        _keys(payload, ('schemaVersion', 'repository', 'signing', 'notary', 'sparkle'), 'v2')
        _keys(payload['signing'], ('identity', 'teamId', 'keychainPath', 'certificateSha1'), 'signing')
        _keys(payload['notary'], ('profile', 'keychainPath'), 'notary')
        _keys(payload['sparkle'], ('account',), 'sparkle')
        signing, team = payload['signing']['identity'], payload['signing']['teamId']
        notary, account = payload['notary']['profile'], payload['sparkle']['account']
        signing_keychain, notary_keychain = _keychain(payload['signing']['keychainPath']), _keychain(payload['notary']['keychainPath'])
        certificate = payload['signing']['certificateSha1']
        if certificate is not None:
            if not isinstance(certificate, str) or re.fullmatch('[a-fA-F0-9]{40}', certificate) is None: raise ProfileError('release profile certificateSha1 must be 40 hexadecimal characters')
            certificate = certificate.upper()
    repository = _text(payload['repository'], 'repository')
    if re.fullmatch('[A-Za-z0-9-]+/[A-Za-z0-9._-]+', repository) is None: raise ProfileError('release profile repository must be OWNER/REPOSITORY')
    repository = repository.lower()
    if expected_repository is not None and repository != expected_repository.lower(): raise ProfileError('release profile repository does not match selected repository')
    signing, team, notary, account = (_text(v, k) for v, k in ((signing,'signingIdentity'),(team,'teamId'),(notary,'notaryProfile'),(account,'sparkle account')))
    if re.fullmatch('[A-Z0-9]{10}', team) is None: raise ProfileError('release profile teamId must be a 10-character Team ID')
    if not signing.startswith('Developer ID Application:') or not signing.endswith('(' + team + ')'): raise ProfileError('release profile signing identity must be Developer ID Application for selected Team ID')
    return ReleaseProfile(repository, signing, team, notary, signing_keychain, certificate, notary_keychain, account, version)


def load_release_profile(path: Path, *, expected_repository: str | None = None) -> ReleaseProfile:
    return parse_profile(read_private_json(path), expected_repository=expected_repository)


def write_release_profile(path: Path, profile: ReleaseProfile) -> None:
    payload = profile_payload(profile)
    parse_profile(payload)
    write_private_json(path, payload)
