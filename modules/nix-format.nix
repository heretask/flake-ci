{
  config,
  lib,
  self,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.ci.nixFormat;
in {
  options.ci.nixFormat = {
    enable = lib.mkEnableOption "alejandra, statix, and deadnix through treefmt";
    paths = mkOption {
      type = types.listOf types.str;
      example = ["flake.nix" "nix"];
      description = "Repository-relative files and directories checked by `checks.treefmt`.";
    };
    excludes = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Repository-relative globs skipped by all three tools, e.g. generated Nix.";
    };
  };

  config = lib.mkIf cfg.enable {
    perSystem = {config, ...}: {
      treefmt = {
        projectRootFile = "flake.nix";
        programs.alejandra.enable = true;
        programs.statix.enable = true;
        programs.deadnix.enable = true;

        programs.deadnix.no-lambda-pattern-names = true;
        programs.deadnix.no-underscore = true;

        settings.formatter.alejandra.excludes = cfg.excludes;
        programs.statix.excludes = cfg.excludes;
        programs.deadnix.excludes = cfg.excludes;
        flakeCheck = false;
      };

      checks.treefmt = config.treefmt.build.check (lib.cleanSourceWith {
        name = "nix-format-source";
        src = self;
        filter = path: type: let
          relative = lib.removePrefix "${self}/" (toString path);
        in
          lib.any (
            wanted:
              relative
              == wanted
              || lib.hasPrefix "${wanted}/" relative
              || (type == "directory" && lib.hasPrefix "${relative}/" wanted)
          )
          cfg.paths;
      });
    };
  };
}
