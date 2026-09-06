"""Bound tool process groups. Closed stdin does not prevent macOS Keychain dialogs."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


class BoundedResult(subprocess.CompletedProcess):
    def __init__(self, argv, returncode, stdout, stderr, timed_out, wall_seconds):
        super().__init__(argv, returncode, stdout, stderr)
        self.timed_out, self.wall_seconds = timed_out, wall_seconds


def run_bounded(argv, *, timeout, env=None, cwd=None, terminate_grace=1.0):
    if timeout <= 0 or terminate_grace < 0: raise ValueError('process budgets must be positive')
    environment = dict(os.environ if env is None else env)
    environment.update(GIT_TERMINAL_PROMPT='0', GH_PROMPT_DISABLED='1')
    start = time.monotonic()
    process = subprocess.Popen(argv, cwd=cwd, env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors='replace', start_new_session=True)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException as error:
        timed_out = isinstance(error, subprocess.TimeoutExpired)
        try: os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        # Even if the leader exits on TERM, a descendant may ignore it.
        try: process.wait(timeout=terminate_grace)
        except subprocess.TimeoutExpired: pass
        if terminate_grace: time.sleep(min(terminate_grace, .05))
        try: os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        stdout, stderr = process.communicate(timeout=max(1, terminate_grace))
        if not timed_out: raise
    return BoundedResult(argv, 124 if timed_out else process.returncode, stdout, stderr, timed_out, time.monotonic() - start)


def safe_record(result, *, phase):
    """Only allowlisted process metadata is suitable for persistent credential logs."""
    return dict(phase=phase, executable=Path(result.args[0]).name, exitStatus=result.returncode, timedOut=getattr(result, 'timed_out', False), wallTimeSeconds=getattr(result, 'wall_seconds', None))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=float, required=True)
    parser.add_argument('--phase', required=True)
    parser.add_argument('--public-stdout', action='store_true', help='Forward successful public protocol output; never use for secret-bearing commands')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command: parser.error('a command is required')
    try: result = run_bounded(command, timeout=args.timeout)
    except OSError:
        print(json.dumps(dict(phase=args.phase, exitStatus=127, error='tool unavailable')))
        return 127
    print(json.dumps(safe_record(result, phase=args.phase)), file=sys.stderr if args.public_stdout else sys.stdout)
    if args.public_stdout and result.returncode == 0:
        sys.stdout.write(result.stdout)
    return result.returncode


if __name__ == '__main__': raise SystemExit(main())
