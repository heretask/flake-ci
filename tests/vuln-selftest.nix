# Network self-test of the pinned scanners (`nix run .#vuln-selftest`), and the workflow that runs it.
# Not a flake check: grype downloads its vulnerability database.
{inputs}: {config, ...}: let
  inherit (config.ci) github;
  steps = import ../modules/github/steps.nix {inherit (github) extraNixConfig;};
in {
  ci.github.workflows.vuln-selftest = {
    name = "Vulnerability scanner self-test";
    on = {
      pull_request.paths = [
        "flake.lock"
        "modules/vuln/**"
        "tests/vuln-selftest.nix"
      ];
      schedule = [{cron = "29 5 * * 2";}];
      workflow_dispatch = {};
    };
    permissions.contents = "read";
    jobs = {
      selftest = {
        name = "selftest";
        runs-on = github.runner;
        timeout-minutes = 15;
        steps = [
          steps.checkout
          steps.installNix
          {
            name = "Run scanner self-test";
            run = "${steps.nixRun} .#vuln-selftest";
          }
        ];
      };
      # Fails once a nixpkgs input is older than 30 days or off a supported branch, so the scanners
      # and the packages they label do not silently go stale.
      flake-lock = {
        name = "flake-lock";
        runs-on = github.runner;
        timeout-minutes = 5;
        steps = [
          steps.checkout
          (steps.flakeChecker
            // {
              "with" = {
                fail-mode = true;
                nixpkgs-keys = "nixpkgs,nixpkgs-vuln";
              };
            })
        ];
      };
    };
  };

  perSystem = {
    lib,
    pkgs,
    system,
    ...
  }: let
    tools = inputs.nixpkgs-vuln.legacyPackages.${system};
    # nginx 1.30.4 is affected by NGINX2Shell (CVE-2026-123007); the others carry the CPE vendors
    # sbomnix 1.8.0 got wrong, which hid every kernel, glibc and curl finding.
    canary = tools.writeText "vuln-canary" ''
      ${tools.linux}
      ${tools.glibc}
      ${tools.curl}
      ${tools.nginx.overrideAttrs {
        version = "1.30.4";
        __intentionallyOverridingVersion = true;
      }}
    '';
    # Never built: sbomnix reads the build-time graph from the .drv files, so only the grype
    # database is downloaded. A plain drvPath would make every output in the graph a dependency.
    canaryDrv = builtins.unsafeDiscardOutputDependency canary.drvPath;
  in {
    packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      vuln-selftest = pkgs.writeShellApplication {
        name = "vuln-selftest";
        runtimeInputs = [tools.grype tools.jq tools.sbomnix];
        text = ''
          work=$(mktemp -d)
          trap 'rm -rf "$work"' EXIT
          sbomnix ${canaryDrv} --buildtime --cdx "$work/sbom.json" --csv /dev/null --spdx /dev/null
          rc=0

          for expected in linux=o:linux:linux_kernel glibc=a:gnu:glibc curl=a:haxx:curl; do
            name=''${expected%%=*}
            cpe=cpe:2.3:''${expected#*=}:
            if ! jq -e --arg name "$name" --arg cpe "$cpe" 'any(.components[]; .name == $name and (.cpe // "" | startswith($cpe)))' "$work/sbom.json" >/dev/null; then
              echo "FAIL: sbomnix labels $name $(jq -c --arg name "$name" '[.components[] | select(.name == $name) | .cpe]' "$work/sbom.json"), expected $cpe*" >&2
              rc=1
            fi
          done

          jq -L ${../modules/vuln} 'include "vuln"; alpine' "$work/sbom.json" >"$work/alpine.json"
          for sbom in sbom alpine; do
            grype "sbom:$work/$sbom.json" --only-fixed -o json >"$work/$sbom.grype.json"
          done
          if ! jq -e -s 'any(.[].matches[]; .vulnerability.id == "CVE-2026-123007" and .artifact.name == "nginx" and (.artifact.version | startswith("1.30.4")))' "$work"/*.grype.json >/dev/null; then
            echo "FAIL: grype does not report CVE-2026-123007 (NGINX2Shell) for nginx 1.30.4" >&2
            rc=1
          fi

          if ((rc == 0)); then
            echo "vuln-selftest: sbomnix CPEs and grype NGINX2Shell detection OK"
          fi
          exit "$rc"
        '';
      };
    };
  };
}
