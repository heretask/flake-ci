#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Mapping, Sequence

STABLE_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
RC_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)-rc\.(\d+)$")
STABLE_VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
CHANGELOG_HEADING = re.compile(r"^## (\d+\.\d+\.\d+(?:-rc\.\d+)?)\s*$", re.MULTILINE)

COMMIT_TEMPLATE = (
    "{% for commit in commits %}"
    "{{ commit.type }}\t{{ commit.breaking_change }}\t{{ commit.id }}\t{{ commit.summary }}\n"
    "{% endfor %}"
)


class ReleaseError(Exception):
    pass


@dataclass(frozen=True)
class Version:
    major: int
    minor: int
    patch: int

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"

    @property
    def tuple(self) -> tuple[int, int, int]:
        return (self.major, self.minor, self.patch)

    @classmethod
    def parse(cls, text: str) -> Version:
        match = STABLE_VERSION.fullmatch(text.strip())
        if not match:
            raise ReleaseError(f"VERSION must be a stable SemVer, got {text!r}")
        return cls(int(match[1]), int(match[2]), int(match[3]))

    def bump(self, impact: str) -> Version:
        if impact == "major":
            return Version(self.major + 1, 0, 0)
        if impact == "minor":
            return Version(self.major, self.minor + 1, 0)
        if impact == "patch":
            return Version(self.major, self.minor, self.patch + 1)
        return self


@dataclass(frozen=True)
class Status:
    latest_stable: Version | None
    calculated_target: Version
    version_target: Version
    matching_rc: str | None
    next_rc: str | None
    head: str
    version_matches: bool
    changelog_ok: bool


@dataclass(frozen=True)
class Config:
    version_file: str = "VERSION"
    changelog_file: str = "CHANGELOG.md"


@dataclass(frozen=True)
class CommitPolicy:
    impact_by_title: Mapping[str, str | None]
    changelog_titles: frozenset[str]


def git_env() -> dict[str, str]:
    env = os.environ.copy()
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE"):
        env.pop(key, None)
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    return env


def git(args: Sequence[str], cwd: Path, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(cwd), *args],
        cwd=cwd,
        text=True,
        capture_output=True,
        check=check,
        env=git_env(),
    )


def repo_root(cwd: Path | None = None) -> Path:
    start = cwd or Path.cwd()
    result = git(["rev-parse", "--show-toplevel"], cwd=start, check=False)
    if result.returncode != 0:
        raise ReleaseError("release must run from a Git repository")
    root = Path(result.stdout.strip())
    if not (root / ".git").is_dir():
        raise ReleaseError("release requires a colocated .git directory")
    return root


def head_sha(root: Path) -> str:
    return git(["rev-parse", "HEAD"], cwd=root).stdout.strip()


def is_dirty(root: Path) -> bool:
    status = git(["status", "--porcelain"], cwd=root).stdout
    return bool(status.strip())


def list_tags(root: Path) -> list[str]:
    out = git(["tag", "--list"], cwd=root).stdout.splitlines()
    return [line.strip() for line in out if line.strip()]


def peel_tag(root: Path, tag: str) -> str:
    return git(["rev-parse", f"{tag}^{{commit}}"], cwd=root).stdout.strip()


def reachable_from_head(root: Path, sha: str) -> bool:
    result = git(["merge-base", "--is-ancestor", sha, "HEAD"], cwd=root, check=False)
    return result.returncode == 0


def parse_stable_tag(tag: str) -> Version | None:
    match = STABLE_TAG.fullmatch(tag)
    if not match:
        return None
    return Version(int(match[1]), int(match[2]), int(match[3]))


def parse_rc_tag(tag: str) -> tuple[Version, int] | None:
    match = RC_TAG.fullmatch(tag)
    if not match:
        return None
    return Version(int(match[1]), int(match[2]), int(match[3])), int(match[4])


def latest_stable(root: Path, tags: Sequence[str]) -> tuple[Version, str] | None:
    found: list[tuple[Version, str]] = []
    for tag in tags:
        version = parse_stable_tag(tag)
        if version is None:
            continue
        sha = peel_tag(root, tag)
        if reachable_from_head(root, sha):
            found.append((version, tag))
    if not found:
        return None
    version, tag = max(found, key=lambda item: item[0].tuple)
    return version, tag


def range_args(since_tag: str | None) -> list[str]:
    return [f"{since_tag}..HEAD"] if since_tag else ["..HEAD"]


def cog(args: Sequence[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["cog", *args],
        cwd=cwd,
        text=True,
        capture_output=True,
        check=False,
        env=git_env(),
    )


def cog_check(root: Path, since_tag: str | None) -> None:
    result = cog(["check", *range_args(since_tag)], root)
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip() or "cog check failed"
        raise ReleaseError(message)


def cog_template(root: Path, since_tag: str | None, template: str) -> str:
    with NamedTemporaryFile("w", suffix=".tera", delete=False) as handle:
        handle.write(template)
        path = handle.name
    try:
        result = cog(["changelog", *range_args(since_tag), "--template", path], root)
    finally:
        Path(path).unlink(missing_ok=True)
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip() or "cog changelog failed"
        raise ReleaseError(message)
    return result.stdout


def load_commit_policy(root: Path) -> CommitPolicy:
    path = root / "cog.toml"
    if not path.is_file():
        raise ReleaseError("missing cog.toml")
    with path.open("rb") as handle:
        data = tomllib.load(handle)
    raw = data.get("commit_types")
    if not isinstance(raw, dict) or not raw:
        raise ReleaseError("cog.toml must define [commit_types]")
    impact_by_title: dict[str, str | None] = {}
    changelog_titles: set[str] = set()
    for name, spec in raw.items():
        if not isinstance(spec, dict):
            raise ReleaseError(f"commit type {name!r} must be a table")
        title = spec.get("changelog_title")
        if not isinstance(title, str) or not title:
            raise ReleaseError(f"commit type {name!r} must set changelog_title")
        omit = bool(spec.get("omit_from_changelog", False))
        bump_minor = bool(spec.get("bump_minor", False))
        bump_patch = bool(spec.get("bump_patch", False))
        if bump_minor and bump_patch:
            raise ReleaseError(f"commit type {name!r} cannot bump both minor and patch")
        impact: str | None
        if bump_minor:
            impact = "minor"
        elif bump_patch:
            impact = "patch"
        else:
            impact = None
        impact_by_title[title] = impact
        if not omit:
            changelog_titles.add(title)
    return CommitPolicy(impact_by_title=impact_by_title, changelog_titles=frozenset(changelog_titles))


def parse_commit_line(line: str) -> tuple[str, bool, str, str] | None:
    if not line.strip() or "\t" not in line:
        return None
    parts = line.split("\t", 3)
    if len(parts) < 4:
        raise ReleaseError(f"malformed cog changelog line: {line!r}")
    kind, breaking_text, commit_id, summary = parts
    breaking = breaking_text.strip().lower() == "true"
    return kind, breaking, commit_id, summary


def changes_since(
    root: Path, since_tag: str | None, policy: CommitPolicy
) -> tuple[list[str], str]:
    cog_check(root, since_tag)
    output = cog_template(root, since_tag, COMMIT_TEMPLATE)
    impacts = []
    lines = []
    for line in output.splitlines():
        parsed = parse_commit_line(line)
        if parsed is None:
            continue
        kind, breaking, commit_id, summary = parsed
        impact = "major" if breaking else policy.impact_by_title.get(kind)
        if impact:
            impacts.append(impact)
        if breaking or kind in policy.changelog_titles:
            lines.append(f"- {commit_id} - {summary}")
    return impacts, "\n".join(lines)


def release_content(
    root: Path, config: Config, latest: Version | None, since_tag: str | None, policy: CommitPolicy
) -> tuple[Version, str]:
    impacts, body = changes_since(root, since_tag, policy)
    rank = {"patch": 1, "minor": 2, "major": 3}
    if latest is None:
        target = read_version(root, config)
    elif not impacts:
        target = latest
    elif latest == Version(0, 0, 0):
        target = Version(1, 0, 0)
    else:
        target = latest.bump(max(impacts, key=lambda impact: rank[impact]))
    return target, body


def split_changelog(text: str) -> tuple[str, list[tuple[str, str]]]:
    matches = list(CHANGELOG_HEADING.finditer(text))
    if not matches:
        prefix = text.rstrip() + "\n\n" if text.strip() else "# Changelog\n\n"
        return prefix, []
    prefix = text[: matches[0].start()]
    sections: list[tuple[str, str]] = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        sections.append((match.group(1), text[match.start() : end]))
    return prefix, sections


def render_section(version: Version, body: str) -> str:
    notes = body.strip()
    if notes:
        return f"## {version}\n\n{notes}\n"
    return f"## {version}\n"


def expected_files(
    root: Path, config: Config, latest: tuple[Version, str] | None
) -> tuple[Version, str, str]:
    latest_version = latest[0] if latest else None
    since = latest[1] if latest else None
    policy = load_commit_policy(root)
    target, body = release_content(root, config, latest_version, since, policy)
    changelog_path = root / config.changelog_file
    current = changelog_path.read_text() if changelog_path.exists() else "# Changelog\n"
    prefix, sections = split_changelog(current)
    preserved: list[str] = []
    for heading, section in sections:
        if "-rc." in heading:
            continue
        try:
            version = Version.parse(heading)
        except ReleaseError:
            continue
        if latest_version is None:
            continue
        if version.tuple <= latest_version.tuple:
            preserved.append(section)
    if latest_version is None or target != latest_version:
        prospective = render_section(target, body)
        parts = [prefix.rstrip("\n") + "\n\n", prospective]
        if preserved:
            history = "".join(preserved)
            if not history.startswith("\n") and not prospective.endswith("\n\n"):
                parts.append("\n")
            parts.append(history)
        changelog = "".join(parts)
    else:
        if preserved:
            changelog = prefix + "".join(preserved)
        else:
            changelog = prefix.rstrip("\n") + "\n\n" + render_section(target, body)
    if not changelog.endswith("\n"):
        changelog += "\n"
    return target, f"{target}\n", changelog


def cmd_prepare(root: Path, config: Config, check: bool) -> int:
    latest = latest_stable(root, list_tags(root))
    _target, version_text, changelog = expected_files(root, config, latest)
    version_path = root / config.version_file
    changelog_path = root / config.changelog_file
    version_bytes = version_text.encode()
    changelog_bytes = changelog.encode()
    current_version = version_path.read_bytes() if version_path.exists() else b""
    current_changelog = changelog_path.read_bytes() if changelog_path.exists() else b""
    if check:
        if current_version == version_bytes and current_changelog == changelog_bytes:
            return 0
        raise ReleaseError("VERSION or CHANGELOG.md does not match calculated prepare output")
    version_path.write_bytes(version_bytes)
    changelog_path.write_bytes(changelog_bytes)
    return 0


def read_version(root: Path, config: Config) -> Version:
    path = root / config.version_file
    if not path.exists():
        raise ReleaseError(f"missing {config.version_file}")
    return Version.parse(path.read_text())


def rcs_for_target(tags: Sequence[str], target: Version) -> list[tuple[int, str]]:
    found = []
    for tag in tags:
        parsed = parse_rc_tag(tag)
        if parsed is None:
            continue
        version, n = parsed
        if version == target:
            found.append((n, tag))
    return sorted(found)


def matching_rc(root: Path, tags: Sequence[str], target: Version, head: str) -> str | None:
    matches = []
    for n, tag in rcs_for_target(tags, target):
        if peel_tag(root, tag) == head:
            matches.append((n, tag))
    if not matches:
        return None
    return max(matches)[1]


def next_rc_tag(tags: Sequence[str], target: Version) -> str:
    existing = rcs_for_target(tags, target)
    n = existing[-1][0] + 1 if existing else 1
    return f"v{target}-rc.{n}"


def collect_status(root: Path, config: Config) -> Status:
    tags = list_tags(root)
    latest = latest_stable(root, tags)
    latest_version = latest[0] if latest else None
    target, version_text, changelog = expected_files(root, config, latest)
    releasable = latest_version is None or target != latest_version
    version = read_version(root, config)
    head = head_sha(root)
    version_path = root / config.version_file
    changelog_path = root / config.changelog_file
    current_version = version_path.read_bytes()
    current_changelog = changelog_path.read_bytes() if changelog_path.exists() else b""
    return Status(
        latest_stable=latest_version,
        calculated_target=target,
        version_target=version,
        matching_rc=matching_rc(root, tags, target, head),
        next_rc=next_rc_tag(tags, target) if releasable else None,
        head=head,
        version_matches=current_version == version_text.encode(),
        changelog_ok=current_changelog == changelog.encode(),
    )


def format_status(status: Status) -> str:
    latest = str(status.latest_stable) if status.latest_stable else "none"
    matching = status.matching_rc or "none"
    return "\n".join(
        [
            f"latest stable: {latest}",
            f"calculated target: {status.calculated_target}",
            f"VERSION target: {status.version_target}",
            f"current matching RC: {matching}",
            f"next RC: {status.next_rc or f'none (nothing to release since v{latest})'}",
        ]
    )


def require_ready(status: Status) -> None:
    if not status.version_matches:
        raise ReleaseError(
            f"VERSION {status.version_target} does not match calculated prepare output for {status.calculated_target}"
        )
    if not status.changelog_ok:
        raise ReleaseError("CHANGELOG.md does not match calculated prepare output")


def create_tag(root: Path, tag: str) -> None:
    result = git(["-c", "tag.gpgSign=false", "tag", tag], cwd=root, check=False)
    if result.returncode != 0:
        raise ReleaseError(result.stderr.strip() or f"failed to create tag {tag}")


def cmd_status(root: Path, config: Config) -> int:
    print(format_status(collect_status(root, config)))
    return 0


def previous_rc(root: Path, version: Version, number: int) -> str | None:
    for n, tag in reversed(rcs_for_target(list_tags(root), version)):
        if n < number and reachable_from_head(root, peel_tag(root, tag)):
            return tag
    return None


def cmd_notes(root: Path, config: Config, tag: str) -> int:
    rc = parse_rc_tag(tag)
    version = rc[0] if rc else parse_stable_tag(tag)
    if version is None:
        raise ReleaseError(f"invalid release tag: {tag!r}")
    path = root / config.changelog_file
    if not path.exists():
        raise ReleaseError(f"missing {config.changelog_file}")
    _, sections = split_changelog(path.read_text())
    for heading, section in sections:
        if heading == str(version):
            previous = previous_rc(root, *rc) if rc else None
            if previous:
                _, body = changes_since(root, previous, load_commit_policy(root))
                body = body or "No changelog entries since this RC."
                section = f"## Changes since {previous}\n\n{body}\n"
            print(section, end="")
            return 0
    raise ReleaseError(f"missing changelog section {version} in {config.changelog_file}")


def cmd_rc(root: Path, config: Config) -> int:
    if is_dirty(root):
        raise ReleaseError("working tree is dirty")
    status = collect_status(root, config)
    require_ready(status)
    if status.matching_rc:
        print(status.matching_rc)
        return 0
    if status.next_rc is None:
        raise ReleaseError(
            f"nothing to release: no release-impacting commits since v{status.latest_stable}"
        )
    tag = status.next_rc
    create_tag(root, tag)
    print(tag)
    return 0


def cmd_stable(root: Path, config: Config) -> int:
    if is_dirty(root):
        raise ReleaseError("working tree is dirty")
    tags = list_tags(root)
    version = read_version(root, config)
    head = head_sha(root)
    if not matching_rc(root, tags, version, head):
        status = collect_status(root, config)
        require_ready(status)
        version = status.calculated_target
    tag = f"v{version}"
    if tag in tags:
        if peel_tag(root, tag) != head:
            raise ReleaseError(f"{tag} already exists on a different commit")
    else:
        create_tag(root, tag)
    print(tag)
    return 0


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="release")
    parser.add_argument("--version-file", default=os.environ.get("RELEASE_VERSION_FILE", "VERSION"))
    parser.add_argument("--changelog-file", default=os.environ.get("RELEASE_CHANGELOG_FILE", "CHANGELOG.md"))
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("rc")
    sub.add_parser("stable")
    notes = sub.add_parser("notes")
    notes.add_argument("tag")
    prepare = sub.add_parser("prepare")
    prepare.add_argument("--check", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    config = Config(version_file=args.version_file, changelog_file=args.changelog_file)
    try:
        root = repo_root()
        if args.command == "status":
            return cmd_status(root, config)
        if args.command == "notes":
            return cmd_notes(root, config, args.tag)
        if args.command == "prepare":
            return cmd_prepare(root, config, args.check)
        if args.command == "rc":
            return cmd_rc(root, config)
        if args.command == "stable":
            return cmd_stable(root, config)
        raise ReleaseError(f"unknown command {args.command}")
    except ReleaseError as error:
        print(f"release: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
