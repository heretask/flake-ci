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

    flakeCheck.runner = mkOption {
      type = types.str;
      default = cfg.runner;
      defaultText = lib.literalExpression "config.ci.github.runner";
      example = "ubuntu-24.04-4core";
      description = "Runner for the flake-check job, e.g. a larger runner for memory-heavy checks.";
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
      });
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
      orphans = lib.subtractLists (map (stem: "${stem}.yaml") (builtins.attrNames cfg.workflows)) committed;
    in {
      files.file = lib.mapAttrs' (stem: _: lib.nameValuePair (path stem) {source = "${rendered}/${stem}.yaml";}) cfg.workflows;

      checks = {
        # `files` only writes configured paths; workflows it does not own must go.
        workflow-orphans = pkgs.runCommandLocal "workflow-orphans" {} (
          if orphans == []
          then ''touch "$out"''
          else ''
            printf 'Unconfigured workflow, delete it or add it to ci.github.workflows: .github/workflows/%s\n' ${lib.escapeShellArgs orphans} >&2
            exit 1
          ''
        );

        actionlint = pkgs.runCommandLocal "actionlint" {nativeBuildInputs = [pkgs.actionlint];} ''
          mkdir -p .github
          cp -r ${rendered} .github/workflows
          actionlint .github/workflows/*.yaml
          touch "$out"
        '';
      };
    };
  };
}
