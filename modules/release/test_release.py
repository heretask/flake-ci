#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path

from release import Config, ReleaseError, collect_status, main, repo_root


def policy_source() -> Path:
    here = Path(__file__).resolve().parent
    for candidate in (here.parent / "cog.toml", here / "cog.toml"):
        if candidate.is_file():
            return candidate
    raise FileNotFoundError("repository cog.toml policy not found")


def git_env():
    env = os.environ.copy()
    env.pop("GIT_DIR", None)
    env.pop("GIT_WORK_TREE", None)
    env.pop("GIT_COMMON_DIR", None)
    env.pop("GIT_INDEX_FILE", None)
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    return env


def run(args, cwd, env=None, check=True):
    merged = git_env()
    if env:
        merged.update(env)
    git_args = args
    if args and args[0] == "git":
        git_args = ["git", "-C", str(cwd), "--git-dir", str(Path(cwd) / ".git"), *args[1:]]
    return subprocess.run(git_args, cwd=cwd, text=True, capture_output=True, check=check, env=merged)


def init_repo(tmp: Path) -> Path:
    repo = tmp / "repo"
    repo.mkdir()
    run(["git", "init", "-b", "main"], cwd=repo)
    run(["git", "config", "user.email", "test@example.com"], cwd=repo)
    run(["git", "config", "user.name", "Test"], cwd=repo)
    (repo / "VERSION").write_text("1.0.0\n")
    (repo / "CHANGELOG.md").write_text("# Changelog\n\n## 1.0.0\n\n- initial\n")
    (repo / "cog.toml").write_text(policy_source().read_text())
    run(["git", "add", "VERSION", "CHANGELOG.md", "cog.toml"], cwd=repo)
    run(["git", "commit", "-m", "chore: initial"], cwd=repo)
    return repo


def commit_file(repo: Path, message: str, name="change.txt", text="x\n"):
    path = repo / name
    path.write_text(path.read_text() + text if path.exists() else text)
    run(["git", "add", name], cwd=repo)
    run(["git", "commit", "-m", message], cwd=repo)


def tag(repo: Path, name: str):
    run(["git", "-c", "tag.gpgSign=false", "tag", name], cwd=repo)


def head(repo: Path) -> str:
    return run(["git", "rev-parse", "HEAD"], cwd=repo).stdout.strip()


def prepare_and_commit(repo: Path, message: str) -> None:
    code = main(["prepare"])
    if code != 0:
        raise AssertionError("prepare failed")
    run(["git", "add", "VERSION", "CHANGELOG.md"], cwd=repo)
    run(["git", "commit", "-m", message], cwd=repo)


class ReleaseLifecycleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = init_repo(Path(self.tmp.name))
        self.config = Config()
        self.old = os.getcwd()
        os.chdir(self.repo)
        self.addCleanup(os.chdir, self.old)

    def status(self):
        return collect_status(self.repo, self.config)

    def git_log_and_tags(self):
        commits = run(["git", "rev-list", "--all"], cwd=self.repo).stdout
        tags = run(["git", "tag", "--list"], cwd=self.repo).stdout
        return commits, tags

    def snapshot_release_files(self):
        return (
            (self.repo / "VERSION").read_text(),
            (self.repo / "CHANGELOG.md").read_text(),
            self.git_log_and_tags(),
        )

    def test_colocated_repository_required(self):
        self.assertEqual(repo_root(self.repo), self.repo)
        workspace = Path(self.tmp.name) / "workspace"
        run(["git", "worktree", "add", str(workspace)], cwd=self.repo)
        with self.assertRaisesRegex(ReleaseError, "requires a colocated .git directory"):
            repo_root(workspace)

    def test_fix_is_patch(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "fix: bug")
        prepare_and_commit(self.repo, "chore: prepare 1.0.1")
        status = self.status()
        self.assertEqual(str(status.calculated_target), "1.0.1")
        self.assertEqual(str(status.latest_stable), "1.0.0")

    def test_revert_is_patch(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "revert: restore previous behavior")
        status = self.status()
        self.assertEqual(str(status.calculated_target), "1.0.1")

    def test_feat_is_minor(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "feat: thing")
        status = self.status()
        self.assertEqual(str(status.calculated_target), "1.1.0")

    def test_breaking_is_major(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "feat!: breaking")
        status = self.status()
        self.assertEqual(str(status.calculated_target), "2.0.0")

    def test_rc_numbering_and_restart_after_target_change(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "fix: one")
        prepare_and_commit(self.repo, "chore: prepare 1.0.1")
        tag(self.repo, "v1.0.1-rc.1")
        tag(self.repo, "v1.0.1-rc.2")
        self.assertEqual(self.status().next_rc, "v1.0.1-rc.3")
        commit_file(self.repo, "feat: two")
        status = self.status()
        self.assertEqual(str(status.calculated_target), "1.1.0")
        self.assertEqual(str(status.latest_stable), "1.0.0")
        self.assertEqual(str(status.version_target), "1.0.1")
        self.assertEqual(status.next_rc, "v1.1.0-rc.1")
        self.assertIsNone(status.matching_rc)

    def test_stable_requires_rc_at_head(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "fix: one")
        prepare_and_commit(self.repo, "chore: prepare 1.0.1")
        before = self.snapshot_release_files()
        self.assertEqual(main(["stable"]), 1)
        self.assertEqual(self.snapshot_release_files(), before)
        tag(self.repo, "v1.0.1-rc.1")
        commit_file(self.repo, "fix: two")
        prepare_and_commit(self.repo, "chore: prepare 1.0.1 again")
        before = self.snapshot_release_files()
        self.assertEqual(main(["stable"]), 1)
        self.assertEqual(self.snapshot_release_files(), before)

    def test_candidate_selects_newest_reachable_rc(self):
        self.assertEqual(main(["candidate"]), 1)
        tag(self.repo, "v1.0.1-rc.9")
        tag(self.repo, "v1.0.1-rc.10")
        commit_file(self.repo, "chore: later")
        tag(self.repo, "v1.0.0-rc.11")
        run(["git", "checkout", "-b", "side"], cwd=self.repo)
        commit_file(self.repo, "chore: unmerged")
        tag(self.repo, "v2.0.0-rc.1")
        run(["git", "checkout", "main"], cwd=self.repo)
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(main(["candidate"]), 0)
        self.assertEqual(output.getvalue(), "v1.0.1-rc.10\n")

    def test_promotion_reuses_rc_commit(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "fix: one")
        prepare_and_commit(self.repo, "chore: prepare 1.0.1")
        sha = head(self.repo)
        files_before = self.snapshot_release_files()
        for channel in ("rc", "stable"):
            self.assertEqual(main([channel]), 0)
            after = self.snapshot_release_files()
            self.assertEqual(after[:2], files_before[:2])
            self.assertEqual(after[2][0], files_before[2][0])
        for channel in ("rc", "stable"):
            self.assertEqual(main([channel]), 0)
            self.assertEqual(self.snapshot_release_files(), after)
        self.assertEqual(head(self.repo), sha)
        self.assertEqual(run(["git", "rev-parse", "v1.0.1^{commit}"], cwd=self.repo).stdout.strip(), sha)
        self.assertEqual(run(["git", "rev-parse", "v1.0.1-rc.1^{commit}"], cwd=self.repo).stdout.strip(), sha)
        self.assertEqual(run(["git", "status", "--porcelain"], cwd=self.repo).stdout, "")

    def test_stable_tag_collision(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "fix: one")
        prepare_and_commit(self.repo, "chore: prepare 1.0.1")
        sha = head(self.repo)
        commit_file(self.repo, "chore: later")
        tag(self.repo, "v1.0.1")
        run(["git", "checkout", sha], cwd=self.repo)
        tag(self.repo, "v1.0.1-rc.1")
        before = self.snapshot_release_files()
        self.assertEqual(main(["stable"]), 1)
        self.assertEqual(self.snapshot_release_files(), before)

    def test_dirty_tree_rejected(self):
        prepare_and_commit(self.repo, "chore: prepare 1.0.0")
        (self.repo / "VERSION").write_text("9.9.9\n")
        before = self.snapshot_release_files()
        for channel in ("rc", "stable"):
            self.assertEqual(main([channel]), 1)
            self.assertEqual(self.snapshot_release_files(), before)

    def test_promotion_rejects_unprepared_rc_commit(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "fix: one")
        tag(self.repo, "v1.0.1-rc.1")
        self.assertEqual(main(["stable"]), 1)

    def test_version_prerelease_rejected(self):
        (self.repo / "VERSION").write_text("1.0.0-rc.1\n")
        with self.assertRaises(ReleaseError):
            self.status()

    def test_version_mismatch_rejected(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "feat: thing")
        self.assertEqual(main(["rc"]), 1)

    def test_rc_changelog_heading_rejected(self):
        (self.repo / "CHANGELOG.md").write_text("# Changelog\n\n## 1.0.0-rc.1\n")
        run(["git", "add", "CHANGELOG.md"], cwd=self.repo)
        run(["git", "commit", "-m", "chore: rc heading"], cwd=self.repo)
        self.assertEqual(main(["rc"]), 1)

    def test_stale_same_impact_changelog_rejected(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "fix: one")
        prepare_and_commit(self.repo, "chore: prepare 1.0.1")
        commit_file(self.repo, "fix: two")
        status = self.status()
        self.assertEqual(str(status.calculated_target), "1.0.1")
        self.assertEqual(str(status.version_target), "1.0.1")
        self.assertFalse(status.changelog_ok)
        self.assertEqual(main(["rc"]), 1)
        self.assertEqual(main(["stable"]), 1)

    def test_exact_readiness(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "fix: one")
        self.assertEqual(main(["prepare"]), 0)
        run(["git", "add", "VERSION", "CHANGELOG.md"], cwd=self.repo)
        run(["git", "commit", "-m", "chore: prepare 1.0.1"], cwd=self.repo)
        status = self.status()
        self.assertTrue(status.version_matches)
        self.assertTrue(status.changelog_ok)
        text = (self.repo / "CHANGELOG.md").read_text()
        extra = text.replace("## 1.0.1\n", "## 1.0.1\n\n- tampered\n", 1)
        (self.repo / "CHANGELOG.md").write_text(extra)
        run(["git", "add", "CHANGELOG.md"], cwd=self.repo)
        run(["git", "commit", "-m", "chore: extra changelog whitespace"], cwd=self.repo)
        status = self.status()
        self.assertFalse(status.changelog_ok)
        self.assertEqual(main(["rc"]), 1)
        self.assertEqual(main(["prepare"]), 0)
        run(["git", "add", "CHANGELOG.md"], cwd=self.repo)
        run(["git", "commit", "-m", "chore: restore changelog"], cwd=self.repo)
        status = self.status()
        self.assertTrue(status.changelog_ok)
        path = self.repo / "CHANGELOG.md"
        path.write_bytes(path.read_bytes() + b"\r")
        run(["git", "add", "CHANGELOG.md"], cwd=self.repo)
        run(["git", "commit", "-m", "chore: trailing cr"], cwd=self.repo)
        status = self.status()
        self.assertFalse(status.changelog_ok)
        self.assertEqual(main(["rc"]), 1)
        self.assertEqual(main(["stable"]), 1)
        self.assertEqual(run(["git", "tag", "--list", "v1.0.1"], cwd=self.repo).stdout, "")

    def test_rc_refuses_already_released_target(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "chore: noise")
        self.assertIsNone(self.status().next_rc)
        before = self.git_log_and_tags()
        self.assertEqual(main(["rc"]), 1)
        self.assertEqual(self.git_log_and_tags(), before)

    def test_unreachable_stable_tag_is_ignored(self):
        tag(self.repo, "v1.0.0")
        run(["git", "checkout", "--orphan", "other"], cwd=self.repo)
        commit_file(self.repo, "feat: orphaned", name="orphan.txt")
        tag(self.repo, "v9.9.9")
        run(["git", "checkout", "main"], cwd=self.repo)
        status = self.status()
        self.assertEqual(str(status.latest_stable), "1.0.0")
        self.assertEqual(str(status.calculated_target), "1.0.0")

    def test_malformed_tags_are_ignored(self):
        tag(self.repo, "v1.0.0")
        for name in ("v1.0", "v1.0.0.1", "v1.0.0-rc", "v1.0.0-rc.foo", "not-a-version"):
            tag(self.repo, name)
        status = self.status()
        self.assertEqual(str(status.latest_stable), "1.0.0")
        self.assertEqual(str(status.calculated_target), "1.0.0")
        self.assertIsNone(status.matching_rc)
        self.assertIsNone(status.next_rc)
        commit_file(self.repo, "fix: bug")
        status = self.status()
        self.assertEqual(status.next_rc, "v1.0.1-rc.1")

    def test_cli_status(self):
        code = main(["status"])
        self.assertEqual(code, 0)

    def test_notes_selects_stable_section_without_changing_checkout(self):
        for filename in ("CHANGELOG.md", "custom changelog.md"):
            section = f"## 1.2.3\n\n### Fixes\n\n- selected change in {filename}\n\n"
            changelog = "# Changelog\n\n## 2.0.0\n\n- newer\n\n" + section + "## 1.0.0\n\n- older\n"
            (self.repo / filename).write_text(changelog)
            before = self.snapshot_release_files()
            status = run(["git", "status", "--porcelain"], cwd=self.repo).stdout
            for release_tag in ("v1.2.3", "v1.2.3-rc.2"):
                with self.subTest(filename=filename, tag=release_tag):
                    output = StringIO()
                    args = [] if filename == "CHANGELOG.md" else ["--changelog-file", filename]
                    with redirect_stdout(output):
                        self.assertEqual(main([*args, "notes", release_tag]), 0)
                    self.assertEqual(output.getvalue(), section)
                    self.assertEqual(self.snapshot_release_files(), before)
                    self.assertEqual((self.repo / filename).read_text(), changelog)
                    self.assertEqual(run(["git", "status", "--porcelain"], cwd=self.repo).stdout, status)

    def test_notes_rejects_invalid_tags_and_missing_sections(self):
        before = self.snapshot_release_files()
        for release_tag, error in (
            ("1.0.0", "invalid release tag"),
            ("v1.0.0-rc.foo", "invalid release tag"),
            ("v9.9.9", "missing changelog section 9.9.9 in CHANGELOG.md"),
        ):
            with self.subTest(tag=release_tag):
                output, errors = StringIO(), StringIO()
                with redirect_stdout(output), redirect_stderr(errors):
                    self.assertEqual(main(["notes", release_tag]), 1)
                self.assertEqual(output.getvalue(), "")
                self.assertIn(error, errors.getvalue())
                self.assertEqual(self.snapshot_release_files(), before)
        (self.repo / "CHANGELOG.md").unlink()
        errors = StringIO()
        with redirect_stderr(errors):
            self.assertEqual(main(["notes", "v1.0.0"]), 1)
        self.assertIn("missing CHANGELOG.md", errors.getvalue())

    def test_rc_notes_show_only_new_changes_while_stable_notes_stay_cumulative(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "feat: first candidate feature")
        prepare_and_commit(self.repo, "chore: prepare first candidate")
        tag(self.repo, "v1.1.0-rc.1")
        first_notes = StringIO()
        with redirect_stdout(first_notes):
            self.assertEqual(main(["notes", "v1.1.0-rc.1"]), 0)
        self.assertTrue(first_notes.getvalue().startswith("## 1.1.0\n"))
        self.assertIn("first candidate feature", first_notes.getvalue())

        commit_file(self.repo, "fix: second candidate fix")
        fix_sha = head(self.repo)
        commit_file(self.repo, "chore: internal cleanup")
        prepare_and_commit(self.repo, "chore: prepare second candidate")
        for release_tag in ("v1.1.0-rc.2", "v1.1.0"):
            tag(self.repo, release_tag)
        before = self.snapshot_release_files()
        for release_tag in ("v1.1.0-rc.2", "v1.1.0-rc.2", "v1.1.0"):
            output = StringIO()
            with redirect_stdout(output):
                self.assertEqual(main(["notes", release_tag]), 0)
            if "-rc." in release_tag:
                self.assertEqual(
                    output.getvalue(),
                    f"## Changes since v1.1.0-rc.1\n\n- {fix_sha} - second candidate fix\n",
                )
            else:
                self.assertTrue(output.getvalue().startswith("## 1.1.0\n"))
                self.assertIn("first candidate feature", output.getvalue())
                self.assertIn("second candidate fix", output.getvalue())
            self.assertNotIn("internal cleanup", output.getvalue())
            self.assertEqual(self.snapshot_release_files(), before)
            self.assertEqual(run(["git", "status", "--porcelain"], cwd=self.repo).stdout, "")

    def test_rc_notes_select_highest_earlier_reachable_rc_for_same_target(self):
        tag(self.repo, "v1.0.0-rc.9")
        commit_file(self.repo, "fix: already in rc10")
        tag(self.repo, "v1.0.0-rc.10")
        run(["git", "checkout", "-b", "other"], cwd=self.repo)
        commit_file(self.repo, "fix: unrelated branch")
        tag(self.repo, "v1.0.0-rc.11")
        run(["git", "checkout", "main"], cwd=self.repo)
        commit_file(self.repo, "fix: new candidate change")
        candidate_sha = head(self.repo)
        for release_tag in ("v1.0.0-rc.12", "v1.0.0-rc.13", "v2.0.0-rc.11"):
            tag(self.repo, release_tag)
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(main(["notes", "v1.0.0-rc.12"]), 0)
        self.assertEqual(
            output.getvalue(),
            f"## Changes since v1.0.0-rc.10\n\n- {candidate_sha} - new candidate change\n",
        )

    def test_rc_notes_fall_back_to_full_section_without_eligible_predecessor(self):
        tag(self.repo, "v0.9.0-rc.1")
        run(["git", "checkout", "-b", "other"], cwd=self.repo)
        commit_file(self.repo, "fix: unrelated branch")
        tag(self.repo, "v1.0.0-rc.1")
        run(["git", "checkout", "main"], cwd=self.repo)
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(main(["notes", "v1.0.0-rc.2"]), 0)
        self.assertEqual(output.getvalue(), "## 1.0.0\n\n- initial\n")

    def test_rc_notes_report_no_entries_when_commit_policy_omits_all_changes(self):
        tag(self.repo, "v1.0.0-rc.1")
        commit_file(self.repo, "chore: internal cleanup")
        tag(self.repo, "v1.0.0-rc.2")
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(main(["notes", "v1.0.0-rc.2"]), 0)
        self.assertEqual(
            output.getvalue(),
            "## Changes since v1.0.0-rc.1\n\nNo changelog entries since this RC.\n",
        )

    def test_initial_version_survives_rcs_then_uses_stable_tag_bumps(self):
        (self.repo / "VERSION").write_text("3.0.0\n")
        commit_file(self.repo, "feat!: initial breaking feature")
        prepare_and_commit(self.repo, "chore: prepare first candidate")
        for number in (1, 2):
            output = StringIO()
            with redirect_stdout(output):
                self.assertEqual(main(["rc"]), 0)
            self.assertEqual(output.getvalue(), f"v3.0.0-rc.{number}\n")
            self.assertEqual((self.repo / "VERSION").read_text(), "3.0.0\n")
            if number == 1:
                commit_file(self.repo, "feat!: another breaking feature")
                prepare_and_commit(self.repo, "chore: prepare second candidate")
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(main(["stable"]), 0)
        self.assertEqual(output.getvalue(), "v3.0.0\n")
        commit_file(self.repo, "fix: after first stable")
        self.assertEqual(main(["prepare"]), 0)
        self.assertEqual((self.repo / "VERSION").read_text(), "3.0.1\n")

    def test_initial_version_uses_configured_version_file(self):
        (self.repo / "VERSION").rename(self.repo / "TARGET_VERSION")
        (self.repo / "TARGET_VERSION").write_text("3.0.0\n")
        self.assertEqual(main(["--version-file", "TARGET_VERSION", "prepare"]), 0)
        self.assertEqual((self.repo / "TARGET_VERSION").read_text(), "3.0.0\n")
        self.assertIn("## 3.0.0\n", (self.repo / "CHANGELOG.md").read_text())
        self.assertFalse((self.repo / "VERSION").exists())

    def test_prepare_writes_first_release_and_is_idempotent(self):
        before = self.git_log_and_tags()
        self.assertEqual(main(["prepare"]), 0)
        self.assertEqual((self.repo / "VERSION").read_text(), "1.0.0\n")
        changelog = (self.repo / "CHANGELOG.md").read_text()
        self.assertIn("## 1.0.0\n", changelog)
        self.assertNotIn("-rc.", changelog)
        self.assertEqual(main(["prepare"]), 0)
        self.assertEqual((self.repo / "CHANGELOG.md").read_text(), changelog)
        self.assertEqual(self.git_log_and_tags(), before)

    def test_prepare_check_success_and_failure(self):
        self.assertEqual(main(["prepare"]), 0)
        self.assertEqual(main(["prepare", "--check"]), 0)
        version = (self.repo / "VERSION").read_text()
        changelog = (self.repo / "CHANGELOG.md").read_text()
        (self.repo / "VERSION").write_text("9.9.9\n")
        self.assertEqual(main(["prepare", "--check"]), 1)
        self.assertEqual((self.repo / "VERSION").read_text(), "9.9.9\n")
        self.assertEqual((self.repo / "CHANGELOG.md").read_text(), changelog)
        (self.repo / "VERSION").write_text(version)
        (self.repo / "CHANGELOG.md").write_text(changelog + "\n# extra\n")
        extra = (self.repo / "CHANGELOG.md").read_text()
        self.assertEqual(main(["prepare", "--check"]), 1)
        self.assertEqual((self.repo / "CHANGELOG.md").read_text(), extra)
        self.assertEqual((self.repo / "VERSION").read_text(), version)

    def test_prepare_rollover_after_abandoned_rc(self):
        tag(self.repo, "v1.0.0")
        historical = (self.repo / "CHANGELOG.md").read_text()
        history = historical[historical.index("## 1.0.0") :]
        commit_file(self.repo, "fix: one")
        self.assertEqual(main(["prepare"]), 0)
        self.assertEqual((self.repo / "VERSION").read_text(), "1.0.1\n")
        run(["git", "add", "VERSION", "CHANGELOG.md"], cwd=self.repo)
        run(["git", "commit", "-m", "chore: prepare 1.0.1"], cwd=self.repo)
        tag(self.repo, "v1.0.1-rc.1")
        commit_file(self.repo, "feat: two")
        before = self.git_log_and_tags()
        self.assertEqual(main(["prepare"]), 0)
        self.assertEqual(self.git_log_and_tags(), before)
        self.assertEqual((self.repo / "VERSION").read_text(), "1.1.0\n")
        changelog = (self.repo / "CHANGELOG.md").read_text()
        self.assertIn("## 1.1.0\n", changelog)
        self.assertNotIn("## 1.0.1\n", changelog)
        self.assertTrue(changelog.endswith(history))
        self.assertIn("one", changelog)
        self.assertIn("two", changelog)
        self.assertNotIn("-rc.", changelog)

    def test_prepare_no_bump_keeps_latest_stable(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "chore: housekeeping")
        self.assertEqual(main(["prepare"]), 0)
        self.assertEqual((self.repo / "VERSION").read_text(), "1.0.0\n")
        changelog = (self.repo / "CHANGELOG.md").read_text()
        self.assertIn("## 1.0.0\n", changelog)
        self.assertNotIn("## 1.0.1\n", changelog)
        self.assertNotIn("-rc.", changelog)

    def test_prepare_malformed_commit_fails(self):
        tag(self.repo, "v1.0.0")
        commit_file(self.repo, "not a conventional commit")
        version = (self.repo / "VERSION").read_text()
        changelog = (self.repo / "CHANGELOG.md").read_text()
        self.assertEqual(main(["prepare"]), 1)
        self.assertEqual((self.repo / "VERSION").read_text(), version)
        self.assertEqual((self.repo / "CHANGELOG.md").read_text(), changelog)


if __name__ == "__main__":
    unittest.main()
