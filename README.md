# flake-ci

A [flake-parts](https://flake.parts) module for repository automation, configured through `ci.*`:

- **Commit convention**: one list of Conventional Commit types and scopes drives commitlint (`nix run .#commitlint`), the PR-title check, and `cog.toml`. commitlint and the PR-title check share one script, so both name the exact problem: an unknown type or scope, a tooling scope on a changelog type (with the `chore(scope): …` to use instead), a missing `: `, or the characters over the limit.
- **Signoff**: `nix run .#signoff` runs `nix flake check`, then marks the tested commit with [gh-signoff](https://github.com/basecamp/gh-signoff). Works from Git and Jujutsu. With `ci.signoff.skipChecks` set, it runs `nix flake check --no-build`, builds every other check of the current system in one `nix build`, and names the skipped checks.
- **Releases**: `nix run .#release` prepares `VERSION`/`CHANGELOG.md` with [cocogitto](https://github.com/cocogitto/cocogitto), tags rc and stable releases, and advances channel branches from a dispatched workflow. Changelog sections follow the [Ash](https://github.com/ash-project/ash/blob/main/CHANGELOG.md) style: a compare link and the date of the newest entry in the heading, breaking changes first, then one section per commit type in `cog.toml` order, each entry crediting its author (`@handle` for GitHub noreply emails) and linking the `(#N)` pull request.
  One `Release` run prepares `main` (the release App pushes the `VERSION`/`CHANGELOG.md` commit itself, so it must be allowed to bypass the rules on `main`), waits for the flake check on that commit unless `skip_ci` is set, then tags and moves the channel. `release stable` needs no RC: it tags any prepared commit, whether or not an RC points at it.
- **GitHub workflows**: PR-title lint, flake check on `main`, optional macOS check, scheduled flake-input update PRs, and release workflows, rendered into `.github/workflows`.
- **Nix formatting**: alejandra, statix, and deadnix through [treefmt-nix](https://github.com/numtide/treefmt-nix).
- **Vulnerability scanning**: `nix run .#vuln -- <target>` scans runtime closures, release directories, and lockfiles with pinned sbomnix, grype, and osv-scanner. Also available alone as `flakeModules.vuln`. See [Vulnerability scanning](#vulnerability-scanning).

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
| `ci.commits.maxLength` | `72` | Maximum description length in characters, after `type(scope): `. The ` (#123)` suffix of a squash merge does not count. |
| `ci.commits.scopes.changelog` | `[]` | Scopes allowed on bumping types, in changelog order. Empty allows any scope on any type. |
| `ci.commits.scopes.other` | `[]` | Scopes allowed only on non-bumping types. The PR-title check and commitlint reject e.g. `feat(nix)`; the changelog drops entries with these scopes and they do not bump the version. |
| `ci.signoff.enable` | `true` | `signoff` package and app. |
| `ci.signoff.skipChecks` | `[]` | `checks` attributes `signoff` does not build; `nix flake check` and main's workflow still build them. |
| `ci.github.enable` | `true` | Generated workflows. |
| `ci.github.runner` | `"ubuntu-24.04"` | Linux runner. |
| `ci.github.flakeCheck.enable` | `true` | `false` drops the `nix-check` workflow, for a repository that checks its flake in its own workflow. The Release workflow needs it. |
| `ci.github.flakeCheck.runner` | `ci.github.runner` | Runner for the flake-check job, e.g. a larger runner. |
| `ci.github.flakeCheck.timeoutMinutes` | `30` | Timeout in minutes for the flake-check job. |
| `ci.github.flakeCheck.reclaimDisk` | `"foreground"` | `"background"` frees preinstalled toolchains from the runner disk without blocking the flake-check job. See [Runner disk](#runner-disk). |
| `ci.github.flakeCheck.queue` | `false` | `true` runs main's flake checks one at a time in push order. See [Queued checks](#queued-checks). |
| `ci.github.flakeCheck.matrix` | `false` | `true` replaces the flake-check job with an eval job and one build job per uncached check. Needs `ci.github.cache = "hestia"`. See [Build matrix](#build-matrix). |
| `ci.github.cache` | `"magic-nix-cache"` | Nix binary cache for flake-check jobs: `"magic-nix-cache"` or `"hestia"`. |
| `ci.github.darwinCheck` | `false` | Manually dispatched flake check on macOS. |
| `ci.github.extraNixConfig` | `""` | Extra `nix.conf` lines for the Nix installer, e.g. binary caches. |
| `ci.github.inputUpdates.<input>.schedule` | `{}` | Scheduled PR updating one flake input. |
| `ci.github.inputUpdates.<input>.appToken.{clientIdVariable,privateKeySecret}` | `null` | GitHub App that opens the update PR, so the PR's checks run. Without it the PR is opened with the workflow's token, which starts no workflows. |
| `ci.github.workflows.<stem>` | presets | Add workflows or override preset fields. |
| `ci.github.handWritten` | `[]` | Stems of committed workflows written by hand. `workflow-orphans` accepts them and `actionlint` checks them. |
| `ci.release.enable` | `false` | `release` app, generated `cog.toml`, Release workflow. |
| `ci.release.repository` | — | `owner/repo` for changelog links. |
| `ci.release.branches.{rc,stable}` | `"unstable"`, `"stable"` | Channel branches. |
| `ci.release.appToken.{clientIdVariable,privateKeySecret}` | — | GitHub App credentials the release workflows use. |
| `ci.release.notify.{repository,eventType}` | `null` | `repository_dispatch` to another repository when a channel branch moves. |
| `ci.release.notify.prebuildEventType` | `null` | Second `repository_dispatch`, sent when a release is requested, so the receiver can build the commit before the channel moves. |
| `ci.nixFormat.{enable,paths,excludes}` | off | treefmt Nix formatters and `checks.treefmt` over `paths`. |
| `ci.vuln.targets.<name>.{closures,dirs,lockfiles,accepts}` | `{}` | Vulnerability scan targets, per system. See [Vulnerability scanning](#vulnerability-scanning). |

Every workflow runs Nix with `--option accept-flake-config false`.

## Hestia cache

Set `ci.github.cache = "hestia";` to use [Mic92/hestia](https://github.com/Mic92/hestia) instead of Magic Nix Cache for flake-check jobs. Magic Nix Cache hits GitHub's Actions cache rate limit (1500 downloads per minute per repository) and then disables itself for the rest of the run. Hestia stores NARs as a few large chunked packs, so it needs far fewer cache entries. In this mode the hestia step is pinned to v3.1.0, flake-check jobs get `actions: read` for hestia's eviction check, and the Check flake step times out 10 minutes before its job so hestia's upload drain still runs. A daily `hestia-gc` workflow with `actions: write` garbage-collects the cache.

## Runner disk

GitHub's `ubuntu-24.04` runner starts with about 14 GB free. The flake-check job removes GHC, Android and .NET first, which frees about 20 GB more but took 41-79 s in measured runs. With `ci.github.flakeCheck.reclaimDisk = "background";` the removal runs detached and the job moves straight on to installing Nix. Builds start on the 14 GB already free. In measured runs the removal finished 71-120 s later, while Nix installed, the flake evaluated and the first builds ran. Its output goes to `$RUNNER_TEMP/reclaim-disk.log`.

[nothing-but-nix](https://github.com/wimpysworld/nothing-but-nix) mounts `/nix` on a btrfs volume carved from a separate `/mnt` disk. The 2-vCPU private-repository runners have no separate disk, so its `holster` mode leaves `/` with under 1 GB free and a 13 GB `/nix`, and its default `cleave` mode blocks for 45-63 s.

## Queued checks

By default each push to `main` gets its own flake-check run, and runs overlap. A run uploads its builds to the cache only when it finishes, so a run that starts while another is still building rebuilds the same derivations. With `ci.github.flakeCheck.queue = true;` the workflow uses one concurrency group per branch with GitHub's `queue: max`: runs wait and start one at a time, oldest first, so each one reuses what the previous run uploaded. Every commit still gets its own result, up to 100 waiting runs, which matters if a release checks for a successful run on an exact commit. A burst of pushes now takes longer to reach the newest commit, since its run waits for the ones before it.

## Build matrix

With `ci.github.flakeCheck.matrix = true;` (and `ci.github.cache = "hestia";`) the flake-check job becomes two job kinds, built with [hestia's build matrix](https://github.com/Mic92/hestia#build-matrix-eval-once-build-in-parallel):

- `eval` evaluates the flake once with `nix flake check --no-build`, lints the pushed commit, and lists the checks whose outputs are not cached yet.
- One `build` job per listed check runs on its own runner, so checks build in parallel. Cached checks get no job.

Checks with the same `meta.hestia.group` share one runner, and `meta.hestia.os` overrides a check's runner labels. flake-ci's own light checks (`workflow-orphans`, `actionlint`, and `checks.treefmt`) use the group `"light"`; put your small checks in that group too.

The matrix covers `.#checks.x86_64-linux` only: a Linux runner cannot build other systems' checks, and hestia's default runner map would send darwin checks to macOS runners. Uncached dependencies shared by several checks are built by each job that needs them. Hestia limits a matrix to 256 jobs. `nix-eval-jobs` comes from the runner's nixpkgs registry, not from flake-ci's pinned nixpkgs.

## Vulnerability scanning

Declare targets under `perSystem`. Every field is a list, defaulting to `[]`:

```nix
perSystem = {config, ...}: {
  ci.vuln.targets.api = {
    closures = [config.packages.server];       # runtime closure: sbomnix SBOM, then grype
    dirs = [config.packages.api];              # grype dir:, e.g. Erlang/OTP and Elixir in a Mix release
    lockfiles = ["${self}/api/mix.lock"];      # osv-scanner; a string, so the file name survives
    accepts = [
      {
        id = "CVE-2026-117656";                # any alias works
        package = "assent";                    # optional; narrows closures and dirs only
        reason = "Only used in dev";
        until = "2027-01-31";
      }
    ];
  };
};
```

`nix run .#vuln -- api` exits 0 when the target is clear and non-zero on a finding or any scanner error. `--quick` runs only the lockfile lane and builds nothing, for PR checks. `packages.vuln` and `apps.vuln` exist once a target is declared.

| Lane | Scanner | Fails on |
| --- | --- | --- |
| `lockfiles` | `osv-scanner scan source` | any finding not accepted |
| `closures` | sbomnix CycloneDX SBOM, then `grype sbom:` | a fixed high or critical finding |
| `closures`, Alpine pass | the same SBOM with each versioned package relabelled `pkg:apk/alpine/<name>@<version>-r0`, then `grype sbom:` | a fixed high or critical finding |
| `dirs` | `grype dir:` | a fixed high or critical finding |

The Alpine pass matches packages against Alpine's security database, which often lists a fix before NVD gives it a CPE. A CVE that a nixpkgs patch resolves (sbomnix records it in `pedigree`) is ignored for that package name and version only. An accept stops applying after its `until` date, so the finding fails the scan again. osv-scanner ignores by ID only, so `package` does not narrow an accept in the lockfile lane.

Each target is also published as plain data at `vuln.<system>.<name>`, derivations as `"<drv>^<output>"` strings. Another flake adds to it with `lib.mkMerge`, keeping both repositories' accepts:

```nix
perSystem = {system, ...}: {
  ci.vuln.targets.prod = lib.mkMerge [
    inputs.platform.vuln.${system}.api
    {closures = [self.nixosConfigurations.prod.config.system.build.toplevel];}
  ];
};
```

The scanners come from flake-ci's own `nixpkgs-vuln` input, not from the `nixpkgs` a consumer makes flake-ci follow. sbomnix before 1.9.0 labels the kernel, glibc, and curl with CPE vendors NVD does not use, which hides every finding for them. `nix` comes from `PATH`.

## Development

`nix flake check` runs the tool self-tests against a fixture consumer (`tests/`) plus this repository's own generated files and formatting.

`nix run .#vuln-selftest` (Linux) checks the pinned scanners against the live grype database: sbomnix must label the kernel `o:linux:linux_kernel`, glibc `gnu:glibc` and curl `haxx:curl`, and grype must report NGINX2Shell (CVE-2026-123007) for nginx 1.30.4. It reads the build graph of a canary derivation, so it downloads only the grype database. The `vuln-selftest` workflow runs it weekly and on PRs that touch `flake.lock` or the scanner, and fails when `nixpkgs` or `nixpkgs-vuln` is locked to a revision older than 30 days. `nixpkgs` and `nixpkgs-vuln` get weekly update PRs.
