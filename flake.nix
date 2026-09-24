{
  description = "flake-parts module: commit convention, signoff, releases, generated GitHub workflows, Nix formatting";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    # Only flake-module.nix is used; skip its flake inputs.
    files = {
      url = "github:mightyiam/files";
      flake = false;
    };

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} ({flake-parts-lib, ...}: let
      ciModule = flake-parts-lib.importApply ./modules {localInputs = inputs;};
    in {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      imports = [
        ciModule
        (import ./tests {inherit ciModule inputs;})
      ];

      flake.flakeModules.default = ciModule;

      # flake-ci's own repository.
      ci = {
        nixFormat = {
          enable = true;
          paths = [
            "flake.nix"
            "modules"
            "tests"
          ];
        };
      };
    });
}
