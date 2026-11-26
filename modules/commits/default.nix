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
        the PR-title check, and cog.toml. Defaults merge per type; replace
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

    featDisallowedVerbs = mkOption {
      type = types.listOf types.str;
      default = [
        "improve"
        "improves"
        "improving"
        "refine"
        "refines"
        "refining"
        "tweak"
        "tweaks"
        "tweaking"
        "cleanup"
        "clean up"
        "polish"
        "polishes"
        "polishing"
        "adjust"
        "adjusts"
        "adjusting"
      ];
      description = ''
        Leading words disallowed on `feat` descriptions when `improvement`
        is an allowed type. Set to `[]` to disable.
      '';
    };

    nonShippedPaths = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["docs/*" ".github/*" "*.md" "api/lib/ht/seed/demo/*"];
      description = ''
        Shell glob patterns for paths that ship nothing. When non-empty, the
        PR-title check rejects changelog types on pull requests whose changed
        files all match a pattern.
      '';
    };

    titleCheck = mkOption {
      type = types.str;
      readOnly = true;
      internal = true;
      description = ''
        Bash defining `check_title TITLE [--squash-merged]`, shared by
        commitlint and the PR-title workflow so both report the same errors.
      '';
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
      titleCheck = let
        typesWhere = keep: builtins.attrNames (lib.filterAttrs (_: type: keep type.bump) cfg.types);
        disallowedVerbs =
          if cfg.types ? feat && cfg.types ? improvement
          then cfg.featDisallowedVerbs
          else [];
      in ''
        changelog_types=(${lib.escapeShellArgs (typesWhere (bump: bump != null))})
        other_types=(${lib.escapeShellArgs (typesWhere (bump: bump == null))})
        changelog_scopes=(${lib.escapeShellArgs cfg.scopes.changelog})
        other_scopes=(${lib.escapeShellArgs cfg.scopes.other})
        feat_disallowed_verbs=(${lib.escapeShellArgs disallowedVerbs})
        max_length=${toString cfg.maxLength}
        ${builtins.readFile ./check-title.sh}'';
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
