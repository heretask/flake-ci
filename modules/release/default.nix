{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.ci.release;
in {
  options.ci.release = {
    enable = lib.mkEnableOption "the `release` app, a generated cog.toml, and release workflows";

    repository = mkOption {
      type = types.str;
      example = "owner/repo";
      description = "GitHub repository for changelog links.";
    };

    branches = {
      rc = mkOption {
        type = types.str;
        default = "unstable";
        description = "Channel branch advanced by an rc release.";
      };
      stable = mkOption {
        type = types.str;
        default = "stable";
        description = "Channel branch advanced by a stable release.";
      };
    };

    appToken = {
      clientIdVariable = mkOption {
        type = types.str;
        description = "Repository variable with the release GitHub App client ID.";
      };
      privateKeySecret = mkOption {
        type = types.str;
        description = "Repository secret with the release GitHub App private key.";
      };
    };

    notify = mkOption {
      description = "Send a repository_dispatch to another repository when a channel branch moves.";
      default = null;
      type = types.nullOr (types.submodule {
        options = {
          repository = mkOption {
            type = types.str;
            example = "owner/ops";
            description = "Receiving repository; the release App must be installed there.";
          };
          eventType = mkOption {
            type = types.str;
            default = "release";
            description = "repository_dispatch event type.";
          };
        };
      });
    };

    freeze = {
      enable = lib.mkEnableOption "a `freeze` PR check that fails while the newest release candidate on `main` has no stable release";
      label = mkOption {
        type = types.str;
        default = "hotfix";
        description = "PR label that lets a PR merge during the freeze.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    ci.github.workflows = import ./workflows.nix {
      inherit cfg lib;
      inherit (config.ci) github;
    };

    perSystem = {pkgs, ...}: let
      release = import ./package.nix {inherit pkgs;};
    in {
      files.file."cog.toml".source = import ./cog-toml.nix {
        inherit lib pkgs;
        inherit (config.ci) commits;
        inherit (cfg) repository;
      };

      packages.release = release;
      apps.release = {
        meta.description = "Inspect and create release candidates and stable releases";
        type = "app";
        program = lib.getExe release;
      };
    };
  };
}
