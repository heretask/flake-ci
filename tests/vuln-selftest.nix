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
    sbomnix = import ../modules/vuln/sbomnix.nix tools;
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
    # assent 0.2.13 is affected by EEF-CVE-2026-117656.
    sbomCanary = tools.writeText "vuln-canary.cdx.json" (builtins.toJSON {
      bomFormat = "CycloneDX";
      specVersion = "1.5";
      components = [
        {
          type = "library";
          name = "assent";
          version = "0.2.13";
          purl = "pkg:hex/assent@0.2.13";
        }
      ];
    });
  in {
    packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      vuln-selftest = pkgs.writeShellApplication {
        name = "vuln-selftest";
        runtimeInputs = [tools.jq tools.osv-scanner sbomnix];
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

          # Each scanner as vuln.sh runs it, read through the same filters.
          findings() { jq -L ${../modules/vuln} "include \"vuln\"; $1" "''${@:2}"; }
          vulnxscan ${canaryDrv} --buildtime --alpine 3.24 --out "$work/vulns.csv" --evidence-out "$work/evidence.json" 2>"$work/vulnxscan.log" || {
            tail -n 20 "$work/vulnxscan.log" >&2
            exit 1
          }
          findings '[vulnxscan_findings]' "$work/evidence.json" >"$work/closure.json"
          if ! jq -e 'any(.[]; .id == "CVE-2026-123007" and .package == "nginx" and .version == "1.30.4" and .fixedIn != [])' "$work/closure.json" >/dev/null; then
            echo "FAIL: no fixed CVE-2026-123007 (NGINX2Shell) finding for nginx 1.30.4 in vulnxscan's output" >&2
            rc=1
          fi
          # A fix counts for the kernel only in the installed release series.
          if ! jq -e 'map(select(.package == "linux")) | length > 0 and all(.[]; .version as $v | all(.fixedIn[]; split(".")[:2] == ($v | split(".")[:2])))' "$work/closure.json" >/dev/null; then
            echo "FAIL: no kernel findings in vulnxscan's output, or one counts a fix from another release series" >&2
            rc=1
          fi
          # The Alpine pass ran, and its findings carry the scanned package's version, not Alpine's.
          if ! jq -e 'map(select(.sources | index("alpine"))) | length > 0 and all(.[]; .version | endswith("-r0") | not)' "$work/closure.json" >/dev/null; then
            echo "FAIL: no findings from vulnxscan's Alpine pass, or one keeps the projected -r0 version" >&2
            rc=1
          fi

          cp ${sbomCanary} "$work/canary.cdx.json"
          osv-scanner scan source --format json --lockfile="$work/canary.cdx.json" >"$work/osv.json" || true
          if ! findings '[osv_findings("sbom")]' "$work/osv.json" | jq -e 'any(.[]; .package == "assent" and ([.id] + .aliases | index("EEF-CVE-2026-117656")) and .fixedIn != [])' >/dev/null; then
            echo "FAIL: no EEF-CVE-2026-117656 finding with a fixed version for pkg:hex/assent@0.2.13 in osv-scanner's output" >&2
            rc=1
          fi

          if ((rc == 0)); then
            echo "vuln-selftest: sbomnix CPEs, vulnxscan NGINX2Shell, kernel and Alpine findings, and osv-scanner CycloneDX findings OK"
          fi
          exit "$rc"
        '';
      };
    };
  };
}
