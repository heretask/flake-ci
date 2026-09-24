{
  config,
  lib,
  ...
}: let
  inherit (lib) mkDefault mkOption types;
  cfg = config.ci.commits;

  defaultType = title: bump: {
    title = mkDefault title;
    bump = mkDefault bump;
  };
in {
  options.ci.commits = {
    types = mkOption {
      description = ''
        Allowed Conventional Commit types. The single source for commitlint,
        the PR-title pattern, and cog.toml. Defaults merge per type; replace
        the whole set with `lib.mkForce`.
      '';
      type = types.attrsOf (types.submodule {
        options = {
          title = mkOption {
            type = types.str;
            description = "Changelog section title.";
          };
          bump = mkOption {
            type = types.nullOr (types.enum ["minor" "patch"]);
            description = "SemVer bump; null omits the type from the changelog.";
          };
        };
      });
    };

    maxLength = mkOption {
      type = types.ints.positive;
      default = 72;
      description = "Maximum description length after `type(scope): `.";
    };

    titlePattern = mkOption {
      type = types.str;
      readOnly = true;
      internal = true;
      description = "Bash regex for commit subjects and PR titles.";
    };
  };

  config = {
    ci.commits = {
      types = {
        feat = defaultType "Features" "minor";
        fix = defaultType "Bug Fixes" "patch";
        improvement = defaultType "Improvements" "patch";
        perf = defaultType "Performance" "patch";
        refactor = defaultType "Refactoring" "patch";
        revert = defaultType "Reverts" "patch";
        build = defaultType "Build" null;
        chore = defaultType "Chores" null;
        ci = defaultType "CI" null;
        docs = defaultType "Documentation" null;
        style = defaultType "Style" null;
        test = defaultType "Tests" null;
      };
      titlePattern = "^(${builtins.concatStringsSep "|" (builtins.attrNames cfg.types)})(\\([^()]+\\))?!?: .{1,${toString cfg.maxLength}}$";
    };

    perSystem = {pkgs, ...}: let
      commitlint = import ./commitlint.nix {
        inherit pkgs;
        commits = cfg;
      };
    in {
      packages.commitlint = commitlint;
      apps.commitlint = {
        meta.description = "Lint Conventional Commit messages";
        type = "app";
        program = lib.getExe commitlint;
      };
    };
  };
}
