"""Run the release workflow shell steps with local command stubs."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


WORKFLOWS = json.loads(Path(sys.argv.pop(1)).read_text())
RELEASE = WORKFLOWS[".github/workflows/release.yaml"]
NOTIFY = WORKFLOWS[".github/workflows/release-notify.yaml"]
STEPS = RELEASE["jobs"]["release"]["steps"]
PREPARATION = RELEASE["jobs"]["prepare"]
RESULT, CREATE_PR = PREPARATION["steps"][-2:]
PERFORM = next(step for step in STEPS if step.get("id") == "perform")
PUBLISH = STEPS[-1]
DISPATCH = NOTIFY["jobs"]["notify"]["steps"][-1]
SHA = "1" * 40

STUB = """import json, os, pathlib, sys
command = [pathlib.Path(sys.argv[0]).name, *sys.argv[1:]]
with open(os.environ['COMMAND_LOG'], 'a') as log:
    log.write(json.dumps(command) + '\\n')
if command[:2] == ['git', 'merge-base']:
    sys.exit(0 if os.environ['MAIN_REACHABLE'] == '1' else 1)
if command[:2] == ['git', 'diff']:
    sys.exit(0 if os.environ['PREPARED'] == '1' else 1)
if command[:2] == ['git', 'rev-parse']:
    print(os.environ['SHA'])
if command[:2] == ['git', 'push']:
    sys.exit(int(os.environ['PUSH_EXIT']))
if command[:3] == ['gh', 'release', 'create']:
    notes = pathlib.Path(command[command.index('--notes-file') + 1])
    assert notes.parent == pathlib.Path(os.environ['RUNNER_TEMP'])
    assert notes.read_text() == os.environ['RELEASE_NOTES']
    sys.exit(int(os.environ['CREATE_EXIT']))
if command[:3] == ['gh', 'release', 'view']:
    print(os.environ['IS_DRAFT'])
    sys.exit(int(os.environ['VIEW_EXIT']))
if command[0] == 'gh':
    print(os.environ['CI_RUN'])
if command[0] == 'nix':
    if command[-2] == 'notes':
        print(os.environ['RELEASE_NOTES'], end='')
        sys.exit(int(os.environ['NOTES_EXIT']))
    print(os.environ['RELEASE_TAG'])
"""


class ReleaseWorkflowsTest(unittest.TestCase):
    def run_step(self, step, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "checkout"
            root.mkdir()
            runner_temp = Path(directory) / "runner temp"
            runner_temp.mkdir()
            (root / "VERSION").write_text("1.2.3\n")
            for command in ("git", "gh", "nix"):
                path = root / command
                path.write_text(f"#!{sys.executable}\n{STUB}")
                path.chmod(0o755)
            output, log = root / "output", root / "commands"
            output.touch()
            log.touch()
            env = os.environ | {
                "PATH": f"{root}{os.pathsep}{os.environ['PATH']}",
                "COMMAND_LOG": str(log), "GITHUB_OUTPUT": str(output),
                "PREPARED": "1", "GITHUB_REPOSITORY": "example/app",
                "GITHUB_SHA": "2" * 40, "SHA": SHA, "CHANNEL": "rc",
                "GH_TOKEN": "test-token", "MAIN_REACHABLE": "1", "CI_RUN": "123",
                "RELEASE_TAG": "v1.2.3-rc.1",
                "TAG": "v1.2.3-rc.1", "GH_REPO": "example/app",
                "RUNNER_TEMP": str(runner_temp), "RELEASE_NOTES": "## 1.2.3\n\n- change\n",
                "PUSH_EXIT": "0", "NOTES_EXIT": "0", "CREATE_EXIT": "0",
                "VIEW_EXIT": "0", "IS_DRAFT": "false",
            } | overrides
            result = subprocess.run(
                ["bash", "-c", step["run"]], cwd=root, env=env, capture_output=True, text=True
            )
            return result, output.read_text(), [json.loads(line) for line in log.read_text().splitlines()]

    def test_preparation_selects_sha_and_requests_pr_only_for_changes(self):
        for prepared in ("1", "0"):
            with self.subTest(prepared=prepared):
                result, output, _ = self.run_step(RESULT, PREPARED=prepared, CHANNEL="")
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = f"sha={SHA}\nready=true\n" if prepared == "1" else (
                    f"sha={SHA}\nready=false\ntitle=chore(release): prepare v1.2.3\n"
                )
                self.assertEqual(output, expected)
        self.assertEqual(CREATE_PR["if"], "steps.result.outputs.ready == 'false'")
        self.assertRegex(CREATE_PR["uses"], r"^peter-evans/create-pull-request@[0-9a-f]{40}$")
        options = CREATE_PR["with"]
        self.assertEqual(options["token"], "${{ steps.app-token.outputs.token }}")
        self.assertEqual((options["base"], options["branch"]), ("main", "automation/prepare-release"))
        self.assertEqual(options["add-paths"].splitlines(), ["VERSION", "CHANGELOG.md"])
        self.assertEqual(options["title"], "${{ steps.result.outputs.title }}")
        self.assertEqual(options["commit-message"], options["title"])
        self.assertIn("rerun Release", options["body"])

    def test_invalid_channel_is_rejected_before_publication(self):
        result, _, commands = self.run_step(PERFORM, CHANNEL="other")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(commands, [])

    def test_publish_requires_main_and_successful_ci(self):
        for env in ({"MAIN_REACHABLE": "0"}, {"CI_RUN": ""}):
            with self.subTest(env=env):
                result, _, commands = self.run_step(PERFORM, **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(command[:2] == ["git", "push"] for command in commands))

    def test_publish_updates_tag_and_channel_atomically_at_selected_sha(self):
        for channel, branch in (("rc", "unstable"), ("stable", "stable")):
            with self.subTest(channel=channel):
                tag = "v1.2.3-rc.1" if channel == "rc" else "v1.2.3"
                result, output, commands = self.run_step(PERFORM, CHANNEL=channel, RELEASE_TAG=tag)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, f"tag={tag}\n")
                self.assertIn(["git", "merge-base", "--is-ancestor", SHA, "origin/main"], commands)
                query = next(command for command in commands if command[0] == "gh")
                self.assertTrue({f"head_sha={SHA}", "branch=main", "status=success"}.issubset(query))
                self.assertEqual(next(command for command in commands if command[0] == "nix")[-2:], ["--", channel])
                pushes = [command for command in commands if command[:2] == ["git", "push"]]
                self.assertEqual(len(pushes), 1)
                self.assertEqual(pushes[0][2], "--atomic")
                self.assertEqual(pushes[0][-2:], [
                    f"refs/tags/{tag}:refs/tags/{tag}", f"{SHA}:refs/heads/{branch}"
                ])
                self.assertFalse(any("/dispatches" in arg for command in commands for arg in command))

    def test_failed_push_does_not_output_tag(self):
        result, output, _ = self.run_step(PERFORM, PUSH_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, "")

    def test_github_release_uses_changelog_notes_and_channel_flags(self):
        for channel, tag in (("rc", "v1.2.3-rc.1"), ("stable", "v1.2.3")):
            with self.subTest(channel=channel):
                result, _, commands = self.run_step(PUBLISH, CHANNEL=channel, TAG=tag)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(commands), 2)
                self.assertEqual(commands[0], [
                    "nix", "run", "--option", "accept-flake-config", "false", ".#release", "--", "notes", tag
                ])
                create = commands[1]
                args = ["--prerelease", "--latest=false"] if channel == "rc" else []
                self.assertEqual(create, [
                    "gh", "release", "create", tag, "--verify-tag", "--title", tag,
                    "--notes-file", create[8], *args,
                ])

    def test_notes_failure_stops_publication(self):
        result, _, commands = self.run_step(PUBLISH, NOTES_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([command[0] for command in commands], ["nix"])

    def test_failed_creation_succeeds_only_for_a_published_release(self):
        for is_draft, view_exit, success in (
            ("false", "0", True),
            ("true", "0", False),
            ("", "1", False),
            ("false", "1", False),
        ):
            with self.subTest(is_draft=is_draft, view_exit=view_exit):
                result, _, commands = self.run_step(
                    PUBLISH, CREATE_EXIT="1", IS_DRAFT=is_draft, VIEW_EXIT=view_exit
                )
                self.assertEqual(result.returncode == 0, success, result.stderr)
                self.assertEqual(commands[-1], [
                    "gh", "release", "view", "v1.2.3-rc.1", "--json", "isDraft", "--jq", ".isDraft"
                ])
                self.assertEqual(len(commands), 3)

    def test_notifier_dispatches_push_revision_for_each_channel(self):
        for channel in ("stable", "unstable"):
            result, _, commands = self.run_step(DISPATCH, CHANNEL=channel)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(commands, [[
                "gh", "api", "--method", "POST", "/repos/example/ops/dispatches",
                "-f", "event_type=release", "-f", f"client_payload[channel]={channel}",
                "-f", f"client_payload[sha]={SHA}",
            ]])

    def test_event_wiring_preserves_immutable_revision(self):
        self.assertEqual(set(RELEASE["on"]), {"workflow_dispatch"})
        channel = RELEASE["on"]["workflow_dispatch"]["inputs"]["channel"]
        self.assertEqual((channel["type"], channel["options"], channel["default"]), ("choice", ["rc", "stable"], "rc"))
        self.assertEqual(RELEASE["concurrency"], {"group": "release-request", "cancel-in-progress": False})
        self.assertEqual(RELEASE["jobs"]["release"]["needs"], ["prepare"])
        self.assertEqual(RELEASE["jobs"]["release"]["if"], "needs.prepare.outputs.ready == 'true'")
        self.assertEqual(PREPARATION["outputs"], {
            "ready": "${{ steps.result.outputs.ready }}", "sha": "${{ steps.result.outputs.sha }}"
        })
        checkout = next(step for step in STEPS if step.get("uses", "").startswith("actions/checkout@"))
        self.assertEqual(checkout["with"]["ref"], "${{ needs.prepare.outputs.sha }}")
        self.assertEqual(PERFORM["env"]["SHA"], "${{ needs.prepare.outputs.sha }}")
        self.assertEqual(PERFORM["env"]["CHANNEL"], "${{ inputs.channel }}")
        self.assertLess(STEPS.index(PERFORM), STEPS.index(PUBLISH))
        self.assertEqual(PUBLISH["env"], {
            "TAG": "${{ steps.perform.outputs.tag }}", "CHANNEL": "${{ inputs.channel }}",
            "GH_REPO": "${{ github.repository }}", "GH_TOKEN": "${{ steps.app-token.outputs.token }}",
        })
        self.assertEqual(DISPATCH["env"]["SHA"], "${{ github.event.after }}")
        self.assertEqual(DISPATCH["env"]["CHANNEL"], "${{ github.ref_name }}")
        self.assertEqual(NOTIFY["on"]["push"]["branches"], ["stable", "unstable"])
        self.assertEqual(NOTIFY["jobs"]["notify"]["if"], "github.event.deleted == false")
        self.assertNotIn("concurrency", NOTIFY)
        self.assertNotIn("concurrency", NOTIFY["jobs"]["notify"])


if __name__ == "__main__":
    unittest.main()
