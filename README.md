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

## Development

`nix flake check` runs the tool self-tests against a fixture consumer (`tests/`) plus this repository's own generated files and formatting.
