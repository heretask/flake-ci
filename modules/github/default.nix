{
  config,
  lib,
  self,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.ci.github;
  path = stem: ".github/workflows/${stem}.yaml";
in {
  options.ci.github = {
    enable = lib.mkEnableOption "generated GitHub Actions workflows" // {default = true;};

    runner = mkOption {
      type = types.str;
      default = "ubuntu-24.04";
      description = "Runner for Linux jobs.";
    };

    flakeCheck.enable = mkOption {
      type = types.bool;
      default = true;
      example = false;
      description = ''
        Generate the `nix-check` workflow that checks the flake on `main`. Turn it off in a repository
        that checks its flake in a workflow of its own. The Release workflow waits for `nix-check`,
        so keep it on with `ci.release.enable`.
      '';
    };

    flakeCheck.pullRequests = {
      enable = lib.mkEnableOption ''
        Nix checks on same-repository pull requests that publish `signoff` on success.
        Requires `flakeCheck.enable`.
      '';

      skipChecks = mkOption {
        type = types.listOf types.str;
        default = config.ci.signoff.skipChecks;
        defaultText = lib.literalExpression "config.ci.signoff.skipChecks";
        description = "Names of flake checks to omit from PR builds.";
      };
    };

    flakeCheck.runner = mkOption {
      type = types.str;
      default = cfg.runner;
      defaultText = lib.literalExpression "config.ci.github.runner";
      example = "ubuntu-24.04-4core";
      description = "Runner for the flake-check job, e.g. a larger runner for memory-heavy checks.";
    };

    flakeCheck.timeoutMinutes = mkOption {
      type = types.ints.positive;
      default = 30;
      example = 60;
      description = "Timeout in minutes for the flake-check job, e.g. longer for cold builds.";
    };

    flakeCheck.reclaimDisk = mkOption {
      type = types.enum ["foreground" "background" "nothing-but-nix"];
      default = "foreground";
      example = "background";
      description = ''
        How the flake-check job frees preinstalled toolchains from the hosted runner's disk.
        `foreground` blocks for the removal (41-79 s measured on ubuntu-24.04). `background` starts
        it and moves on, so builds begin with the ~14 GB already free and get ~20 GB more within
        about two minutes. `nothing-but-nix` runs wimpysworld/nothing-but-nix with its Carve
        protocol before Nix is installed: `/nix` moves to a btrfs volume of about 75 GiB at once,
        which grows to about 105 GiB as the purge finishes in the background.
      '';
    };

    flakeCheck.queue = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Run main's flake checks one at a time, in push order, instead of side by side. Each run then
        starts after the previous one has uploaded its builds to the cache, and every commit still
        gets its own result. Up to 100 runs wait; GitHub cancels any beyond that.
      '';
    };

    flakeCheck.matrix = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Replace the flake-check job with a hestia build matrix: an `eval` job evaluates the flake once,
        then one `build` job per check that is not cached yet, each on its own runner. Checks with the
        same `meta.hestia.group` share a runner; `meta.hestia.os` overrides a check's runner labels.
        Needs `cache = "hestia"`.
      '';
    };

    flakeCheck.prebuildShared = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        With `flakeCheck.matrix`, build in the `eval` job the uncached derivations that more than one
        build job depends on, e.g. a compile step several test checks share. The build jobs then
        fetch them instead of each building its own copy. A derivation that fails to build here does
        not fail `eval`; the jobs that need it report it.
      '';
    };

    cache = mkOption {
      type = types.enum ["magic-nix-cache" "hestia"];
      default = "magic-nix-cache";
      example = "hestia";
      description = ''
        Binary cache for the flake-check jobs. `hestia` packs built paths into a few large entries
        in the GitHub Actions cache, avoiding the cache rate limit that throttles Magic Nix Cache,
        and adds a scheduled `hestia-gc` workflow. It needs `flakeCheck.timeoutMinutes` above 10.
      '';
    };

    hestiaGc.pushTtlDays = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 3;
      description = ''
        Days the `hestia-gc` workflow keeps a store path after its last push, even when no branch's
        latest build references it. `null` keeps hestia's default of 14. Lower it when the cache
        manifest nears hestia's 256 MiB decode limit: past it, flake-check jobs start from an empty
        cache and `hestia-gc` fails (Mic92/hestia#192).
      '';
    };

    darwinCheck = lib.mkEnableOption "a manually dispatched flake check on macOS";

    extraNixConfig = mkOption {
      type = types.lines;
      default = "";
      example = ''
        extra-substituters = https://example.cachix.org
        extra-trusted-public-keys = example.cachix.org-1:...
      '';
      description = "Extra nix.conf lines for the Nix installer in every workflow, e.g. binary caches.";
    };

    inputUpdates = mkOption {
      description = "Flake inputs refreshed by a scheduled update PR.";
      default = {};
      example = {"elixir-security-advisories".schedule = "17 4 * * *";};
      type = types.attrsOf (types.submodule {
        options.schedule = mkOption {
          type = types.str;
          description = "Cron schedule (UTC).";
        };
        options.appToken = mkOption {
          default = null;
          description = ''
            GitHub App that opens the update PR, so the PR's checks run. Events from the workflow's
            own token start no workflows. The App needs contents and pull-requests write.
          '';
          type = types.nullOr (types.submodule {
            options = {
              clientIdVariable = mkOption {
                type = types.str;
                description = "Repository variable with the App client ID.";
              };
              privateKeySecret = mkOption {
                type = types.str;
                description = "Repository secret with the App private key.";
              };
            };
          });
        };
      });
    };

    handWritten = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["deploy"];
      description = ''
        File stems of committed workflows that are written by hand instead of generated.
        `workflow-orphans` accepts them and `actionlint` checks them with the generated ones.
      '';
    };

    workflows = mkOption {
      description = ''
        Workflows by file stem, rendered to `.github/workflows/<stem>.yaml`.
        Holds the presets; add workflows or override preset fields here.
      '';
      type = types.attrsOf types.anything;
      default = {};
    };
  };

  config = lib.mkIf cfg.enable {
    ci.github.workflows = import ./workflows.nix {
      inherit cfg lib;
      inherit (config.ci) commits;
      checkVersionInvariance = config.ci.release.enable && config.ci.release.checkVersionInvariance;
    };

    flake = lib.mkIf (cfg.flakeCheck.enable && cfg.flakeCheck.pullRequests.enable && cfg.flakeCheck.pullRequests.skipChecks != []) {
      prChecks = lib.mapAttrs (_: systemConfig: builtins.removeAttrs systemConfig.checks cfg.flakeCheck.pullRequests.skipChecks) config.allSystems;
    };

    perSystem = {pkgs, ...}: let
      rendered =
        pkgs.runCommand "github-workflows" {
          nativeBuildInputs = [(pkgs.python3.withPackages (ps: [ps.pyyaml]))];
          workflows = builtins.toJSON cfg.workflows;
          passAsFile = ["workflows"];
        } ''
          python3 ${./render.py} "$workflowsPath" "$out"
        '';
      committed = let
        dir = "${self}/.github/workflows";
      in
        lib.optionals (builtins.pathExists dir) (
          builtins.filter (lib.hasSuffix ".yaml") (builtins.attrNames (builtins.readDir dir))
        );
      orphans = lib.subtractLists (map (stem: "${stem}.yaml") (builtins.attrNames cfg.workflows ++ cfg.handWritten)) committed;
    in {
      files.file = lib.mapAttrs' (stem: _: lib.nameValuePair (path stem) {source = "${rendered}/${stem}.yaml";}) cfg.workflows;

      checks = {
        # `files` only writes configured paths; workflows it does not own must go.
        workflow-orphans = pkgs.runCommandLocal "workflow-orphans" {meta.hestia.group = "light";} (
          if orphans == []
          then ''touch "$out"''
          else ''
            printf 'Unconfigured workflow, delete it or add it to ci.github.workflows or ci.github.handWritten: .github/workflows/%s\n' ${lib.escapeShellArgs orphans} >&2
            exit 1
          ''
        );

        actionlint = let
          # actionlint does not know concurrency.queue yet (rhysd/actionlint#657).
          ignoreQueue = lib.optionalString cfg.flakeCheck.queue "-ignore ${lib.escapeShellArg ''unexpected key "queue" for "concurrency" section''} ";
        in
          pkgs.runCommandLocal "actionlint" {
            nativeBuildInputs = [pkgs.actionlint];
            meta.hestia.group = "light";
          } ''
            mkdir -p .github
            cp -r ${rendered} .github/workflows
            chmod u+w .github/workflows
            ${lib.concatMapStrings (stem: ''
                cp ${self}/.github/workflows/${stem}.yaml .github/workflows/
              '')
              cfg.handWritten}
            actionlint ${ignoreQueue}.github/workflows/*.yaml
            touch "$out"
          '';
      };
    };
  };
}
