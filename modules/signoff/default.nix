{
  config,
  lib,
  ...
}: {
  options.ci.signoff = {
    enable =
      lib.mkEnableOption "`signoff`: run the flake check, then gh-signoff the tested commit"
      // {default = true;};

    skipChecks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["vm-test"];
      description = ''
        `checks` attributes `signoff` does not build. It still evaluates the whole flake and builds
        every other check, and names the skipped ones. `nix flake check` and main's workflow still
        build them.
      '';
    };
  };

  config = lib.mkIf config.ci.signoff.enable {
    perSystem = {pkgs, ...}: let
      signoff = import ./package.nix {
        inherit pkgs;
        inherit (config.ci.signoff) skipChecks;
      };
      signoff-fast = import ./package.nix {
        inherit pkgs;
        name = "signoff-fast";
        check = false;
      };
    in {
      packages = {inherit signoff signoff-fast;};
      apps.signoff-fast = {
        type = "app";
        program = lib.getExe signoff-fast;
      };
      apps.signoff = {
        meta.description = "Run the Nix flake check and sign off on the tested commit";
        type = "app";
        program = lib.getExe signoff;
      };
    };
  };
}
