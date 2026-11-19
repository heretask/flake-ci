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

    scopes = {
      changelog = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["api" "app"];
        description = ''
          Scopes allowed on changelog types (those with a bump), in changelog
          order. Empty allows any scope on any type.
        '';
      };
      other = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["nix" "ci"];
        description = ''
          Scopes allowed only on non-changelog types. Commits with these scopes
          are left out of the changelog and do not bump the version.
        '';
      };
    };

    headerPattern = mkOption {
      type = types.str;
      readOnly = true;
      internal = true;
      description = "Bash regex for `type(scope)!`, the part before `: `.";
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
      headerPattern = let
        alt = builtins.concatStringsSep "|";
        typesWhere = keep: builtins.attrNames (lib.filterAttrs (_: type: keep type.bump) cfg.types);
        scope = names:
          if cfg.scopes.changelog == []
          then "(\\([^()]+\\))?"
          else "(\\((${alt names})\\))?";
      in "((${alt (typesWhere (bump: bump != null))})${scope cfg.scopes.changelog}|(${alt (typesWhere (bump: bump == null))})${scope (cfg.scopes.changelog ++ cfg.scopes.other)})!?";
      titlePattern = "^${cfg.headerPattern}: .{1,${toString cfg.maxLength}}$";
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
