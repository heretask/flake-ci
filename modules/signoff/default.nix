{
  config,
  lib,
  ...
}: {
  options.ci.signoff.enable =
    lib.mkEnableOption "`signoff`: run the flake check, then gh-signoff the tested commit"
    // {default = true;};

  config = lib.mkIf config.ci.signoff.enable {
    perSystem = {pkgs, ...}: let
      signoff = import ./package.nix {inherit pkgs;};
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
        meta.description = "Run the full Nix flake check and sign off on the tested commit";
        type = "app";
        program = lib.getExe signoff;
      };
    };
  };
}
