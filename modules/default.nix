# flake-ci: flake-parts module configured through `ci.*`.
# localInputs: flake-ci's own inputs (files, treefmt-nix, nixpkgs-vuln), bound by flake.nix.
{localInputs}: {
  imports = [
    "${localInputs.files}/flake-module.nix"
    localInputs.treefmt-nix.flakeModule
    ./files.nix
    ./commits
    ./github
    ./github/vuln.nix
    ./nix-format.nix
    ./release
    ./signoff
    (localInputs.flake-parts.lib.importApply ./vuln {inherit localInputs;})
  ];
}
