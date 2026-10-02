"""Tests for scripts/checks/working-memory-staleness.py."""
from __future__ import annotations

import datetime as dt
import importlib.util
import os
import subprocess
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
SCRIPT = SCRIPTS / "checks" / "working-memory-staleness.py"
spec = importlib.util.spec_from_file_location("working_memory_staleness", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

TODAY = "2026-10-02"
LIVE_PLAN = "# Plan\n\nStatus: active.\n\n- [x] one\n- [ ] two\n- [ ] three\n"


def write(root: Path, rel: str, text: str) -> Path:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def run(root: Path, capsys, *extra: str, allowlist: str | None = None) -> tuple[int, str, str]:
    args = ["--root", str(root), "--today", TODAY, *extra]
    allow = root / "allowlist"
    if allowlist is not None:
        allow.write_text(allowlist, encoding="utf-8")
    args += ["--allowlist", str(allow)]
    code = checker.main(args)
    captured = capsys.readouterr()
    return code, captured.out, captured.err


@pytest.fixture
def root(tmp_path: Path) -> Path:
    return tmp_path


# ---------------------------------------------------------------- passing cases


def test_clean_tree_passes(root, capsys):
    write(root, "docs/superpowers/plans/2026-10-01-live.md", LIVE_PLAN)
    write(root, "docs/plans/2026-10-02-active.md", "# Program\n\nStatus: active. Delete when the program closes.\n")
    code, out, err = run(root, capsys)
    assert code == 0
    assert "no working-memory doc looks finished or stale" in out
    assert err == ""


def test_empty_tree_passes(root, capsys):
    code, _, _ = run(root, capsys)
    assert code == 0


def test_unscanned_directories_are_ignored(root, capsys):
    write(root, "docs/user-manual/chapters/old.md", "Status: complete\n")
    write(root, "docs/features/old.md", "Status: shipped\n")
    code, _, _ = run(root, capsys)
    assert code == 0


# ---------------------------------------------------------------- finished-status


@pytest.mark.parametrize(
    "line",
    [
        "Status: complete",
        "Status: Shipped in 2026.9.36",
        "**Status:** Done",
        "**Status: implemented and merged**",
        "Status 2026-07-05: Resolved for newly written provenance.",
        "Status: PASS after four fixes.",
        "Status: VERIFIED in the running GUI on 2026-08-19",
        "Status: **acceptance complete**",
        "> Status: superseded by the one-way export",
    ],
)
def test_finished_status_fails_and_names_file_and_rule(root, capsys, line):
    write(root, "docs/superpowers/specs/2026-10-01-thing.md", f"# Thing\n\n{line}\n")
    code, _, err = run(root, capsys)
    assert code == 1
    assert "docs/superpowers/specs/2026-10-01-thing.md: finished-status" in err
    assert "1 working-memory doc(s)" in err


def test_status_heading_form_is_read(root, capsys):
    write(root, "docs/plans/2026-10-01-thing.md", "# Thing\n\n## Status\n\nShipped in 2026.9.40.\n")
    code, _, err = run(root, capsys)
    assert code == 1
    assert "finished-status" in err


@pytest.mark.parametrize(
    "line",
    [
        "Status: active",
        "Status: not yet merged",
        "Status: draft, nothing is implemented",
        "Status: Written specification for user review; implementation not started.",
        "Status: Planning review only. Do not implement fixes until the manifest is reviewed.",
        "Status: delete this plan when the campaign ships",
        "Status: product spec",
    ],
)
def test_open_status_passes(root, capsys, line):
    write(root, "docs/plans/2026-10-01-thing.md", f"# Thing\n\n{line}\n")
    code, _, err = run(root, capsys)
    assert code == 0, err


@pytest.mark.parametrize(
    "line",
    [
        "Status: active. Phase 0 shipped",
        "Status: Active, Phase 0 complete and merged",
        "Status: ACTIVE. Companion plan implemented.",
        "**Status: active. Phase 0 shipped in 2026.9.77**",
        "**Status:** Active. Phase 0 shipped.",
        "Status 2026-10-02: active, first lane merged",
    ],
)
def test_active_status_passes_even_with_a_finished_word(root, capsys, line):
    write(root, "docs/plans/2026-10-02-program.md", f"# Program\n\n{line}\n")
    code, _, err = run(root, capsys)
    assert code == 0, err


def test_active_status_heading_form_passes(root, capsys):
    write(root, "docs/plans/2026-10-02-program.md", "# Program\n\n## Status\n\nActive. Phase 0 shipped in 2026.9.77.\n")
    code, _, err = run(root, capsys)
    assert code == 0, err


def test_active_status_passes_in_reports_too(root, capsys):
    write(root, "docs/reports/2026-10-02-review.md", "# Review\n\nStatus: active. Findings resolved as lanes merge.\n")
    code, _, err = run(root, capsys)
    assert code == 0, err


def test_shipped_status_still_fails(root, capsys):
    write(root, "docs/plans/2026-10-02-program.md", "# Program\n\nStatus: shipped\n")
    code, _, err = run(root, capsys)
    assert code == 1
    assert "docs/plans/2026-10-02-program.md: finished-status: Status line says 'shipped'" in err


@pytest.mark.parametrize(
    "line",
    [
        "Status: shipped, no longer active",
        "Status: inactive, shipped in 2026.9.36",
        "Status: was active, now complete",
    ],
)
def test_active_later_in_the_status_line_does_not_exempt_it(root, capsys, line):
    write(root, "docs/plans/2026-10-02-program.md", f"# Program\n\n{line}\n")
    code, _, err = run(root, capsys)
    assert code == 1
    assert "docs/plans/2026-10-02-program.md: finished-status" in err


def test_active_status_does_not_hide_the_checkbox_rule(root, capsys):
    write(root, "docs/plans/2026-10-02-program.md", "# Program\n\nStatus: active. Phase 0 shipped\n\n- [x] a\n- [x] b\n- [x] c\n")
    code, _, err = run(root, capsys)
    assert code == 1
    assert "all-steps-done" in err
    assert "finished-status" not in err


def test_status_after_the_first_lines_is_not_read(root, capsys):
    body = "# Thing\n" + "text\n" * 30 + "Status: complete\n"
    write(root, "docs/plans/2026-10-01-thing.md", body)
    code, _, _ = run(root, capsys)
    assert code == 0


def test_word_inside_a_longer_word_is_not_finished(root, capsys):
    write(root, "docs/plans/2026-10-01-thing.md", "Status: incomplete, passage pending\n")
    code, _, _ = run(root, capsys)
    assert code == 0


# ---------------------------------------------------------------- all-steps-done


def test_all_steps_ticked_fails(root, capsys):
    write(root, "docs/superpowers/plans/2026-10-01-plan.md", "Status: active\n\n- [x] a\n- [X] b\n- [x] c\n")
    code, _, err = run(root, capsys)
    assert code == 1
    assert "all-steps-done" in err


def test_partly_ticked_steps_pass(root, capsys):
    write(root, "docs/superpowers/plans/2026-10-01-plan.md", "Status: active\n\n- [x] a\n- [x] b\n- [ ] c\n")
    code, _, _ = run(root, capsys)
    assert code == 0


def test_fewer_than_three_steps_do_not_count(root, capsys):
    write(root, "docs/superpowers/plans/2026-10-01-plan.md", "Status: active\n\n- [x] a\n- [x] b\n")
    code, _, _ = run(root, capsys)
    assert code == 0


# ---------------------------------------------------------------- stale-no-status


def test_old_plan_without_status_fails(root, capsys):
    write(root, "docs/superpowers/plans/2026-09-10-old.md", "# Old\n\nNo status here.\n")
    code, _, err = run(root, capsys)
    assert code == 1
    assert "docs/superpowers/plans/2026-09-10-old.md: stale-no-status" in err
    assert "22 days old" in err


def test_recent_plan_without_status_passes(root, capsys):
    write(root, "docs/superpowers/plans/2026-09-25-recent.md", "# Recent\n")
    code, _, _ = run(root, capsys)
    assert code == 0


def test_age_limit_is_exclusive_and_configurable(root, capsys):
    write(root, "docs/plans/2026-09-18-edge.md", "# Edge\n")  # exactly 14 days old
    assert run(root, capsys)[0] == 0
    assert run(root, capsys, "--max-age-days", "13")[0] == 1
    assert run(root, capsys, "--max-age-days", "60")[0] == 0


def test_old_plan_with_open_status_passes(root, capsys):
    write(root, "docs/plans/2026-05-01-long-running.md", "Status: active\n")
    code, _, _ = run(root, capsys)
    assert code == 0


def test_undated_file_uses_its_last_commit_date(root, capsys):
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    path = write(root, "docs/issues/backlog.md", "# Backlog\n")
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)
    env = {
        **os.environ,
        "GIT_AUTHOR_DATE": "2026-05-09T12:00:00",
        "GIT_COMMITTER_DATE": "2026-05-09T12:00:00",
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@example.com",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@example.com",
    }
    subprocess.run(["git", "-C", str(root), "commit", "-q", "-m", "add"], check=True, env=env)
    assert path.exists()
    code, _, err = run(root, capsys)
    assert code == 1
    assert "docs/issues/backlog.md: stale-no-status" in err


def test_undated_file_outside_git_is_skipped(root, capsys):
    write(root, "docs/issues/backlog.md", "# Backlog\n")
    code, _, _ = run(root, capsys)
    assert code == 0


# ---------------------------------------------------------------- reports


def test_reports_get_only_the_status_rule(root, capsys):
    write(root, "docs/reports/2026-01-01-old-report.md", "# Old report\n\nNo status.\n- [x] a\n- [x] b\n- [x] c\n")
    assert run(root, capsys)[0] == 0
    write(root, "docs/reports/2026-09-30-done-report.md", "# Done\n\nStatus: findings resolved.\n")
    code, _, err = run(root, capsys)
    assert code == 1
    assert "docs/reports/2026-09-30-done-report.md: finished-status" in err
    assert "old-report" not in err


# ---------------------------------------------------------------- allowlist


def test_allowlist_exempts_a_file(root, capsys):
    write(root, "docs/verification/2026-07-25-inventory.md", "# Inventory\n")
    assert run(root, capsys)[0] == 1
    code, _, err = run(root, capsys, allowlist="docs/verification/2026-07-25-inventory.md  # a test reads it\n")
    assert code == 0, err


def test_allowlist_directory_entry_exempts_everything_below(root, capsys):
    write(root, "docs/plans/study-questions/SPEC.md", "Status: complete\n")
    write(root, "docs/plans/study-questions/nested/page.md", "Status: shipped\n")
    write(root, "docs/plans/2026-10-01-other.md", "Status: complete\n")
    code, _, err = run(root, capsys, allowlist="docs/plans/study-questions/  # deferred work\n")
    assert code == 1
    assert "docs/plans/2026-10-01-other.md" in err
    assert "study-questions" not in err


def test_allowlist_comments_and_blank_lines_are_ignored(root, capsys):
    write(root, "docs/plans/2026-10-01-thing.md", "Status: complete\n")
    code, _, _ = run(root, capsys, allowlist="# header\n\n  # indented comment\ndocs/plans/2026-10-01-thing.md  # reason\n")
    assert code == 0


def test_stale_allowlist_entry_warns_without_failing(root, capsys):
    write(root, "docs/plans/2026-10-01-live.md", "Status: active\n")
    code, out, err = run(root, capsys, allowlist="docs/plans/gone.md  # deleted since\ndocs/gone-dir/  # also deleted\n")
    assert code == 0
    assert "allowlist entry matches no scanned file: docs/plans/gone.md" in err
    assert "allowlist entry matches no scanned file: docs/gone-dir/" in err
    assert "no working-memory doc looks finished or stale" in out


def test_missing_allowlist_file_is_fine(root, capsys):
    write(root, "docs/plans/2026-10-01-live.md", "Status: active\n")
    code = checker.main(["--root", str(root), "--today", TODAY, "--allowlist", str(root / "absent")])
    assert code == 0


# ---------------------------------------------------------------- reporting


def test_every_finding_is_reported_with_a_count(root, capsys):
    write(root, "docs/plans/2026-10-01-a.md", "Status: complete\n")
    write(root, "docs/superpowers/specs/2026-09-01-b.md", "# No status\n")
    write(root, "docs/issues/2026-10-01-c.md", "Status: active\n- [x] a\n- [x] b\n- [x] c\n")
    code, _, err = run(root, capsys)
    assert code == 1
    assert "3 working-memory doc(s)" in err
    assert "2026-10-01-a.md: finished-status" in err
    assert "2026-09-01-b.md: stale-no-status" in err
    assert "2026-10-01-c.md: all-steps-done" in err
    assert "working-memory-staleness.allowlist" in err


def test_today_defaults_to_the_real_date(root, capsys):
    stamp = (dt.date.today() - dt.timedelta(days=3)).isoformat()
    write(root, f"docs/plans/{stamp}-fresh.md", "# Fresh\n")
    code = checker.main(["--root", str(root), "--allowlist", str(root / "absent")])
    capsys.readouterr()
    assert code == 0


# ---------------------------------------------------------------- hook wiring


def test_pre_push_hook_runs_the_check_before_the_unit_gate(tmp_path):
    repo = tmp_path / "repo"
    (repo / "scripts").mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    (repo / "scripts" / "install-git-hooks.sh").write_text((SCRIPTS / "install-git-hooks.sh").read_text())
    result = subprocess.run(
        ["/bin/bash", str(repo / "scripts" / "install-git-hooks.sh")],
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    assert result.returncode == 0, result.stdout
    hook = (repo / ".git" / "hooks" / "pre-push").read_text()
    assert "scripts/checks/working-memory-staleness.py" in hook
    assert hook.index("working-memory-staleness.py") < hook.index('full-suite-gate.sh" --tier unit')
    assert "working-memory-staleness" in result.stdout
