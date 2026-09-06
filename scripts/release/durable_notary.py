"""Durable notarization submission and bounded polling; never blindly resubmit."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time
from types import SimpleNamespace
try:
    from bounded_process import run_bounded, safe_record
    from release_profiles import read_private_json, write_private_json, validate_private_parent, ProfileError
except ModuleNotFoundError:
    from scripts.release.bounded_process import run_bounded, safe_record
    from scripts.release.release_profiles import read_private_json, write_private_json, validate_private_parent, ProfileError


class NotaryError(ValueError):
    pass


def _artifact_identity(path):
    """Hash one stable regular-file descriptor; reject replacement and concurrent writes."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode): raise NotaryError('notarization artifact is not a regular file')
        digest = hashlib.sha256()
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block: break
            digest.update(block)
        after = os.fstat(descriptor)
        current = path.lstat()
        fields = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns, value.st_mode)
        if fields(before) != fields(after) or fields(after) != fields(current):
            raise NotaryError('notarization artifact changed while hashing')
        return dict(path=str(path), sha256=digest.hexdigest(), size=after.st_size,
                    device=after.st_dev, inode=after.st_ino)
    finally:
        os.close(descriptor)


def _json(result):
    try:
        value = json.loads(result.stdout)
        return value if isinstance(value, dict) else {}
    except (ValueError, TypeError): return {}


def notarize(artifact: Path, state_path: Path, profile, *, run=run_bounded, timeout=180, poll_budget=600, poll_interval=5, env=None):
    if timeout <= 0 or poll_budget < 0 or poll_interval < 0: raise NotaryError('invalid notarization budget')
    artifact = artifact.expanduser().absolute()
    state_path = state_path.expanduser().absolute()
    if artifact.is_symlink() or not artifact.is_file(): raise NotaryError('notarization artifact must be a regular non-symlink file')
    # Parent is private so same-account coordination cannot be replaced by another user.
    try: validate_private_parent(state_path)
    except ProfileError as error: raise NotaryError(str(error)) from error
    identity = _artifact_identity(artifact)
    context = dict(repository=profile.repository, profile=profile.notary_profile, keychain=profile.notary_keychain)
    lock_path = state_path.with_name(state_path.name + '.lock')
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1: raise NotaryError('unsafe notarization state lock')
        try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error: raise NotaryError('notarization state is in use') from error
        existing = state_path.exists() or state_path.is_symlink()
        if existing:
            try: state = read_private_json(state_path)
            except ProfileError as error: raise NotaryError(str(error)) from error
            if state.get('schemaVersion') != 1 or state.get('credentialContext') != context:
                raise NotaryError('notarization credential context changed or state is invalid')
            if state.get('artifact') != identity:
                state.update(status='Blocked', blockedReason='ArtifactChanged', updatedAt=datetime.now(timezone.utc).isoformat())
                write_private_json(state_path, state, replace=True)
                raise NotaryError('notarization artifact changed; retained submission evidence is blocked')
            if state.get('status') in ('Submitting', 'AmbiguousUpload'):
                raise NotaryError('upload outcome is ambiguous; reconcile submission ID before continuing')
            if state.get('status') not in ('In Progress', 'Accepted', 'Invalid'): raise NotaryError('notarization state is invalid')
            if re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', str(state.get('submissionId', ''))) is None:
                raise NotaryError('notarization state lacks a valid submission ID')
        else:
            state = dict(schemaVersion=1, artifact=identity, credentialContext=context, status='Submitting', submissionId=None)
        def save():
            state['updatedAt'] = datetime.now(timezone.utc).isoformat()
            write_private_json(state_path, state, replace=state_path.exists())
        def unchanged():
            try:
                current = _artifact_identity(artifact)
            except (OSError, NotaryError):
                current = None
            if current != identity:
                state.update(status='Blocked', blockedReason='ArtifactChanged')
                save()
                raise NotaryError('notarization artifact changed; retained submission evidence is blocked')
        unchanged()
        if state['status'] in ('Accepted', 'Invalid'):
            return state
        common = ['--keychain-profile', profile.notary_profile]
        if profile.notary_keychain: common += ['--keychain', profile.notary_keychain]
        if not existing:
            save()  # A crash from this point is ambiguous until an ID is durable.
            try:
                unchanged()
                result = run(['xcrun', 'notarytool', 'submit', str(artifact), *common, '--output-format', 'json'], timeout=timeout, env=env)
                state['submissionCommand'] = safe_record(result, phase='notary-submit')
                submission_id = _json(result).get('id')
                if not isinstance(submission_id, str) or re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', submission_id) is None:
                    state['status'] = 'AmbiguousUpload'; save(); unchanged(); return state
            except OSError:
                state['status'] = 'AmbiguousUpload'; save(); unchanged(); return state
            state.update(submissionId=submission_id, status='In Progress')
            save()  # Persist submission ID even if the input changed during upload.
            unchanged()
        deadline = time.monotonic() + poll_budget
        while time.monotonic() < deadline:
            unchanged()
            try:
                result = run(['xcrun', 'notarytool', 'info', state['submissionId'], *common, '--output-format', 'json'], timeout=min(timeout, max(.01, deadline-time.monotonic())), env=env)
                state['lastPollCommand'] = safe_record(result, phase='notary-info')
                response = _json(result)
                status = response.get('status')
                unchanged()
                if result.returncode == 0 and response.get('id') != state['submissionId']:
                    state.update(status='Blocked', blockedReason='SubmissionResponseMismatch')
                    save()
                    raise NotaryError('notarization info response does not match retained submission ID')
                if result.returncode == 0 and status in ('Accepted', 'Invalid', 'In Progress'):
                    state['status'] = status
                    state['lastPollOutcome'] = 'StatusReceived'
                else: state['lastPollOutcome'] = 'TransportOrResponseFailure'
            except OSError:
                state['lastPollOutcome'] = 'ToolUnavailable'
            unchanged()
            save()
            if state['status'] in ('Accepted', 'Invalid'):
                unchanged()
                return state
            time.sleep(min(poll_interval, max(0, deadline-time.monotonic())))
        unchanged()
        return state
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--notary-profile', required=True)
    parser.add_argument('--notary-keychain')
    parser.add_argument('--command-timeout', type=float, default=180)
    parser.add_argument('--poll-budget', type=float, default=600)
    args = parser.parse_args()
    try:
        result = notarize(args.artifact, args.state, args, timeout=args.command_timeout, poll_budget=args.poll_budget)
    except (NotaryError, ProfileError, OSError) as error:
        print('Notarization cannot continue: ' + str(error))
        return 76
    print(json.dumps({k: result[k] for k in ('status', 'submissionId', 'artifact')}))
    return {'Accepted': 0, 'Invalid': 2, 'In Progress': 75, 'AmbiguousUpload': 76}[result['status']]


if __name__ == '__main__': raise SystemExit(main())
