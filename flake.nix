{
  description = "flake-parts module: commit convention, signoff, releases, generated GitHub workflows, Nix formatting, vulnerability scanning";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Scanners for ci.vuln. Consumers do not follow it, so the tool set tested here is the one they run.
    nixpkgs-vuln.url = "github:NixOS/nixpkgs/nixos-unstable";
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
      vulnModule = flake-parts-lib.importApply ./modules/vuln {localInputs = inputs;};
    in {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      imports = [
        ciModule
        (import ./tests {inherit ciModule inputs;})
        (import ./tests/vuln.nix {inherit vulnModule inputs;})
        (import ./tests/vuln-selftest.nix {inherit inputs;})
      ];

      flake.flakeModules = {
        default = ciModule;
        vuln = vulnModule;
      };

      # flake-ci's own repository.
      ci = {
        github = {
          # Magic Nix Cache gets throttled by the Actions cache rate limit and then builds cold.
          cache = "hestia";
          flakeCheck = {
            # /nix gets its own volume over the runner's free disk instead of the root filesystem.
            reclaimDisk = "nothing-but-nix";
            # Run the flake check on same-repo PR heads and publish `signoff` on success.
            pullRequests.enable = true;
          };
          inputUpdates = {
            nixpkgs.schedule = "17 4 * * 1";
            nixpkgs-vuln.schedule = "47 4 * * 1";
          };
        };
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
