# flake-ci: flake-parts module configured through `ci.*`.
# localInputs: flake-ci's own inputs (files, treefmt-nix), bound by flake.nix.
{localInputs}: {
  imports = [
    "${localInputs.files}/flake-module.nix"
    localInputs.treefmt-nix.flakeModule
    ./files.nix
    ./commits
    ./github
    ./nix-format.nix
    ./release
    ./signoff
  ];
}
