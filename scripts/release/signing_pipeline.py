"""Receipt-bound signing stages with immutable notarization inputs and resumable polling."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
try:
    from bounded_process import run_bounded, safe_record
    from durable_notary import notarize, NotaryError, _artifact_identity
    from release_profiles import (ReleaseProfile, ProfileError, profile_payload, parse_profile,
                                  read_private_json, write_private_json, validate_private_parent)
except ModuleNotFoundError:
    from scripts.release.bounded_process import run_bounded, safe_record
    from scripts.release.durable_notary import notarize, NotaryError, _artifact_identity
    from scripts.release.release_profiles import (ReleaseProfile, ProfileError, profile_payload, parse_profile,
                                                 read_private_json, write_private_json, validate_private_parent)


class SigningError(ValueError):
    pass


def artifact_record(path):
    if path.is_symlink(): raise SigningError('signing artifact root must not be a symlink')
    if path.is_file():
        identity = _artifact_identity(path)
        return dict(kind='file', sha256=identity['sha256'], size=identity['size'])
    if not path.is_dir(): raise SigningError('retained signing artifact is missing')
    digest = hashlib.sha256()
    def visit(directory):
        for entry in sorted(directory.iterdir(), key=lambda p: os.fsencode(p.name)):
            info = entry.lstat()
            record = dict(path=str(entry.relative_to(path)), mode=stat.S_IMODE(info.st_mode))
            if stat.S_ISLNK(info.st_mode):
                try: entry.resolve(strict=True).relative_to(path.resolve())
                except (ValueError, OSError) as error: raise SigningError('signing payload has an escaping or broken symlink') from error
                record.update(kind='symlink', target=os.readlink(entry))
            elif stat.S_ISREG(info.st_mode):
                identity = _artifact_identity(entry)
                record.update(kind='file', sha256=identity['sha256'], size=identity['size'])
            elif stat.S_ISDIR(info.st_mode): record['kind'] = 'directory'
            else: raise SigningError('signing payload has an unsupported entry')
            digest.update(json.dumps(record, sort_keys=True, separators=(',', ':')).encode() + b'\n')
            if record['kind'] == 'directory': visit(entry)
    visit(path)
    return dict(kind='directory', sha256=digest.hexdigest())


def sign_and_notarize(source_app, receipt, signed_app, dmg, transaction_dir, profile, *,
                      entitlements, volume_name, public_key, run=run_bounded, notary=notarize,
                      command_timeout=180, poll_budget=600, env=None, smoke_script=None, scratch_path=None):
    source_app, receipt, signed_app, dmg, transaction_dir, entitlements = (
        Path(p).expanduser().absolute() for p in (source_app, receipt, signed_app, dmg, transaction_dir, entitlements))
    if source_app.suffix != '.app' or source_app.is_symlink() or not source_app.is_dir():
        raise SigningError('source candidate must be an app directory')
    if signed_app.name != source_app.name or signed_app.parent != transaction_dir.parent / 'signed' or dmg.parent != transaction_dir.parent:
        raise SigningError('signing output paths must be bounded children of the release directory')
    transaction_dir.mkdir(mode=0o700, exist_ok=True)
    journal = transaction_dir / 'transaction.json'
    validate_private_parent(journal)
    if signed_app.parent.exists() or signed_app.parent.is_symlink():
        validate_private_parent(signed_app.parent / '.private-parent-check')
    context = dict(candidateReceiptSha256=_artifact_identity(receipt)['sha256'],
                   unsignedApp=artifact_record(source_app), profile=profile_payload(profile),
                   expectedPublicKey=public_key, signedApp=str(signed_app), dmg=str(dmg), volumeName=volume_name,
                   entitlementsSha256=_artifact_identity(entitlements)['sha256'],
                   smokeScriptSha256=_artifact_identity(Path(smoke_script))['sha256'] if smoke_script else None)
    paths = dict(appInput=transaction_dir / source_app.name, appZip=transaction_dir / 'app.zip',
                 signedApp=signed_app, dmgInput=transaction_dir / 'input.dmg', dmg=dmg)
    lock = os.open(transaction_dir / '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        info = os.fstat(lock)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
            raise SigningError('signing transaction lock is unsafe')
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error: raise SigningError('signing transaction is already running') from error
        if journal.exists() or journal.is_symlink():
            state = read_private_json(journal)
            if state.get('schemaVersion') != 1 or state.get('context') != context:
                raise SigningError('signing candidate or credential context changed; retained stages preserved')
            if not isinstance(state.get('artifacts'), dict): raise SigningError('signing transaction is invalid')
        else:
            if any(path.exists() or path.is_symlink() for path in paths.values()):
                raise SigningError('unrecorded signing outputs already exist; refusing replacement')
            state = dict(schemaVersion=1, context=context, artifacts={}, commands=[], status='Preparing')
            write_private_json(journal, state)
        def save(): write_private_json(journal, state, replace=True)
        def record(name):
            state['artifacts'][name] = artifact_record(paths[name]); save()
        def validate(name):
            if artifact_record(paths[name]) != state['artifacts'][name]:
                state.update(status='Blocked', blockedReason='RetainedArtifactChanged'); save()
                raise SigningError('retained signing artifact changed; refusing signing or submission')
        for name in state['artifacts']:
            if name not in paths: raise SigningError('signing transaction has unknown artifact')
            validate(name)
        if state.get('status') == 'Accepted':
            if set(state['artifacts']) != set(paths): raise SigningError('completed signing transaction is missing artifacts')
            return state
        if state.get('status') == 'Blocked': raise SigningError('signing transaction is blocked; retained evidence requires review')
        def command(argv, phase):
            try: result = run(argv, timeout=command_timeout, env=env)
            except OSError as error: raise SigningError(phase + ' tool is unavailable') from error
            state['commands'].append(safe_record(result, phase=phase)); save()
            if result.returncode != 0: raise SigningError(phase + ' failed or exceeded its budget; retained stages preserved')
            return result
        def clear_unfinished(path):
            # Only an already-owned transaction with no completed record may restart a local stage.
            if path.is_symlink(): raise SigningError('unfinished signing output is a symlink')
            if path.is_dir(): shutil.rmtree(path)
            elif path.exists(): path.unlink()
        def sign(path, *, runtime=True, entitlement=False):
            argv = ['/usr/bin/codesign', '--force', '--sign', profile.certificate_sha1 or profile.signing_identity,
                    '--timestamp', '--generate-entitlement-der']
            if profile.signing_keychain: argv += ['--keychain', profile.signing_keychain]
            if runtime: argv += ['--options', 'runtime']
            if entitlement: argv += ['--entitlements', str(entitlements)]
            command([*argv, str(path)], 'codesign')
        if 'appInput' not in state['artifacts']:
            clear_unfinished(paths['appInput'])
            command(['/usr/bin/ditto', str(source_app), str(paths['appInput'])], 'copy-unsigned-app')
            app = paths['appInput']
            sign(app / 'Contents/MacOS/lungfish-cli', entitlement=True)
            tools = app / 'Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Contents/Resources/Tools'
            if tools.is_dir():
                for path in sorted(tools.rglob('*')):
                    if path.is_file() and not path.is_symlink():
                        result = command(['/usr/bin/file', '-b', str(path)], 'inspect-native-tool')
                        if result.stdout.startswith('Mach-O'): sign(path)
            sparkle = app / 'Contents/Frameworks/Sparkle.framework'
            if sparkle.is_dir():
                for relative in ('Versions/B/Updater.app', 'Versions/B/XPCServices/Downloader.xpc',
                                 'Versions/B/XPCServices/Installer.xpc', 'Versions/B/Autoupdate', 'Versions/B/Sparkle'):
                    if (sparkle / relative).exists(): sign(sparkle / relative)
                sign(sparkle)
            sign(app, entitlement=True)
            command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], 'verify-signed-app')
            detail = command(['/usr/bin/codesign', '--display', '--verbose=4', str(app)], 'verify-signing-team')
            if ('TeamIdentifier=' + profile.team_id) not in (detail.stdout + detail.stderr).splitlines():
                raise SigningError('actual signed app Team ID does not match selected profile')
            if smoke_script:
                smoke = ['/bin/bash', str(smoke_script), str(app)]
                if scratch_path: smoke += ['--allowed-swiftpm-fallback', str(scratch_path)]
                command(smoke, 'signed-app-tool-smoke')
            record('appInput')
        if 'appZip' not in state['artifacts']:
            clear_unfinished(paths['appZip'])
            command(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(paths['appInput']), str(paths['appZip'])], 'create-app-notary-zip')
            record('appZip')
        def submit(name, state_name):
            validate(name)
            result = notary(paths[name], transaction_dir / state_name, profile, run=run,
                            timeout=command_timeout, poll_budget=poll_budget, env=env)
            validate(name)
            state['status'] = 'Preparing' if result['status'] == 'Accepted' else result['status']; save()
            return result['status'] == 'Accepted'
        if not submit('appZip', 'notary-app.json'): return state
        if 'signedApp' not in state['artifacts']:
            clear_unfinished(paths['signedApp'])
            signed_app.parent.mkdir(mode=0o700, exist_ok=True)
            validate_private_parent(signed_app.parent / '.private-parent-check')
            command(['/usr/bin/ditto', str(paths['appInput']), str(signed_app)], 'copy-app-for-stapling')
            command(['/usr/bin/xcrun', 'stapler', 'staple', str(signed_app)], 'staple-app')
            command(['/usr/bin/xcrun', 'stapler', 'validate', str(signed_app)], 'validate-app-staple')
            command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(signed_app)], 'verify-stapled-app')
            record('signedApp')
        if 'dmgInput' not in state['artifacts']:
            clear_unfinished(paths['dmgInput'])
            with tempfile.TemporaryDirectory(prefix='dmg-stage-', dir=transaction_dir) as stage:
                command(['/usr/bin/ditto', str(signed_app), str(Path(stage) / source_app.name)], 'stage-dmg-app')
                (Path(stage) / 'Applications').symlink_to('/Applications')
                command(['/usr/bin/hdiutil', 'create', '-volname', volume_name, '-srcfolder', stage, '-format', 'UDZO', str(paths['dmgInput'])], 'create-dmg')
            sign(paths['dmgInput'], runtime=False)
            record('dmgInput')
        if not submit('dmgInput', 'notary-dmg.json'): return state
        if 'dmg' not in state['artifacts']:
            clear_unfinished(dmg)
            shutil.copyfile(paths['dmgInput'], dmg)
            command(['/usr/bin/xcrun', 'stapler', 'staple', str(dmg)], 'staple-dmg')
            command(['/usr/bin/xcrun', 'stapler', 'validate', str(dmg)], 'validate-dmg-staple')
            command(['/usr/bin/codesign', '--verify', '--strict', str(dmg)], 'verify-stapled-dmg')
            record('dmg')
        state['status'] = 'Accepted'; save()
        return state
    finally: os.close(lock)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source-app', 'receipt', 'signed-app', 'dmg', 'transaction-dir', 'entitlements'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('repository', 'signing-identity', 'team-id', 'notary-profile', 'volume-name', 'public-key'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--signing-keychain'); parser.add_argument('--certificate-sha1')
    parser.add_argument('--notary-keychain'); parser.add_argument('--sparkle-account', default='ed25519')
    parser.add_argument('--command-timeout', type=float, default=180)
    parser.add_argument('--poll-budget', type=float, default=600)
    parser.add_argument('--smoke-script', type=Path, required=True)
    parser.add_argument('--scratch-path', type=Path)
    args = parser.parse_args()
    try:
        profile = ReleaseProfile(args.repository, args.signing_identity, args.team_id, args.notary_profile,
                                 args.signing_keychain, args.certificate_sha1, args.notary_keychain, args.sparkle_account, 2)
        parse_profile(profile_payload(profile))
        state = sign_and_notarize(args.source_app, args.receipt, args.signed_app, args.dmg, args.transaction_dir,
                                 profile, entitlements=args.entitlements, volume_name=args.volume_name,
                                 public_key=args.public_key, command_timeout=args.command_timeout, poll_budget=args.poll_budget,
                                 smoke_script=args.smoke_script, scratch_path=args.scratch_path)
    except (SigningError, NotaryError, ProfileError, OSError) as error:
        print('Signing transaction retained: ' + str(error)); return 76
    print(json.dumps(dict(status=state['status'], transaction=str(args.transaction_dir))))
    return {'Accepted':0, 'Invalid':2, 'In Progress':75, 'AmbiguousUpload':76}.get(state['status'], 76)


if __name__ == '__main__': raise SystemExit(main())
