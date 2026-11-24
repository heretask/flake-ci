{
  config,
  lib,
  self,
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

    versionFile = mkOption {
      type = types.path;
      default = self + "/VERSION";
      defaultText = lib.literalExpression ''self + "/VERSION"'';
      description = "Path to the SemVer VERSION file read by `ci.release.version` and `ci.release.buildVersion`.";
    };

    version = mkOption {
      type = types.str;
      readOnly = true;
      description = "Trimmed SemVer read lazily from `ci.release.versionFile`.";
    };

    buildVersion = mkOption {
      type = types.str;
      readOnly = true;
      description = ''
        Environment-agnostic SemVer build identifier `<VERSION>+<YYYYMMDDHHMM>.<shortRev>`,
        derived lazily from `ci.release.version`, `self.lastModifiedDate`, and `self.shortRev`.
      '';
    };

    formatBuildVersion = mkOption {
      type = types.functionTo types.str;
      readOnly = true;
      description = ''
        Format `<version>+<YYYYMMDDHHMM>.<shortRev>` from `{ version ? ci.release.version, lastModifiedDate ? self.lastModifiedDate or null, shortRev ? self.shortRev or null }`.
      '';
    };

    checkVersionInvariance = lib.mkEnableOption ''
      a `Check VERSION invariance` step in `nix-check` and `nix-check-pr` that verifies changing
      `VERSION` does not change any flake check derivation path
    '';

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
          prebuildEventType = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "prebuild";
            description = "repository_dispatch event type sent as soon as a release is requested, with the channel branch and the commit about to be released, so the receiver can build it before the channel moves. `null` sends none.";
          };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {
    ci.release.version = lib.trim (builtins.readFile cfg.versionFile);

    ci.release.formatBuildVersion = {
      version ? cfg.version,
      lastModifiedDate ? self.lastModifiedDate or null,
      shortRev ? self.shortRev or null,
    }: let
      buildStamp = lib.concatStringsSep "." (
        lib.optional (lastModifiedDate != null) (builtins.substring 0 12 lastModifiedDate)
        ++ lib.optional (shortRev != null) shortRev
      );
    in "${version}${lib.optionalString (buildStamp != "") "+${buildStamp}"}";

    ci.release.buildVersion = cfg.formatBuildVersion {};

    ci.github.workflows = import ./workflows.nix {
      inherit cfg lib;
      inherit (config.ci) github;
    };

    perSystem = {pkgs, ...}: let
      release = import ./package.nix {
        inherit pkgs;
        inherit (config.ci.commits) scopes;
      };
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
