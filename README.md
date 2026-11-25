# flake-ci

A [flake-parts](https://flake.parts) module for repository automation, configured through `ci.*`:

- **Commit convention**: one list of Conventional Commit types and scopes drives commitlint (`nix run .#commitlint`), the PR-title check, and `cog.toml`. commitlint and the PR-title check share one script, so both name the exact problem: an unknown type or scope, a tooling scope on a changelog type (with the `chore(scope): …` to use instead), a missing `: `, or the characters over the limit.
- **Signoff**: `nix run .#signoff` runs `nix flake check`, then marks the tested commit with [gh-signoff](https://github.com/basecamp/gh-signoff). Works from Git and Jujutsu. With `ci.signoff.skipChecks` set, it runs `nix flake check --no-build`, builds every other check of the current system in one `nix build`, and names the skipped checks.
- **Releases**: `nix run .#release` prepares `VERSION`/`CHANGELOG.md` with [cocogitto](https://github.com/cocogitto/cocogitto), tags rc and stable releases, and advances channel branches from a dispatched workflow. Changelog sections follow the [Ash](https://github.com/ash-project/ash/blob/main/CHANGELOG.md) style: a compare link and the date of the newest entry in the heading, breaking changes first, then one section per commit type in `cog.toml` order, each entry crediting its author (`@handle` for GitHub noreply emails) and linking the `(#N)` pull request.
  One `Release` run prepares `main` (the release App pushes the `VERSION`/`CHANGELOG.md` commit itself, so it must be allowed to bypass the rules on `main`), waits for the flake check on that commit unless `skip_ci` is set, then tags and moves the channel. `release stable` needs no RC: it tags any prepared commit, whether or not an RC points at it.
- **GitHub workflows**: PR-title lint, flake check on `main`, optional macOS check, scheduled flake-input update PRs, and release workflows, rendered into `.github/workflows`.
- **Nix formatting**: alejandra, statix, and deadnix through [treefmt-nix](https://github.com/numtide/treefmt-nix).
- **Vulnerability scanning**: `nix run .#vuln -- <target>` scans runtime closures, release directories, and lockfiles with pinned vulnxscan (sbomnix, grype, vulnix), grype, and osv-scanner, and reports what it finds as a summary and as JSON. `ci.github.vuln` generates the workflows that run it on a schedule and on changes. Also available alone as `flakeModules.vuln`. See [Vulnerability scanning](#vulnerability-scanning).

Generated files (workflows, `cog.toml`) are committed and written by [mightyiam/files](https://github.com/mightyiam/files): `nix run .#write-files` regenerates them, and each has a `files:<path>` check that fails when it is stale. A check depends only on its own committed file and what generates it, so a binary cache skips it on commits that touch neither. `checks.workflow-orphans` fails on workflow files that no `ci.github.workflows` entry owns.

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
| `ci.github.flakeCheck.pullRequests.enable` | `false` | Run Nix on same-repository PR heads and publish `signoff` on success. Requires `flakeCheck.enable`. |
| `ci.github.flakeCheck.pullRequests.skipChecks` | `ci.signoff.skipChecks` | Names of flake checks to omit from PR builds. Use `[]` for the full suite. |
| `ci.github.flakeCheck.runner` | `ci.github.runner` | Runner for the flake-check job, e.g. a larger runner. |
| `ci.github.flakeCheck.timeoutMinutes` | `30` | Timeout in minutes for the flake-check job. |
| `ci.github.flakeCheck.reclaimDisk` | `"foreground"` | `"background"` frees preinstalled toolchains from the runner disk without blocking the flake-check job. `"nothing-but-nix"` gives `/nix` its own volume instead. See [Runner disk](#runner-disk). |
| `ci.github.flakeCheck.queue` | `false` | `true` runs main's flake checks one at a time in push order. See [Queued checks](#queued-checks). |
| `ci.github.flakeCheck.matrix` | `false` | `true` replaces the flake-check job with an eval job and one build job per uncached check. Needs `ci.github.cache = "hestia"`. See [Build matrix](#build-matrix). |
| `ci.github.cache` | `"magic-nix-cache"` | Nix binary cache for flake-check jobs: `"magic-nix-cache"` or `"hestia"`. |
| `ci.github.hestiaGc.pushTtlDays` | `null` | Days `hestia-gc` keeps a store path after its last push; `null` is hestia's default of 14. See [Hestia cache](#hestia-cache). |
| `ci.github.darwinCheck` | `false` | Manually dispatched flake check on macOS. |
| `ci.github.extraNixConfig` | `""` | Extra `nix.conf` lines for the Nix installer, e.g. binary caches. |
| `ci.github.inputUpdates.<input>.schedule` | `{}` | Scheduled PR updating one flake input. |
| `ci.github.inputUpdates.<input>.appToken.{clientIdVariable,privateKeySecret}` | `null` | GitHub App that opens the update PR, so the PR's checks run. Without it the PR is opened with the workflow's token, which starts no workflows. |
| `ci.github.workflows.<stem>` | presets | Add workflows or override preset fields. |
| `ci.github.handWritten` | `[]` | Stems of committed workflows written by hand. `workflow-orphans` accepts them and `actionlint` checks them. |
| `ci.release.enable` | `false` | `release` app, generated `cog.toml`, Release workflow. |
| `ci.release.repository` | — | `owner/repo` for changelog links. |
| `ci.release.versionFile` | `self + "/VERSION"` | Path to the `VERSION` file read by `ci.release.version` and `ci.release.buildVersion`. |
| `ci.release.version` | read-only | Trimmed SemVer string read lazily from `ci.release.versionFile`. |
| `ci.release.buildVersion` | read-only | Environment-agnostic SemVer build ID `<VERSION>+<YYYYMMDDHHMM>.<shortRev>` derived lazily from `VERSION`, `self.lastModifiedDate`, and `self.shortRev`. |
| `ci.release.formatBuildVersion` | read-only | Function `{ version ? ci.release.version, lastModifiedDate ? self.lastModifiedDate or null, shortRev ? self.shortRev or null } -> string`. |
| `ci.release.checkVersionInvariance` | `false` | Add a `Check VERSION invariance` step to `nix-check` and `nix-check-pr` verifying `VERSION` bumps invalidate no check derivations. |
| `ci.release.branches.{rc,stable}` | `"unstable"`, `"stable"` | Channel branches. |
| `ci.release.appToken.{clientIdVariable,privateKeySecret}` | — | GitHub App credentials the release workflows use. |
| `ci.release.notify.{repository,eventType}` | `null` | `repository_dispatch` to another repository when a channel branch moves. |
| `ci.release.notify.prebuildEventType` | `null` | Second `repository_dispatch`, sent when a release is requested, so the receiver can build the commit before the channel moves. |
| `ci.nixFormat.{enable,paths,excludes}` | off | treefmt Nix formatters and `checks.treefmt` over `paths`. |
| `ci.vuln.targets.<name>.{closures,dirs,sboms,lockfiles,accepts}` | `{}` | Vulnerability scan targets, per system. See [Vulnerability scanning](#vulnerability-scanning). |

Every workflow runs Nix with `--option accept-flake-config false`.

## Hestia cache

Set `ci.github.cache = "hestia";` to use [Mic92/hestia](https://github.com/Mic92/hestia) instead of Magic Nix Cache for flake-check jobs. Magic Nix Cache hits GitHub's Actions cache rate limit (1500 downloads per minute per repository) and then disables itself for the rest of the run. Hestia stores NARs as a few large chunked packs, so it needs far fewer cache entries. In this mode the hestia step is pinned to v3.1.0, flake-check jobs get `actions: read` for hestia's eviction check, and the Check flake step times out 10 minutes before its job so hestia's upload drain still runs. A daily `hestia-gc` workflow with `actions: write` garbage-collects the cache.

Hestia refuses to read a cache manifest that decodes to more than 256 MiB ([Mic92/hestia#192](https://github.com/Mic92/hestia/issues/192)). Past that size flake-check jobs log `stored manifest is corrupt`, start from an empty cache and rebuild everything, and `hestia-gc` fails every night on the oversized manifest version. `hestia-gc` keeps every path pushed in the last 14 days, so a repository that pushes many paths can reach the limit before anything is collected. Set `ci.github.hestiaGc.pushTtlDays` lower, e.g. `3`, to collect unreferenced paths sooner.

## Runner disk

GitHub's `ubuntu-24.04` runner starts with about 14 GB free. The flake-check job removes GHC, Android and .NET first, which frees about 20 GB more but took 41-79 s in measured runs. With `ci.github.flakeCheck.reclaimDisk = "background";` the removal runs detached and the job moves straight on to installing Nix. Builds start on the 14 GB already free. In measured runs the removal finished 71-120 s later, while Nix installed, the flake evaluated and the first builds ran. Its output goes to `$RUNNER_TEMP/reclaim-disk.log`.

With `ci.github.flakeCheck.reclaimDisk = "nothing-but-nix";` the job runs [nothing-but-nix](https://github.com/wimpysworld/nothing-but-nix) v12 with its Carve protocol before installing Nix. It mounts `/nix` on a btrfs volume made from the runner's free disk, about 75 GiB on public x64 runners within seconds, and grows it to about 105 GiB as it removes Rust, GHC, Android, .NET, Swift and the tool cache in the background. Carve keeps Docker and every apt package. Private-repository runners have smaller disks, so `/nix` gets less.

## Queued checks

By default each push to `main` gets its own flake-check run, and runs overlap. A run uploads its builds to the cache only when it finishes, so a run that starts while another is still building rebuilds the same derivations. With `ci.github.flakeCheck.queue = true;` the workflow uses one concurrency group per branch with GitHub's `queue: max`: runs wait and start one at a time, oldest first, so each one reuses what the previous run uploaded. Every commit still gets its own result, up to 100 waiting runs, which matters if a release checks for a successful run on an exact commit. A burst of pushes now takes longer to reach the newest commit, since its run waits for the ones before it.

## Build matrix

With `ci.github.flakeCheck.matrix = true;` (and `ci.github.cache = "hestia";`) the flake-check job becomes two job kinds, built with [hestia's build matrix](https://github.com/Mic92/hestia#build-matrix-eval-once-build-in-parallel):

- `eval` evaluates the flake once with `nix flake check --no-build`, lints the pushed commit, and lists the checks whose outputs are not cached yet.
- One `build` job per listed check runs on its own runner, so checks build in parallel. Cached checks get no job.

Checks with the same `meta.hestia.group` share one runner, and `meta.hestia.os` overrides a check's runner labels. flake-ci's own light checks (`workflow-orphans`, `actionlint`, `checks.treefmt`, and the `files:<path>` checks) use the group `"light"`; put your small checks in that group too.

The matrix covers `.#checks.x86_64-linux` only: a Linux runner cannot build other systems' checks, and hestia's default runner map would send darwin checks to macOS runners. Uncached dependencies shared by several checks are built by each job that needs them. Hestia limits a matrix to 256 jobs. `nix-eval-jobs` comes from your flake's `nixpkgs` input at its locked revision; a flake without an input of that name gets it from the runner's nixpkgs registry.

## Run Nix on pull requests

Set `ci.github.flakeCheck.pullRequests.enable = true;` and run `nix run .#write-files`. Require the `PR title lint` check and the bare `signoff` commit status from any source in your branch ruleset.

Nix PR checks start on open, reopen, and push for same-repository PRs, including upper layers of a stack. A push cancels the older run for that PR. Each run checks out the exact PR head and posts `signoff` on that commit after its checks pass. A new head needs its own result.

The same run lints the PR title in its first job and posts the result as a `PR title lint` commit status on the head, so a push costs no separate lint job. The `PR title` workflow still starts on every PR event, but its job is skipped unless the title was edited or the PR comes from a fork; a skipped job is not billed and satisfies the required `PR title lint` check. GitHub requires both the check and the status of that name, so an invalid title blocks the merge either way. Editing the title reruns the lint and updates the status. An invalid title does not fail the Nix checks.

`signoff` returns immediately if the tested commit already has a passing `signoff` status. If its Nix PR run is queued or running, the command prints the run URL and exits with status 75. Use `nix run .#signoff -- --local` to run the local suite immediately.

PR builds use the local `ci.signoff.skipChecks` exclusions by default. Set `ci.github.flakeCheck.pullRequests.skipChecks` to override the PR suite. Hestia receives the selected check derivations, including their grouping and runner metadata. The workflow on `main` builds the full suite.

## Release versioning and check caching

Because `Release` pushes a `chore: prepare vX.Y.Z` commit that touches only `VERSION` and `CHANGELOG.md` and then waits for `nix-check.yaml`, checks whose derivations read `VERSION` rebuild on every release.

- Parameterize release packages with `version ? config.ci.release.version` (or stamp an immutable commit build ID via `config.ci.release.buildVersion`), and pin checks to a constant such as `version = "0.0.0"`.
- Run `nix run .#release -- check-version-invariance` locally, or set `ci.release.checkVersionInvariance = true;` to fail `nix-check` and `nix-check-pr` if any check's `.drvPath` changes when `VERSION` is mutated.

## Vulnerability scanning

Declare targets under `perSystem`. Every field is a list, defaulting to `[]`:

```nix
perSystem = {config, ...}: {
  ci.vuln.targets.api = {
    closures = [config.packages.server];       # runtime closure: vulnxscan              
    dirs = [config.packages.api];              # grype dir:, e.g. Erlang/OTP and Elixir in a Mix release
    sboms = [config.packages.api-sbom];        # CycloneDX JSON file you build; osv-scanner
    lockfiles = ["${self}/api/mix.lock"];      # osv-scanner; a string, so the file name survives
    accepts = [
      {
        id = "CVE-2026-117656";                # any alias works
        package = "assent";                    # optional; limits the accept to this package
        reason = "Only used in dev";
        until = "2027-01-31";
      }
    ];
  };
};
```

`nix run .#vuln -- api` prints a summary: the blocking findings by package, a count of the rest, and the accepts that have expired or expire within 14 days. `--quick` runs only the lockfile lane and builds nothing, for PR checks. `--out DIR` also writes the summary to `DIR/summary.md` and every finding to `DIR/findings.json`. `packages.vuln` and `apps.vuln` exist once a target is declared.

| Exit code | Meaning |
| --- | --- |
| 0 | The scan is complete and nothing blocks. |
| 1 | The scan is complete and at least one finding blocks. |
| 2 | Wrong arguments. |
| 3 | The scan is incomplete: the target did not evaluate, a build failed, or a scanner failed, for example on a database download. The summary names what failed. This code wins over 1. |

| Lane | Scanner | Blocks on |
| --- | --- | --- |
| `lockfiles` | `osv-scanner scan source` | any finding not accepted |
| `sboms` | `osv-scanner scan source` on each file | any finding not accepted |
| `closures` | `vulnxscan --alpine` from sbomnix: an SBOM of the closure, then grype against NVD, grype against Alpine's security database, vulnix, and OSV | a high or critical finding for which grype knows a fixed version |
| `dirs` | `grype dir:` | a fixed high or critical finding |

Findings that do not block are counted in the summary and listed in `findings.json`; accept one or patch the package yourself. vulnxscan merges its scanners into one finding per CVE and package, and drops a CVE that a nixpkgs patch of that package names. Only grype says whether a fixed version exists, so a finding that only vulnix or OSV reports is listed and never blocks.

The Alpine pass treats each package as the Alpine package of the same name and version. Alpine's security database often lists a fixed version while NVD is still analysing the CVE, which grype's NVD matching cannot see. The match is by name, so a blocking finding from `alpine` alone is a reason to look, not proof; accept it when it is wrong. A fix Alpine made by patching its own build, such as `3.5.9-r1` for a package at 3.5.9, does not count as a fixed version: no upstream release carries it, and nixpkgs may or may not have the same patch. `--alpine` is a patch flake-ci carries on sbomnix (`modules/vuln/vulnxscan-alpine.patch`). An accept names an ID or any of its aliases, and `package` limits it to one package, in every lane. It stops applying after its `until` date, so the finding blocks again.

A kernel advisory lists a fixed version for each release series. For the Linux kernel, only a later release of the installed series counts: on 6.18.64, a fix in 6.18.70 blocks, and one that exists only in 6.12.114 and 7.2.6 does not, because no update within 6.18 brings it. Every other package counts any fixed version.

`findings.json` is the same result for programs:

```json
{
  "schema": 1,
  "target": "api",
  "mode": "full",
  "date": "2026-11-24",
  "complete": true,
  "errors": [],
  "findings": [
    {
      "lane": "sbom",
      "id": "EEF-CVE-2026-117656",
      "aliases": ["CVE-2026-117656", "GHSA-9fr5-g44g-9526"],
      "ecosystem": "Hex",
      "package": "assent",
      "version": "0.2.13",
      "severity": "Critical",
      "fixedIn": ["0.3.2"],
      "sources": ["osv"],
      "accepted": {"reason": "Only used in dev", "until": "2027-01-31"},
      "blocking": false
    }
  ],
  "accepts": [{"id": "CVE-2026-117656", "package": "assent", "reason": "Only used in dev", "until": "2027-01-31", "state": "live"}]
}
```

`mode` is `full` or `quick`, and `lane` is `closure`, `dir`, `sbom` or `lockfile`. `severity` uses grype's labels, onto which osv-scanner's CVSS score is mapped. `fixedIn` is empty when no fixed version counts. `sources` names who reported it: vulnxscan's scanners in the closure lane (`grype`, `alpine`, `vulnix`, `osv`), a grype namespace in the `dir` lane, and `osv` in the other two. An accept's `state` is `live`, `expiring` (within 14 days) or `expired`. `errors` lists what failed when `complete` is false.

Use `sboms` for packages the other lanes cannot see in what you ship. grype has no Hex advisories, for example, so `grype dir:` on a Mix release covers only Erlang/OTP and Elixir; a derivation that lists the release's Hex packages as `pkg:hex/<name>@<version>` components closes that gap, and reads the versions from the build instead of a lockfile. Each entry is a derivation whose output is one CycloneDX JSON file. A file without components leaves the scan incomplete.

Each target is also published as plain data at `vuln.<system>.<name>`, derivations as `"<drv>^<output>"` strings. Another flake adds to it with `lib.mkMerge`, keeping both repositories' accepts:

```nix
perSystem = {system, ...}: {
  ci.vuln.targets.prod = lib.mkMerge [
    inputs.platform.vuln.${system}.api
    {closures = [self.nixosConfigurations.prod.config.system.build.toplevel];}
  ];
};
```

The scanners come from flake-ci's own `nixpkgs-vuln` input, not from the `nixpkgs` a consumer makes flake-ci follow. vulnix downloads the NVD feeds to `~/.cache/vulnix`, about 420 MB, on its first run. sbomnix before 1.9.0 labels the kernel, glibc, and curl with CPE vendors NVD does not use, which hides every finding for them. `nix` comes from `PATH`.

### Scan workflows

`ci.github.vuln.enable` generates the workflows that run the scan, so every declared target is scanned without listing it again:

```nix
ci.github.vuln = {
  enable = true;
  fullScanPaths = ["flake.lock" "modules/**"];   # default: ["flake.lock"]
  quick.schedule = "11 */4 * * *";               # default: null
  nixpkgsKeys = ["nixpkgs" "nixpkgs-small"];     # default: ["nixpkgs"]
  inputToken = {                                 # only for private flake inputs
    clientIdVariable = "AUTOMATION_APP_CLIENT_ID";
    privateKeySecret = "AUTOMATION_PRIVATE_KEY";
    repositories = ["platform"];
  };
};
```

| Workflow | Runs | When |
| --- | --- | --- |
| `vuln.yaml` | `vuln <target>`, one job per target | `schedule` (daily by default), manual dispatch, and pull requests and pushes to `main` that change a `fullScanPaths` path |
| `vuln.yaml` | flake-checker on `nixpkgsKeys` | the schedule and manual dispatch |
| `vuln-quick.yaml` | `vuln <target> --quick` for every target in one job | every pull request (`quick.pullRequests`), and `quick.schedule` when set |

A scan result changes when an advisory is published and when what you ship changes. The schedule covers the first. `fullScanPaths` covers the second: list the paths that decide what a target ships, so a change is scanned when it is made. The grype database is rebuilt about once a day, so a full scan more often than daily finds little; osv.dev lists advisories within the hour, which is what `quick.schedule` is for.

A blocking finding or an incomplete scan fails the run, scheduled or not. Each scan job shows the summary on the run page and uploads `findings.json` as an artifact, `vuln-<target>` or `vuln-quick`; the workflows write nothing else to the forge. The workflow's matrix holds the target names of `ci.github.vuln.system` (`x86_64-linux`), so adding a target changes the workflow file: run `nix run .#write-files`. `runner`, `timeoutMinutes` (60) and `nothingButNix` size the full-scan jobs, which use `ci.github.cache`.

## Development

`nix flake check` runs the tool self-tests against a fixture consumer (`tests/`) plus this repository's own generated files and formatting.

`nix run .#vuln-selftest` (Linux) checks the pinned scanners against the live grype database: sbomnix must label the kernel `o:linux:linux_kernel`, glibc `gnu:glibc` and curl `haxx:curl`, vulnxscan must report NGINX2Shell (CVE-2026-123007) for nginx 1.30.4 with a fixed version, kernel findings with none from another release series and findings from its Alpine pass, and osv-scanner must report EEF-CVE-2026-117656 for assent 0.2.13 in a CycloneDX file. It reads each scanner's JSON through the filters `vuln` uses, so a scanner update that changes that output fails here. It reads the build graph of a canary derivation, so it builds nothing: it downloads the grype database and the NVD feeds and queries osv.dev. It also builds the patched sbomnix, so a `nixpkgs-vuln` update the patch no longer applies to fails here. The `vuln-selftest` workflow runs it weekly and on PRs that touch `flake.lock` or the scanner, and fails when `nixpkgs` or `nixpkgs-vuln` is locked to a revision older than 30 days. `nixpkgs` and `nixpkgs-vuln` get weekly update PRs.
