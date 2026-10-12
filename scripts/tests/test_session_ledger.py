"""Tests for scripts/llm/session_ledger.py, the per-agent usage ledger of Claude Code sessions.

Each test writes a small synthetic session under a temporary transcript root (a main transcript, a subagent
transcript and its meta file) and checks what the ledger counts, prices and flags. No real transcript is read.
"""
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

LEDGER = Path(__file__).parents[1] / 'llm' / 'session_ledger.py'
SID = '11111111-2222-3333-4444-555555555555'
AID = 'a0123456789abcdef'
T0 = datetime(2026, 10, 11, 13, 0, tzinfo=timezone.utc).timestamp()


def load_ledger():
    spec = importlib.util.spec_from_file_location('session_ledger', LEDGER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stamp(seconds):
    return datetime.fromtimestamp(T0 + seconds, timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')


def usage(inp=0, write=0, read=0, out=0, w1h=0):
    return {'input_tokens': inp, 'cache_creation_input_tokens': write, 'cache_read_input_tokens': read,
            'output_tokens': out,
            'cache_creation': {'ephemeral_5m_input_tokens': write - w1h, 'ephemeral_1h_input_tokens': w1h}}


def bash(tool_id, command):
    return {'type': 'tool_use', 'id': tool_id, 'name': 'Bash', 'input': {'command': command, 'timeout': 270000}}


class Transcript:
    """Builds one JSONL transcript in the shape Claude Code writes."""

    def __init__(self, path, agent_id=None):
        self.path = Path(path)
        self.agent_id = agent_id
        self.entries = []

    def add(self, kind, seconds, message, **extra):
        entry = {'type': kind, 'uuid': '%s-%d' % (self.agent_id or 'main', len(self.entries)),
                 'timestamp': stamp(seconds), 'message': message}
        if self.agent_id:
            entry.update(agentId=self.agent_id, isSidechain=True)
        entry.update(extra)
        self.entries.append(entry)
        return entry

    def prompt(self, seconds, text):
        return self.add('user', seconds, {'role': 'user', 'content': text})

    def turn(self, seconds, message_id, use, content, model='claude-sonnet-5-5', stop='tool_use'):
        return self.add('assistant', seconds, {'id': message_id, 'model': model, 'role': 'assistant',
                                               'content': content, 'usage': use, 'stop_reason': stop})

    def result(self, seconds, tool_id, text, error=False, tool_use_result=None):
        extra = {'toolUseResult': tool_use_result} if tool_use_result else {}
        block = {'type': 'tool_result', 'tool_use_id': tool_id, 'content': text, 'is_error': error}
        return self.add('user', seconds, {'role': 'user', 'content': [block]}, **extra)

    def save(self, *paths):
        text = ''.join(json.dumps(e) + '\n' for e in self.entries)
        for p in paths or (self.path,):
            Path(p).parent.mkdir(parents=True, exist_ok=True)
            Path(p).write_text(text)


class LedgerTestCase(unittest.TestCase):
    def setUp(self):
        self.ledger = load_ledger()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.main = Transcript(self.root / 'proj' / (SID + '.jsonl'))
        self.sub = Transcript(self.root / 'proj' / SID / 'subagents' / ('agent-%s.jsonl' % AID), AID)
        meta = self.root / 'proj' / SID / 'subagents' / ('agent-%s.meta.json' % AID)
        meta.parent.mkdir(parents=True, exist_ok=True)
        meta.write_text(json.dumps({'description': 'Lane A1 small fixes', 'model': 'sonnet'}))

    def run_ledger(self, now_seconds=None):
        self.main.save()
        self.sub.save()
        now = T0 + now_seconds if now_seconds is not None else None
        return self.ledger.load_session(SID, str(self.root), now, 12)

    @staticmethod
    def agent(session, key):
        return next(a for a in session['agents'] if a['key'] == key)


class UsageAndCostTests(LedgerTestCase):
    def test_usage_repeated_per_content_block_counts_once_with_largest_values(self):
        self.sub.prompt(0, 'brief')
        self.sub.turn(5, 'msg_1', usage(read=50000, write=2000, out=10), [{'type': 'thinking', 'thinking': ''}])
        self.sub.turn(6, 'msg_1', usage(read=50000, write=2000, out=500), [bash('t1', 'ls')])
        self.sub.result(7, 't1', 'a b c')
        lane = self.agent(self.run_ledger(), AID)
        self.assertEqual(lane['turns'], 1)
        self.assertEqual(lane['tokens']['out'], 500)
        self.assertEqual(lane['tokens']['cr'], 50000)

    def test_cost_uses_the_price_of_the_turn_model(self):
        self.sub.prompt(0, 'brief')
        self.sub.turn(5, 'msg_1', usage(inp=1000, write=1000000, read=1000000, out=100000), [], stop='end_turn')
        lane = self.agent(self.run_ledger(), AID)
        # sonnet: input 2.00, 5-minute cache write 2.50, cache read 0.20, output 10.00 dollars per million tokens
        self.assertAlmostEqual(lane['cost'], 0.002 + 2.5 + 0.2 + 1.0, places=6)
        self.assertEqual(self.ledger.price_for('claude-opus-5-5'), self.ledger.PRICES['opus'])
        self.assertIsNone(self.ledger.price_for('unknown-model'))

    def test_main_transcript_copied_into_two_project_folders_counts_once(self):
        self.main.prompt(0, 'start')
        self.main.turn(5, 'msg_m1', usage(read=30000, write=1000, out=50, w1h=1000), [bash('m1', 'ls')])
        self.main.result(6, 'm1', 'x')
        self.main.save(self.main.path, self.root / 'other-proj' / (SID + '.jsonl'))
        self.sub.save()
        session = self.ledger.load_session(SID, str(self.root), None, 12)
        main = self.agent(session, 'main')
        self.assertEqual(len(session['mains']), 2)
        self.assertEqual(main['turns'], 1)
        self.assertEqual(main['tools'], {'Bash': 1})

    def test_large_cache_write_after_a_long_gap_is_a_rebuild(self):
        self.sub.prompt(0, 'brief')
        self.sub.turn(5, 'msg_1', usage(read=200000, write=1000, out=50), [bash('t1', 'sleep_free_wait')])
        self.sub.result(300, 't1', 'done')
        self.sub.turn(365, 'msg_2', usage(read=0, write=201000, out=50), [], stop='end_turn')
        lane = self.agent(self.run_ledger(), AID)
        self.assertEqual(len(lane['rebuilds']), 1)
        rebuild = lane['rebuilds'][0]
        self.assertEqual(rebuild['tokens'], 201000)
        self.assertEqual(rebuild['gap'], 360)
        self.assertEqual(rebuild['cause'], 'tool result')


class ToolCallTests(LedgerTestCase):
    def test_worktree_guard_rejection_is_counted_with_a_path_free_signature(self):
        self.sub.prompt(0, 'brief')
        self.sub.turn(5, 'msg_1', usage(read=40000, out=20), [bash('t1', 'cd /x && git status')])
        self.sub.result(6, 't1', 'This agent is isolated in the worktree /Users/x/wt but this command names git in '
                                  'a form too complex to verify', error=True)
        lane = self.agent(self.run_ledger(), AID)
        self.assertEqual(lane['guard_rejections'], 1)
        self.assertEqual(lane['fail_count'], 1)
        self.assertTrue(lane['fails'][0]['sig'].startswith('This agent is isolated in the worktree <path> but'))
        self.assertEqual(self.ledger.err_signature('Exit code 128\nfatal: bad'), 'Exit code N')

    def test_builds_and_commits_are_found_but_not_a_search_for_the_words(self):
        self.sub.prompt(0, 'brief')
        self.sub.turn(5, 'msg_1', usage(read=40000, out=20), [
            bash('t1', 'export DEVELOPER_DIR=/x; swift build --skip-update --build-tests'),
            bash('t2', "rg -n 'swift build' notes.md"),
            bash('t3', 'git commit -m "Fix the parser"')])
        self.sub.result(160, 't1', 'Build complete! (153.00s)')
        self.sub.result(161, 't2', 'notes.md:3:swift build')
        self.sub.result(162, 't3', '[branch abc] Fix the parser')
        lane = self.agent(self.run_ledger(), AID)
        self.assertEqual([b['cmd'][-13:] for b in lane['builds']], ['--build-tests'])
        self.assertEqual(lane['builds'][0]['sec'], 155)
        self.assertEqual(lane['commits'], 1)

    def test_call_without_result_is_a_hang_only_while_the_session_is_live(self):
        self.sub.prompt(0, 'brief')
        self.sub.turn(60, 'msg_1', usage(read=40000, out=20), [bash('t1', 'python3 -')])
        live = self.agent(self.run_ledger(now_seconds=60 + 1200), AID)
        self.assertEqual(len(live['pending']), 1)
        self.assertTrue(live['pending'][0]['hang'])
        ended = self.agent(self.run_ledger(now_seconds=60 + 7200), AID)
        self.assertFalse(ended['pending'][0]['hang'])


class OrchestrationTests(LedgerTestCase):
    def test_spawn_message_and_meta_are_mapped_onto_the_subagent(self):
        self.main.prompt(0, 'start the phase')
        spawn = {'type': 'tool_use', 'id': 'm1', 'name': 'Agent',
                 'input': {'description': 'Lane A1 small fixes', 'prompt': 'Read SCR/briefs/lane-A1.md',
                           'model': 'sonnet', 'isolation': 'worktree', 'subagent_type': 'general-purpose'}}
        self.main.turn(5, 'msg_m1', usage(read=30000, write=1000, out=50, w1h=1000), [spawn])
        self.main.result(6, 'm1', 'launched', tool_use_result={'agentId': AID, 'status': 'async_launched'})
        send = {'type': 'tool_use', 'id': 'm2', 'name': 'SendMessage', 'input': {'to': AID, 'message': 'Rule update'}}
        self.main.turn(100, 'msg_m2', usage(read=31000, write=500, out=40, w1h=500), [send])
        self.main.result(101, 'm2', 'sent')
        self.sub.prompt(7, 'Read SCR/briefs/lane-A1.md')
        self.sub.turn(10, 'msg_1', usage(read=40000, write=3000, out=20), [bash('t1', 'ls')])
        self.sub.result(11, 't1', 'x')
        self.sub.add('user', 102, {'role': 'user', 'content': 'The coordinator sent a message while you were working'},
                     isMeta=True)
        self.sub.turn(104, 'msg_2', usage(read=43000, write=500, out=20), [], stop='end_turn')
        session = self.run_ledger()
        main, lane = self.agent(session, 'main'), self.agent(session, AID)
        self.assertEqual(main['spawns'][0]['agentId'], AID)
        self.assertEqual(main['sends'], {AID: 1})
        self.assertEqual(lane['label'], 'Lane A1 small fixes')
        self.assertEqual(lane['role'], 'lane')
        self.assertEqual(lane['spawn']['isolation'], 'worktree')
        self.assertEqual(lane['resumes'], 1)
        self.assertEqual(len(lane['resume_segments']), 1)
        self.assertFalse(lane['resume_segments'][0]['idle'])

    def test_roles_follow_the_agent_descriptions(self):
        role = self.ledger.role_of
        self.assertEqual(role('Lane A6 executor core', 'sub'), 'lane')
        self.assertEqual(role('Lane B3 continuation under R1', 'sub'), 'lane')
        self.assertEqual(role('Fix agent for lane A6', 'sub'), 'fix')
        self.assertEqual(role('Fix agent for TF-W, fresh', 'sub'), 'fix')
        self.assertEqual(role('Land S1, A4, A5, A7', 'sub'), 'landing')
        self.assertEqual(role('Landing 6a of Phase 2.8', 'sub'), 'landing')
        self.assertEqual(role('Swift review of lane S1', 'sub'), 'review')
        self.assertEqual(role('BIO check of B6 fix 3', 'sub'), 'review')
        self.assertEqual(role('Architecture expert inventory', 'sub'), 'design')
        self.assertEqual(role('R1 vote, QA expert', 'sub'), 'design')
        self.assertEqual(role('LLM monitor checkpoint 3', 'sub'), 'llm')
        self.assertEqual(role('Monitor checkpoint 2', 'sub'), 'llm')
        self.assertEqual(role('anything', 'main'), 'main')


class CommandLineTests(LedgerTestCase):
    def test_writes_markdown_and_json_without_message_text(self):
        self.main.prompt(0, 'start')
        self.main.turn(5, 'msg_m1', usage(read=30000, write=1000, out=50, w1h=1000),
                       [{'type': 'text', 'text': 'SECRET-ASSISTANT-TEXT'}, bash('m1', 'ls')])
        self.main.result(6, 'm1', 'SECRET-RESULT-TEXT')
        self.sub.prompt(7, 'brief')
        self.sub.turn(10, 'msg_1', usage(read=40000, write=3000, out=20), [bash('t1', 'ls')])
        self.sub.result(11, 't1', 'SECRET-RESULT-TEXT')
        self.main.save()
        self.sub.save()
        md, js = self.root / 'ledger.md', self.root / 'ledger.json'
        run = subprocess.run([sys.executable, str(LEDGER), '--root', str(self.root), '--md', str(md),
                              '--json', str(js), '--now', stamp(60), SID], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        text = md.read_text()
        self.assertIn('# Session ledger', text)
        self.assertIn('Lane A1 small fixes', text)
        data = json.loads(js.read_text())
        self.assertEqual(data[0]['session'], SID)
        self.assertEqual(len(data[0]['agents']), 2)
        for output in (text, js.read_text()):
            self.assertNotIn('SECRET-ASSISTANT-TEXT', output)
            self.assertNotIn('SECRET-RESULT-TEXT', output)


if __name__ == '__main__':
    unittest.main()
