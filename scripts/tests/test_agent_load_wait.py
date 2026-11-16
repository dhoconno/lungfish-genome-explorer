"""Tests for the load wait that four agent types carry (O177 ballot 3 Q7).

lge-lane, lge-lane-opus, lge-fix and lge-land wait for a load under 40 with one until-loop on `sysctl -n vm.loadavg`.
sysctl prints the averages in braces, as `{ 4.90 3.54 2.85 }`, so field 1 is the brace and field 2 the 1-minute load.
Each run gives the loop a stand-in sysctl and sleep on PATH, so no test waits.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

TYPES = Path(__file__).parents[2] / '.claude' / 'agents'
NAMES = ('lge-lane', 'lge-lane-opus', 'lge-fix', 'lge-land')
LOOP = re.compile(r"`(until sysctl -n vm\.loadavg [^`]+)`")
# A sysctl that logs its call and prints the next line of LOADS, and a sleep that logs its argument and returns at once.
FAKE_SYSCTL = '#!/bin/sh\necho x >> "$CALLS"\nn=$(wc -l < "$CALLS" | tr -d " ")\nsed -n "${n}p" "$LOADS"\n'
FAKE_SLEEP = '#!/bin/sh\necho "$1" >> "$SLEEPS"\n'


def loops():
    """The load loops each type file gives, by type."""
    return {name: LOOP.findall((TYPES / ('%s.md' % name)).read_text()) for name in NAMES}


class LoadWaitTests(unittest.TestCase):
    def test_each_building_type_gives_one_loop_and_the_same_one(self):
        found = loops()
        for name in NAMES:
            with self.subTest(name):
                self.assertEqual(len(found[name]), 1, '%s.md gives no load loop' % name)
                self.assertIn('never repeated `uptime` calls', (TYPES / ('%s.md' % name)).read_text())
        self.assertEqual(len({loop for name in NAMES for loop in found[name]}), 1)

    def run_loop(self, loads):
        """Runs the loop of lge-lane with one LOADS line a check, and returns the sysctl calls and the sleeps."""
        found = loops()['lge-lane']
        self.assertTrue(found, 'lge-lane.md gives no load loop')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'bin').mkdir()
            for name, text in (('sysctl', FAKE_SYSCTL), ('sleep', FAKE_SLEEP)):
                (root / 'bin' / name).write_text(text)
                (root / 'bin' / name).chmod(0o755)
            (root / 'loads').write_text(''.join(line + '\n' for line in loads))
            env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'],
                       CALLS=str(root / 'calls'), LOADS=str(root / 'loads'), SLEEPS=str(root / 'sleeps'))
            done = subprocess.run(['bash', '-c', found[0]], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(done.returncode, 0, done.stderr)
            sleeps = root / 'sleeps'
            return (len((root / 'calls').read_text().splitlines()),
                    len(sleeps.read_text().split()) if sleeps.exists() else 0)

    def test_the_loop_waits_while_the_one_minute_load_is_40_or_more(self):
        loads = ['{ 55.20 30.10 20.00 }', '{ 40.00 30.10 20.00 }', '{ 39.99 30.10 20.00 }']
        self.assertEqual(self.run_loop(loads), (3, 2))

    def test_the_loop_reads_the_one_minute_field_and_not_the_brace_or_the_others(self):
        self.assertEqual(self.run_loop(['{ 12.50 61.00 70.00 }']), (1, 0))


if __name__ == '__main__':
    unittest.main()
