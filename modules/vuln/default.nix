# Vulnerability scanning: `ci.vuln.targets`, published as plain data at `flake.vuln.<system>.<name>`.
# localInputs: flake-ci's own inputs; the scanners come from its pinned nixpkgs-vuln.
{localInputs}: {
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  # "<drv>^<output>": evaluating a target builds nothing, `vuln` realises it when it scans.
  # types.package alone would also accept the strings a published target already holds.
  installable = types.coercedTo (types.addCheck types.package lib.isDerivation) (d: "${d.drvPath}^${d.outputName}") types.str;
  list = type: description:
    mkOption {
      type = types.listOf type;
      default = [];
      inherit description;
    };
  target = types.submodule {
    options = {
      closures = list installable "Runtime closures, scanned with vulnxscan: grype against NVD and against Alpine's security database, vulnix and OSV.";
      dirs = list installable "Outputs scanned with `grype dir:`, e.g. a Mix release for Erlang/OTP and Elixir.";
      sboms = list installable "CycloneDX JSON files, scanned with osv-scanner: packages that no scanner finds in the built output, e.g. the Hex packages in a Mix release.";
      lockfiles = list types.str ''Lockfiles scanned with osv-scanner, as strings so the file name survives, e.g. "''${self}/api/mix.lock".'';
      accepts = list (types.submodule {
        options = {
          id = mkOption {
            type = types.str;
            description = "Vulnerability ID or any of its aliases (CVE, GHSA, EEF).";
          };
          package = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Package name the accept is limited to. `null` accepts the ID for every package.";
          };
          reason = mkOption {
            type = types.str;
            description = "Why the finding is accepted.";
          };
          until = mkOption {
            type = types.strMatching "[0-9]{4}-[0-9]{2}-[0-9]{2}";
            example = "2027-01-31";
            description = "Last day (UTC) the accept applies; afterwards the finding blocks again.";
          };
        };
      }) "Findings that do not fail the scan.";
    };
  };
in {
  perSystem = {
    config,
    pkgs,
    system,
    ...
  }: let
    tools = localInputs.nixpkgs-vuln.legacyPackages.${system};
    sbomnix = import ./sbomnix.nix tools;
    vuln = pkgs.writeShellApplication {
      name = "vuln";
      runtimeInputs = [tools.grype tools.jq tools.osv-scanner sbomnix];
      text = ''
        system=${system}
        vuln_jq=${./.}
        ${builtins.readFile ./vuln.sh}
      '';
    };
  in {
    options.ci.vuln.targets = mkOption {
      type = types.attrsOf target;
      default = {};
      description = ''
        Scan targets for `nix run .#vuln -- <name> [--quick] [--out DIR]`. Every field is a list, so `lib.mkMerge`
        of a target another flake publishes at `vuln.<system>.<name>` adds to it.
      '';
    };

    config = lib.mkIf (config.ci.vuln.targets != {}) {
      packages.vuln = vuln;
      apps.vuln = {
        meta.description = "Scan a ci.vuln target for vulnerabilities";
        type = "app";
        program = lib.getExe vuln;
      };
    };
  };

  # Plain data, so another flake can merge a target without sharing these option declarations.
  flake.vuln = lib.mapAttrs (_: perSystem: perSystem.ci.vuln.targets) config.allSystems;
}
