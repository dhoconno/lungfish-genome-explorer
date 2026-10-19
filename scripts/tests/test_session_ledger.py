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
BID = 'b0123456789abcdef'
T0 = datetime(2026, 10, 11, 13, 0, tzinfo=timezone.utc).timestamp()


def load_ledger():
    spec = importlib.util.spec_from_file_location('session_ledger', LEDGER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stamp(seconds):
    return datetime.fromtimestamp(T0 + seconds, timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')


def usage(inp=0, write=0, read=0, out=0, w1h=0, think=0):
    use = {'input_tokens': inp, 'cache_creation_input_tokens': write, 'cache_read_input_tokens': read,
           'output_tokens': out,
           'cache_creation': {'ephemeral_5m_input_tokens': write - w1h, 'ephemeral_1h_input_tokens': w1h}}
    if think:
        use['output_tokens_details'] = {'thinking_tokens': think}
    return use


def bash(tool_id, command):
    return {'type': 'tool_use', 'id': tool_id, 'name': 'Bash', 'input': {'command': command, 'timeout': 270000}}


def agent_call(tool_id, description, **settings):
    return {'type': 'tool_use', 'id': tool_id, 'name': 'Agent',
            'input': dict({'description': description, 'prompt': 'Read SCR/briefs/%s.md' % tool_id}, **settings)}


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

    def test_message_without_a_final_usage_is_charged_its_content_estimate(self):
        # Claude Code 2.1.295 writes most subagent messages with stop_reason None and the usage of message_start.
        self.sub.prompt(0, 'brief')
        thinking = {'type': 'thinking', 'thinking': '', 'signature': 'x' * 32000}
        self.sub.turn(5, 'msg_1', usage(read=50000, write=2000, out=5), [thinking], stop=None)
        self.sub.turn(6, 'msg_1', usage(read=50000, write=2000, out=5), [bash('t1', 'ls')], stop=None)
        self.sub.result(7, 't1', 'a b c')
        lane = self.agent(self.run_ledger(), AID)
        tool_input = len(json.dumps({'command': 'ls', 'timeout': 270000})) / 3.5
        expected = int((32000 / self.ledger.SIG_CHARS_PER_TOKEN + tool_input) / self.ledger.EST_BIAS)
        self.assertEqual(lane['tokens']['out'], expected)
        self.assertEqual(lane['est_out'], {'msgs': 1, 'tokens': expected - 5})

    def test_message_with_a_stop_reason_keeps_its_recorded_output(self):
        self.sub.prompt(0, 'brief')
        thinking = {'type': 'thinking', 'thinking': '', 'signature': 'x' * 32000}
        self.sub.turn(5, 'msg_1', usage(read=50000, write=2000, out=700), [thinking, bash('t1', 'ls')])
        self.sub.result(6, 't1', 'a b c')
        lane = self.agent(self.run_ledger(), AID)
        self.assertEqual(lane['tokens']['out'], 700)
        self.assertEqual(lane['est_out'], {'msgs': 0, 'tokens': 0})

    def test_cost_uses_the_price_of_the_turn_model(self):
        self.sub.prompt(0, 'brief')
        self.sub.turn(5, 'msg_1', usage(inp=1000, write=1000000, read=1000000, out=100000), [], stop='end_turn')
        lane = self.agent(self.run_ledger(), AID)
        # sonnet: input 2.00, 5-minute cache write 2.50, cache read 0.10, output 10.00 dollars per million tokens
        self.assertAlmostEqual(lane['cost'], 0.002 + 2.5 + 0.1 + 1.0, places=6)
        self.assertEqual(self.ledger.price_for('claude-opus-5-5'), self.ledger.PRICES['opus'])
        self.assertIsNone(self.ledger.price_for('unknown-model'))

    def record_cost(self, model, inp, out, read, write_5m, write_1h):
        """The ledger's cost for the tokens of one model in Claude Code's cost-state record of session 8abd61c3 (2.12
        session 1, written by 2.1.299). The record does not split its cache writes, so the 1 hour share is the ledger's."""
        use = {'in': inp, 'out': out, 'cr': read, 'cc': write_5m + write_1h, 'w5m': write_5m, 'w1h': write_1h}
        return self.ledger.cost_of(use, model)[0]

    def test_opus_prices_are_the_catalog_prices_and_reproduce_the_cost_state_record(self):
        # Opus 5.5 is tier_4_20_cache_read_0_20 in the model catalog of Claude Code 2.1.286, 2.1.295 and 2.1.299
        self.assertEqual(self.ledger.PRICES['opus'], {'in': 4.0, 'out': 20.0, 'read': 0.20, 'w5m': 5.0, 'w1h': 8.0})
        self.assertAlmostEqual(self.record_cost('claude-opus-5-5', 19338, 8046216, 1082615627, 19500214, 2026932),
                               491.24, delta=0.01)

    def test_sonnet_prices_are_the_2_1_299_catalog_prices_and_reproduce_the_cost_state_record(self):
        # Sonnet 5.5 is tier_2_10_cache_read_0_10 in Claude Code 2.1.299 (tier_2_10 with cache read 0.20 in 2.1.295 and older)
        self.assertEqual(self.ledger.PRICES['sonnet'], {'in': 2.0, 'out': 10.0, 'read': 0.10, 'w5m': 2.5, 'w1h': 4.0})
        self.assertAlmostEqual(self.record_cost('claude-sonnet-5-5', 9716, 16030762, 772615054, 33742412, 0),
                               321.94, delta=0.01)

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
        self.assertEqual(role('Census of gap sites', 'sub', 'llm-efficiency-monitor'), 'llm')
        self.assertEqual(role('Write next ten lane briefs', 'sub'), 'design')
        self.assertEqual(role('Brief writer 6 (ten lanes)', 'sub'), 'design')
        self.assertEqual(role('anything', 'main'), 'main')


class RoleRuleTests(LedgerTestCase):
    """Roles for the descriptions a manager gave its agents in 2.12 (monitor cp5 action 9, cp6 action 6, 2.11 proposal 11)."""

    def roles(self, *labels):
        return [self.ledger.role_of(label, 'sub') for label in labels]

    def test_fix_agent_labels_are_fix_agents(self):
        self.assertEqual(self.roles('Fix agent 12.31 TaxTriage parity prefs leak fix', 'Fix agent 12.13 review fixes 1-6',
                                    'Fix agent 12.07 ruling applied'), ['fix', 'fix', 'fix'])

    def test_a_lane_label_naming_review_fixes_is_a_fix(self):
        self.assertEqual(self.roles('Lane 12.15 review fixes', 'Lane 12.31 M4 review fixes',
                                    'Lane 12.39 branch 1 review fix'), ['fix', 'fix', 'fix'])
        # other lane work stays lane, among it a continuation that applies a ruling or publishes and fixes
        self.assertEqual(self.roles('Lane 12.27 c2 ruling applied', 'Lane 12.06 c3 staged publish + fixes',
                                    'Lane 12.17 M2 real-tool parity'), ['lane', 'lane', 'lane'])

    def test_a_diagnose_label_is_a_fix_but_a_diagnosis_by_an_expert_is_design(self):
        self.assertEqual(self.roles('Diagnose NAO-MGS cancel test flake', 'Diagnose the Viral Recon open timeout'),
                         ['fix', 'fix'])
        self.assertEqual(self.roles('Expert diagnosis of the cancel flake'), ['design'])

    def test_a_ruling_is_a_ruling_whatever_its_first_word(self):
        self.assertEqual(self.roles(
            'Ruling on the export shape', 'ARCH ruling export shape and census', 'BIO ruling 12.31 G3 with ARCH line',
            'UX ruling 12.17 refusal words, M2 states', 'QA ruling on A46 M3 parity masks', 'UX words ruling for lane 12.26',
            'ARCH ruling on viewer graphics B10'), ['ruling'] * 7)
        # work that only mentions a ruling keeps its role: a brief writer, a plan commit, a review, a ruling applied
        self.assertEqual(self.roles('Brief writer W8 export ruling', 'Plan docs commit: rulings, O12, keys',
                                    'Review of the ARCH ruling', 'Lane 12.27 c2 ruling applied'),
                         ['design', 'design', 'review', 'lane'])

    def test_release_operators_are_operators_but_lane_milestones_are_not(self):
        self.assertEqual(self.roles(
            'Live window 1 operator', 'Window 1 part A operator', 'M3: push main, publish 2026.10.20',
            'M3 rerun: resume publish, finish', 'Q36 M3 push main and publish', 'Q66 reruns at H2 and M2 package',
            'Package the candidate', 'Publish Preview 2026.10.21'), ['operator'] * 8)
        # a milestone of a lane, a review or a plan of the release and a lane that publishes keep their roles
        self.assertEqual(self.roles('Lane A51 M2-M3 continuation', 'A48 M3 fix group B', 'QA review of the package step',
                                    'Q66 M1 plan (final candidate)', 'Lane 12.06 c3 staged publish + fixes'),
                         ['lane', 'lane', 'review', 'design', 'lane'])


class SpendByRoleModelAndEffortTests(LedgerTestCase):
    """The model and effort each spawn asked for, beside the model its turns ran on, in two tables of the report."""
    LANE = '| lane | claude-sonnet-5-5 | max | 1 | 2 | 30K | 16K | 0 | 53.3 | 0 | 0.91 |'
    REVIEW = '| review | claude-opus-5-5 | %s | 1 | 2 | 16K | 5K | 8K | 81.8 | 1 | 0.78 |'
    MAIN = '| main | claude-opus-5-5 | unset | 1 | 2 | 90 | 0 | 0 | 0.0 | 0 | 0.03 |'
    OPUS, SONNET = 'claude-opus-5-5', 'claude-sonnet-5-5'

    def write_meta(self, agent_id, **fields):
        meta = self.root / 'proj' / SID / 'subagents' / ('agent-%s.meta.json' % agent_id)
        meta.write_text(json.dumps(fields))

    def write_session(self, review_settings=None):
        """The main transcript spawns a lane with model and effort set and a review with `review_settings`, which are
        none by default. The lane's turns carry recorded thinking. The review's second turn kept no final usage, and
        its thinking is stored as text."""
        review_settings = review_settings or {}
        self.main.prompt(0, 'start the phase')
        self.main.turn(5, 'msg_m1', usage(read=30000, write=1000, out=50, w1h=1000),
                       [agent_call('m1', 'Lane A1 small fixes', model='sonnet', effort='max',
                                   subagent_type='lge-worker')], model=self.OPUS)
        self.main.result(6, 'm1', 'launched', tool_use_result={'agentId': AID, 'status': 'async_launched'})
        self.main.turn(8, 'msg_m2', usage(read=31000, write=500, out=40, w1h=500),
                       [agent_call('m2', 'Swift review of lane A1', subagent_type='general-purpose',
                                   **review_settings)], model=self.OPUS)
        self.main.result(9, 'm2', 'launched', tool_use_result={'agentId': BID, 'status': 'async_launched'})
        self.sub.prompt(7, 'brief of the lane')
        self.sub.turn(10, 'msg_a1', usage(read=1000000, write=100000, out=20000, think=12000), [bash('t1', 'ls')])
        self.sub.result(11, 't1', 'x')
        self.sub.turn(20, 'msg_a2', usage(read=1100000, write=60000, out=10000, think=4000), [], stop='end_turn')
        review = Transcript(self.root / 'proj' / SID / 'subagents' / ('agent-%s.jsonl' % BID), BID)
        review.prompt(9, 'brief of the review')
        review.turn(12, 'msg_b1', usage(read=500000, write=40000, out=8000, think=5000), [bash('u1', 'ls')],
                    model=self.OPUS)
        review.result(13, 'u1', 'x')
        review.turn(30, 'msg_b2', usage(read=520000, write=10000, out=5), [{'type': 'thinking', 'thinking': 'x' * 36000}],
                    model=self.OPUS, stop=None)
        for transcript in (self.main, self.sub, review):
            transcript.save()
        self.write_meta(AID, description='Lane A1 small fixes', agentType='lge-worker', model='sonnet', effort='max')
        self.write_meta(BID, description='Swift review of lane A1', agentType='general-purpose', **review_settings)
        return self.ledger.load_session(SID, str(self.root), None, 12)

    @staticmethod
    def section(text, heading):
        """The table rows of one section of the report, without the header row."""
        body = text.split('### %s\n' % heading)[1].split('\n### ')[0]
        return [line for line in body.splitlines() if line.startswith('| ')][1:]

    def test_rows_of_both_sections(self):
        session = self.write_session()
        estimated = int(36000 / 4 / self.ledger.EST_BIAS)  # thinking text at 4 characters a token, less the bias
        rows = session['by_role_model_effort']
        self.assertEqual(
            [(x['role'], x['model'], x['effort'], x['agents'], x['turns'], x['out'], x['think_recorded'],
              x['think_estimated'], x['no_final_usage']) for x in rows],
            [('lane', self.SONNET, 'max', 1, 2, 30000, 16000, 0, 0),
             ('review', self.OPUS, 'unset', 1, 2, 8000 + estimated, 5000, estimated, 1),
             ('main', self.OPUS, 'unset', 1, 2, 90, 0, 0, 0)])
        self.assertAlmostEqual(rows[0]['think_share'], 16000 / 30000)
        self.assertAlmostEqual(rows[1]['think_share'], (5000 + estimated) / (8000 + estimated))
        # opus: input 4.00, 5-minute cache write 5.00, 1-hour write 8.00, cache read 0.20, output 20.00 dollars per million tokens
        self.assertAlmostEqual(rows[1]['cost'], 0.46 + 0.104 + 0.05 + estimated * 20 / 1e6, places=5)
        self.assertAlmostEqual(sum(x['cost'] for x in rows), self.ledger.aggregate(session['agents'])['cost'], places=5)
        self.assertEqual(session['spawns_without_model_or_effort'], [
            {'key': BID, 'label': 'Swift review of lane A1', 'agent_type': 'general-purpose',
             'missing': ['model', 'effort'], 'model': 'unset', 'effort': 'unset', 'ran_on': self.OPUS}])
        self.assertEqual(self.agent(session, AID)['request'],
                         {'model': 'sonnet', 'effort': 'max', 'agent_type': 'lge-worker', 'ran_on': self.SONNET})
        self.assertEqual(self.agent(session, 'main')['request']['effort'], 'unset')
        text = '\n'.join(self.ledger.md_session(session, 12)[0])
        self.assertEqual(self.section(text, 'By role, model and effort'), [self.LANE, self.REVIEW % 'unset', self.MAIN])
        self.assertEqual(self.section(text, 'Spawns without model or effort'), [
            '| %s | Swift review of lane A1 | general-purpose | model and effort | unset | unset | %s |' % (BID, self.OPUS)])

    def test_spawns_with_both_settings_leave_the_second_section_empty(self):
        session = self.write_session({'model': 'opus', 'effort': 'high'})
        text = '\n'.join(self.ledger.md_session(session, 12)[0])
        self.assertEqual(session['spawns_without_model_or_effort'], [])
        self.assertIn('### Spawns without model or effort\n\n- none', text)
        self.assertEqual(self.section(text, 'By role, model and effort'), [self.LANE, self.REVIEW % 'high', self.MAIN])

    def test_requested_settings_come_from_the_spawn_then_the_meta_then_unset(self):
        request = self.ledger.request_of
        meta = {'model': 'opus', 'effort': 'high', 'agentType': 'lge-expert'}
        spawn = {'model': 'sonnet', 'effort': 'max', 'subagent_type': 'lge-worker'}
        self.assertEqual(request({'model': self.OPUS, 'spawn': spawn, 'meta': meta}),
                         {'model': 'sonnet', 'effort': 'max', 'agent_type': 'lge-worker', 'ran_on': self.OPUS})
        self.assertEqual(request({'model': self.OPUS, 'spawn': {'model': None, 'effort': None}, 'meta': meta}),
                         {'model': 'opus', 'effort': 'high', 'agent_type': 'lge-expert', 'ran_on': self.OPUS})
        self.assertEqual(request({'model': self.OPUS, 'meta': {}}),
                         {'model': 'unset', 'effort': 'unset', 'agent_type': 'unset', 'ran_on': self.OPUS})

    def test_a_spawn_missing_one_setting_names_that_setting_and_the_main_transcript_is_no_spawn(self):
        def agent(kind, key, model, effort):
            return {'kind': kind, 'key': key, 'label': 'Agent ' + key, 'request': {
                'model': model, 'effort': effort, 'agent_type': 'lge-worker', 'ran_on': self.OPUS}}
        rows = self.ledger.spawns_without_model_or_effort([
            agent('main', 'main', 'unset', 'unset'), agent('sub', 'a1', 'opus', 'unset'),
            agent('sub', 'a2', 'unset', 'max'), agent('sub', 'a3', 'opus', 'max')])
        self.assertEqual([(x['key'], x['missing']) for x in rows], [('a1', ['effort']), ('a2', ['model'])])

    def test_json_carries_the_two_tables_beside_the_markdown(self):
        self.write_session()
        md, js = self.root / 'ledger.md', self.root / 'ledger.json'
        run = subprocess.run([sys.executable, str(LEDGER), '--root', str(self.root), '--md', str(md),
                              '--json', str(js), '--now', stamp(60), SID], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        data = json.loads(js.read_text())[0]
        self.assertEqual([(x['role'], x['model'], x['effort']) for x in data['by_role_model_effort']],
                         [('lane', self.SONNET, 'max'), ('review', self.OPUS, 'unset'), ('main', self.OPUS, 'unset')])
        self.assertEqual([(x['key'], x['missing']) for x in data['spawns_without_model_or_effort']],
                         [(BID, ['model', 'effort'])])
        self.assertEqual(self.section(md.read_text(), 'By role, model and effort'),
                         [self.LANE, self.REVIEW % 'unset', self.MAIN])


class ManagerEffortTests(LedgerTestCase):
    """The manager has no spawn, so its effort is the `effort` field of its own transcript (2.11 cp7 proposal 10)."""
    OPUS = 'claude-opus-5-5'

    def write_session(self, efforts):
        self.main.prompt(0, 'start the phase')
        for i, effort in enumerate(efforts):
            entry = self.main.turn(5 + 10 * i, 'msg_m%d' % i, usage(read=30000, write=1000, out=50, w1h=1000), [],
                                   model=self.OPUS, stop='end_turn')
            if effort:
                entry['effort'] = effort
        self.sub.prompt(7, 'brief')
        # a subagent's field reads the session's setting on every message, not the setting its spawn asked for
        self.sub.turn(10, 'msg_1', usage(read=40000, write=3000, out=20), [], stop='end_turn')['effort'] = 'xhigh'
        return self.run_ledger()

    def test_main_effort_is_the_most_common_value_in_its_transcript(self):
        session = self.write_session(['xhigh', 'xhigh', 'high'])
        main = self.agent(session, 'main')
        self.assertEqual(main['transcript_effort'], 'xhigh')
        self.assertEqual(main['request']['effort'], 'xhigh')
        self.assertIn(('main', self.OPUS, 'xhigh'),
                      [(x['role'], x['model'], x['effort']) for x in session['by_role_model_effort']])

    def test_a_subagent_keeps_its_spawn_setting_whatever_its_own_field_reads(self):
        session = self.write_session(['xhigh'])
        lane = self.agent(session, AID)
        self.assertEqual(lane['transcript_effort'], 'xhigh')
        self.assertEqual(lane['request']['effort'], 'unset')

    def test_a_main_transcript_with_no_effort_field_stays_unset(self):
        session = self.write_session([None])
        main = self.agent(session, 'main')
        self.assertIsNone(main['transcript_effort'])
        self.assertEqual(main['request']['effort'], 'unset')


class PathsTests(LedgerTestCase):
    """`--paths` prints where a session's transcripts and subagents folder are (2.12 proposal 14), so no helper types a
    project folder."""

    def run_paths(self, *targets):
        return subprocess.run([sys.executable, str(LEDGER), '--root', str(self.root), '--paths'] + list(targets),
                              capture_output=True, text=True)

    def test_paths_names_the_transcript_and_the_subagents_folder(self):
        self.main.prompt(0, 'start')
        self.sub.prompt(7, 'brief')
        self.main.save()
        self.sub.save()
        run = self.run_paths(SID)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stdout.splitlines(), [
            'session ' + SID, 'transcript ' + str(self.main.path),
            'subagents %s 1' % (self.root / 'proj' / SID / 'subagents')])

    def test_paths_lists_every_project_folder_that_holds_the_session(self):
        other = self.root / 'other-proj' / (SID + '.jsonl')
        self.main.prompt(0, 'start')
        self.main.save(self.main.path, other)
        self.sub.prompt(7, 'brief')
        self.sub.save()
        run = self.run_paths(SID)
        lines = run.stdout.splitlines()
        self.assertEqual([x.split(' ')[0] for x in lines], ['session', 'transcript', 'transcript', 'subagents'])
        self.assertEqual(sorted(x.split(' ', 1)[1] for x in lines if x.startswith('transcript')),
                         sorted([str(self.main.path), str(other)]))

    def test_paths_of_a_session_with_no_transcript_says_so_and_exits_1(self):
        unknown = '99999999-0000-0000-0000-000000000000'
        run = self.run_paths(unknown)
        self.assertEqual(run.returncode, 1)
        self.assertEqual(run.stdout.splitlines(), ['session ' + unknown, 'not found under ' + str(self.root)])


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
