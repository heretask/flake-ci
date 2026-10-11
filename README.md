# flake-ci

A [flake-parts](https://flake.parts) module for repository automation, configured through `ci.*`:

- **Commit convention**: one list of Conventional Commit types drives commitlint (`nix run .#commitlint`), the PR-title check, and `cog.toml`.
- **Signoff**: `nix run .#signoff` runs `nix flake check`, then marks the tested commit with [gh-signoff](https://github.com/basecamp/gh-signoff). Works from Git and Jujutsu.
- **Releases**: `nix run .#release` prepares `VERSION`/`CHANGELOG.md` with [cocogitto](https://github.com/cocogitto/cocogitto), tags rc and stable releases, and advances channel branches from a dispatched workflow.
- **GitHub workflows**: PR-title lint, flake check on `main`, optional macOS check, scheduled flake-input update PRs, and release workflows, rendered into `.github/workflows`.
- **Nix formatting**: alejandra, statix, and deadnix through [treefmt-nix](https://github.com/numtide/treefmt-nix).

Generated files (workflows, `cog.toml`) are committed and written by [mightyiam/files](https://github.com/mightyiam/files): `nix run .#write-files` regenerates them, and each has a `files:<path>` check that fails when it is stale. `checks.workflow-orphans` fails on workflow files that no `ci.github.workflows` entry owns.

## Use

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    ci = {
      url = "github:heretask/flake-ci";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-darwin"];
      imports = [inputs.ci.flakeModules.default];

      ci = {
        github.inputUpdates.some-input.schedule = "17 4 * * *";
        release = {
          enable = true;
          repository = "owner/repo";
          appToken = {
            clientIdVariable = "RELEASE_APP_CLIENT_ID";
            privateKeySecret = "RELEASE_APP_PRIVATE_KEY";
          };
        };
        nixFormat = {
          enable = true;
          paths = ["flake.nix" "nix"];
        };
      };
    };
}
```

Then run `nix run .#write-files` and commit the generated files.

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `ci.commits.types.<type>.{title,bump}` | `feat`, `fix`, `improvement`, `perf`, `refactor`, `revert` (bumping); `build`, `chore`, `ci`, `docs`, `style`, `test` | Allowed types, changelog title, SemVer bump (`null` omits from the changelog). Defaults merge per type; replace the set with `lib.mkForce`. |
| `ci.commits.maxLength` | `72` | Maximum description length. |
| `ci.signoff.enable` | `true` | `signoff` package and app. |
| `ci.github.enable` | `true` | Generated workflows. |
| `ci.github.runner` | `"ubuntu-24.04"` | Linux runner. |
| `ci.github.flakeCheck.runner` | `ci.github.runner` | Runner for the flake-check job, e.g. a larger runner. |
| `ci.github.flakeCheck.timeoutMinutes` | `30` | Timeout in minutes for the flake-check job. |
| `ci.github.flakeCheck.reclaimDisk` | `"foreground"` | `"background"` frees preinstalled toolchains from the runner disk without blocking the flake-check job. See [Runner disk](#runner-disk). |
| `ci.github.flakeCheck.queue` | `false` | `true` runs main's flake checks one at a time in push order. See [Queued checks](#queued-checks). |
| `ci.github.cache` | `"magic-nix-cache"` | Nix binary cache for flake-check jobs: `"magic-nix-cache"` or `"hestia"`. |
| `ci.github.darwinCheck` | `false` | Manually dispatched flake check on macOS. |
| `ci.github.extraNixConfig` | `""` | Extra `nix.conf` lines for the Nix installer, e.g. binary caches. |
| `ci.github.inputUpdates.<input>.schedule` | `{}` | Scheduled PR updating one flake input. |
| `ci.github.workflows.<stem>` | presets | Add workflows or override preset fields. |
| `ci.release.enable` | `false` | `release` app, generated `cog.toml`, Release workflow. |
| `ci.release.repository` | — | `owner/repo` for changelog links. |
| `ci.release.branches.{rc,stable}` | `"unstable"`, `"stable"` | Channel branches. |
| `ci.release.appToken.{clientIdVariable,privateKeySecret}` | — | GitHub App credentials the release workflows use. |
| `ci.release.notify.{repository,eventType}` | `null` | `repository_dispatch` to another repository when a channel branch moves. |
| `ci.nixFormat.{enable,paths,excludes}` | off | treefmt Nix formatters and `checks.treefmt` over `paths`. |

Every workflow runs Nix with `--option accept-flake-config false`.

## Hestia cache

Set `ci.github.cache = "hestia";` to use [Mic92/hestia](https://github.com/Mic92/hestia) instead of Magic Nix Cache for flake-check jobs. Magic Nix Cache hits GitHub's Actions cache rate limit (1500 downloads per minute per repository) and then disables itself for the rest of the run. Hestia stores NARs as a few large chunked packs, so it needs far fewer cache entries. In this mode the hestia step is pinned to v3.1.0, flake-check jobs get `actions: read` for hestia's eviction check, and the Check flake step times out 10 minutes before its job so hestia's upload drain still runs. A daily `hestia-gc` workflow with `actions: write` garbage-collects the cache.

## Runner disk

GitHub's `ubuntu-24.04` runner starts with about 14 GB free. The flake-check job removes GHC, Android and .NET first, which frees about 20 GB more but took 41-79 s in measured runs. With `ci.github.flakeCheck.reclaimDisk = "background";` the removal runs detached and the job moves straight on to installing Nix. Builds start on the 14 GB already free. In measured runs the removal finished 71-120 s later, while Nix installed, the flake evaluated and the first builds ran. Its output goes to `$RUNNER_TEMP/reclaim-disk.log`.

[nothing-but-nix](https://github.com/wimpysworld/nothing-but-nix) mounts `/nix` on a btrfs volume carved from a separate `/mnt` disk. The 2-vCPU private-repository runners have no separate disk, so its `holster` mode leaves `/` with under 1 GB free and a 13 GB `/nix`, and its default `cleave` mode blocks for 45-63 s.

## Queued checks

By default each push to `main` gets its own flake-check run, and runs overlap. A run uploads its builds to the cache only when it finishes, so a run that starts while another is still building rebuilds the same derivations. With `ci.github.flakeCheck.queue = true;` the workflow uses one concurrency group per branch with GitHub's `queue: max`: runs wait and start one at a time, oldest first, so each one reuses what the previous run uploaded. Every commit still gets its own result, up to 100 waiting runs, which matters if a release checks for a successful run on an exact commit. A burst of pushes now takes longer to reach the newest commit, since its run waits for the ones before it.

## Development

`nix flake check` runs the tool self-tests against a fixture consumer (`tests/`) plus this repository's own generated files and formatting.
