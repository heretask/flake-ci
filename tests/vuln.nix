# ci.vuln checks that need no network: composition across flakes and the jq rendering in vuln.jq.
{
  vulnModule,
  inputs,
}: {
  perSystem = {
    lib,
    pkgs,
    system,
    ...
  }: let
    jq = lib.getExe inputs.nixpkgs-vuln.legacyPackages.${system}.jq;
    json = name: value: pkgs.writeText "${name}.json" (builtins.toJSON value);

    # Runs a vuln.jq filter on `input` and diffs the result against `expected`: text, or JSON with sorted keys.
    render = name: {
      filter,
      input,
      expected,
    }:
      pkgs.runCommandLocal "vuln-${name}" {} ''
        ${jq} -rS -L ${../modules/vuln} 'include "vuln"; ${filter}' ${input} > got
        diff -u ${
          if builtins.isString expected
          then pkgs.writeText "expected" expected
          else "<(${jq} -S . ${json "expected" expected})"
        } got
        touch "$out"
      '';

    mkFlake = module:
      inputs.flake-parts.lib.mkFlake {inherit inputs;} {
        systems = [system];
        imports = [vulnModule module];
      };
    accept = {
      id = "CVE-2026-1";
      package = null;
      reason = "no fix yet";
      until = "2999-12-31";
    };
    # vulnModule alone, without the rest of flake-ci, as flakeModules.vuln ships it.
    platform = mkFlake {
      perSystem = {pkgs, ...}: {
        ci.vuln.targets.api = {
          dirs = [pkgs.hello];
          sboms = [pkgs.hello];
          lockfiles = ["/src/api/mix.lock"];
          accepts = [accept];
        };
      };
    };
    ops = mkFlake {
      perSystem = {pkgs, ...}: {
        ci.vuln.targets.prod = lib.mkMerge [
          platform.vuln.${system}.api
          {closures = [pkgs.jq];}
        ];
      };
    };
    empty = mkFlake {};

    # A vulnxscan evidence document, cut down to the fields vuln.jq reads.
    evidence = {
      findings = [
        (evidenceFinding "f1" "CVE-2026-20" "linux" "6.18.64" "7.8" ["grype"] false)
        (evidenceFinding "f2" "CVE-2026-21" "linux" "6.18.64" "9.8" ["grype" "vulnix"] false)
        (evidenceFinding "f3" "CVE-2026-10" "krb5" "1.22.2" "7.1" ["alpine"] false)
        (evidenceFinding "f4" "CVE-2026-11" "krb5" "1.22.2" "8.1" ["alpine"] true)
        (evidenceFinding "f5" "CVE-2026-12" "zlib" "1.3.2" "" ["vulnix"] false)
        (evidenceFinding "f6" "CVE-2026-13" "openssl" "3.5.9" "7.5" ["alpine"] false)
        (evidenceFinding "f7" "CVE-2026-14" "openssl" "3.5.9" "7.5" ["alpine" "grype"] false)
      ];
      observations = [
        (observation "f1" "grype" "6.18.64" "fixed" "6.12.114, 6.18.70, 7.2.6, 7.3")
        (observation "f2" "grype" "6.18.64" "fixed" "6.6.160, 6.18.64, 6.18, 7.2.6")
        (observation "f2" "vulnix" "6.18.64" null null)
        (observation "f3" "alpine" "1.22.2" "fixed" "1.22.3-r0")
        (observation "f4" "alpine" "1.22.2" "fixed" "1.22.3-r0")
        (observation "f5" "vulnix" "1.3.2" null null)
        # Alpine patched its own 3.5.9 build; only NVD names an upstream release.
        (observation "f6" "alpine" "3.5.9" "fixed" "3.5.9-r1")
        (observation "f7" "alpine" "3.5.9" "fixed" "3.5.9-r1")
        (observation "f7" "grype" "3.5.9" "fixed" "3.5.10")
      ];
    };
    evidenceFinding = finding_id: vuln_id: package: version: severity: scanners: suppressed_by_patch_evidence: {
      inherit finding_id vuln_id package version severity scanners suppressed_by_patch_evidence;
    };
    observation = finding_id: scanner: version: fix_state: fix_versions:
      {inherit finding_id scanner version;} // lib.optionalAttrs (fix_state != null) {inherit fix_state fix_versions;};
    # A grype match, cut down to the fields vuln.jq reads.
    grypeMatch = id: severity: versions: artifact: {
      vulnerability = {
        inherit id severity;
        namespace = "github:language:erlang";
        fix = {
          inherit versions;
          state =
            if versions == []
            then "not-fixed"
            else "fixed";
        };
      };
      relatedVulnerabilities = [{inherit id;} {id = "CVE-2026-30";}];
      inherit artifact;
    };
    finding = lane: id: package: version: severity: fixedIn: {
      inherit lane id package version severity fixedIn;
      aliases = [];
      ecosystem = "nix";
      sources = ["grype"];
    };
    # Findings as the lanes emit them, the accepts they meet, and one failed lane.
    scan = {
      manifest.accepts = [
        {
          id = "CVE-2026-117656";
          package = "assent";
          reason = "dev | only";
          until = "2026-11-20";
        }
        {
          id = "CVE-2026-2";
          package = "other";
          reason = "another package";
          until = "2999-12-31";
        }
        {
          id = "EEF-CVE-2026-2";
          package = null;
          reason = "expired";
          until = "2026-11-19";
        }
        {
          id = "CVE-2026-13";
          package = null;
          reason = "not reachable";
          until = "2026-12-04";
        }
      ];
      findings = [
        (finding "closure" "CVE-2026-10" "openssl" "3.5.9" "High" ["3.5.10"])
        # A second closure ships the same package; there the Alpine pass matched it.
        (finding "closure" "CVE-2026-10" "openssl" "3.5.9" "Critical" ["3.5.10-r0"] // {sources = ["alpine"];})
        (finding "closure" "CVE-2026-11" "linux" "6.18.64" "Critical" [])
        (finding "closure" "CVE-2026-12" "zlib" "1.3" "Medium" ["1.3.1"])
        (finding "sbom" "EEF-CVE-2026-117656" "assent" "0.2.13" "Critical" ["0.3.2"] // osv ["CVE-2026-117656"])
        (finding "lockfile" "EEF-CVE-2026-2" "ex_aws" "2.7.0" "Medium" ["2.8.0"] // osv ["CVE-2026-2"])
        (finding "dir" "CVE-2026-13" "erlang" "28.0" "High" ["28.1"] // {ecosystem = "erlang-otp";})
      ];
    };
    erlang = {
      aliases = ["CVE-2026-30"];
      ecosystem = "erlang-otp";
      sources = ["github:language:erlang"];
    };
    osv = aliases: {
      inherit aliases;
      ecosystem = "Hex";
      sources = ["osv"];
    };
    report = ''report($in.manifest; "prod"; "full"; "2026-11-20"; ["dir /nix/store/x: grype exited 1"])'';
    reported = id: package: severity: fixedIn: sources: accepted: blocking: {inherit id package severity fixedIn sources accepted blocking;};
    scanAccept = n: state: builtins.elemAt scan.manifest.accepts n // {inherit state;};
  in {
    checks = {
      # The bug this guards: types.package accepts store-path strings, so a published target's
      # "<drv>^<output>" strings failed to merge into another flake ("expected a set").
      vuln-merge = assert ops.vuln.${system}.prod
      == {
        closures = ["${pkgs.jq.drvPath}^bin"];
        dirs = ["${pkgs.hello.drvPath}^out"];
        sboms = ["${pkgs.hello.drvPath}^out"];
        lockfiles = ["/src/api/mix.lock"];
        accepts = [accept];
      };
      assert ops.apps.${system} ? vuln;
      assert !(empty.packages.${system} ? vuln);
        pkgs.runCommandLocal "vuln-merge" {} "touch $out";

      # The kernel counts as fixed only by a later release of its own series, and Alpine's patch of
      # its own build is no fixed version. A finding a nixpkgs patch resolves is dropped, and one
      # without a grype observation has no fixed version.
      vuln-vulnxscan-findings = render "vulnxscan-findings" {
        filter = "[vulnxscan_findings]";
        input = json "evidence" evidence;
        expected = [
          (finding "closure" "CVE-2026-20" "linux" "6.18.64" "High" ["6.18.70"] // {sources = ["grype"];})
          (finding "closure" "CVE-2026-21" "linux" "6.18.64" "Critical" [] // {sources = ["grype" "vulnix"];})
          (finding "closure" "CVE-2026-10" "krb5" "1.22.2" "High" ["1.22.3-r0"] // {sources = ["alpine"];})
          (finding "closure" "CVE-2026-12" "zlib" "1.3.2" "Unknown" [] // {sources = ["vulnix"];})
          (finding "closure" "CVE-2026-13" "openssl" "3.5.9" "High" [] // {sources = ["alpine"];})
          (finding "closure" "CVE-2026-14" "openssl" "3.5.9" "High" ["3.5.10"] // {sources = ["alpine" "grype"];})
        ];
      };

      vuln-grype-findings = render "grype-findings" {
        filter = "[grype_findings]";
        input = json "grype" {
          matches = [
            (grypeMatch "GHSA-aaaa" "High" ["28.1"] {
              name = "erts";
              version = "16.0";
              type = "erlang-otp";
            })
            (grypeMatch "GHSA-bbbb" "Medium" [] {
              name = "erts";
              version = "16.0";
              type = "erlang-otp";
            })
          ];
        };
        expected = [
          (finding "dir" "GHSA-aaaa" "erts" "16.0" "High" ["28.1"] // erlang)
          (finding "dir" "GHSA-bbbb" "erts" "16.0" "Medium" [] // erlang)
        ];
      };

      vuln-osv-findings = render "osv-findings" {
        filter = ''[osv_findings("sbom")]'';
        input = json "osv" {
          results = [
            {
              packages = [
                {
                  package = {
                    name = "assent";
                    version = "0.2.13";
                    ecosystem = "Hex";
                  };
                  groups = [
                    {
                      ids = ["EEF-CVE-2026-117656"];
                      aliases = ["CVE-2026-117656" "EEF-CVE-2026-117656"];
                      max_severity = "9.3";
                    }
                    {
                      ids = ["EEF-CVE-2026-3"];
                      max_severity = "";
                    }
                  ];
                  vulnerabilities = [
                    {
                      id = "EEF-CVE-2026-117656";
                      affected = [
                        {
                          package.name = "assent";
                          ranges = [{events = [{introduced = "0.1.25";} {fixed = "0.3.2";}];}];
                        }
                        {ranges = [{events = [{fixed = "18898bd";}];}];}
                      ];
                    }
                  ];
                }
              ];
            }
          ];
        };
        expected = [
          {
            lane = "sbom";
            id = "EEF-CVE-2026-117656";
            aliases = ["CVE-2026-117656"];
            ecosystem = "Hex";
            package = "assent";
            version = "0.2.13";
            severity = "Critical";
            fixedIn = ["0.3.2"];
            sources = ["osv"];
          }
          {
            lane = "sbom";
            id = "EEF-CVE-2026-3";
            aliases = [];
            ecosystem = "Hex";
            package = "assent";
            version = "0.2.13";
            severity = "Unknown";
            fixedIn = [];
            sources = ["osv"];
          }
        ];
      };

      # What blocks: any osv finding, and a high or critical grype finding with a fixed version.
      # An accept applies by ID or alias, to its package only, until its last day.
      vuln-report = render "report" {
        filter = ''. as $in | .findings | ${report} | .findings |= map({id, package, severity, fixedIn, sources, accepted, blocking})'';
        input = json "scan" scan;
        expected = {
          schema = 1;
          target = "prod";
          mode = "full";
          date = "2026-11-20";
          complete = false;
          errors = ["dir /nix/store/x: grype exited 1"];
          findings = [
            (reported "CVE-2026-10" "openssl" "Critical" ["3.5.10" "3.5.10-r0"] ["alpine" "grype"] null true)
            (reported "EEF-CVE-2026-2" "ex_aws" "Medium" ["2.8.0"] ["osv"] null true)
            (reported "EEF-CVE-2026-117656" "assent" "Critical" ["0.3.2"] ["osv"] {
                reason = "dev | only";
                until = "2026-11-20";
              }
              false)
            (reported "CVE-2026-11" "linux" "Critical" [] ["grype"] null false)
            (reported "CVE-2026-13" "erlang" "High" ["28.1"] ["grype"] {
                reason = "not reachable";
                until = "2026-12-04";
              }
              false)
            (reported "CVE-2026-12" "zlib" "Medium" ["1.3.1"] ["grype"] null false)
          ];
          accepts = [
            (scanAccept 0 "expiring")
            (scanAccept 1 "live")
            (scanAccept 2 "expired")
            (scanAccept 3 "expiring")
          ];
        };
      };

      vuln-summary = render "summary" {
        filter = ''. as $in | .findings | ${report} | summary'';
        input = json "scan" scan;
        expected = ''
          ## Vulnerability scan: prod

          **Incomplete.** Part of the scan failed, so findings can be missing:

          - dir /nix/store/x: grype exited 1

          **2 blocking findings** in 2 packages:

          | Package | Version | Lane | Findings | Fixed in |
          | --- | --- | --- | --- | --- |
          | openssl | 3.5.9 | closure | CVE-2026-10 (Critical) | 3.5.10, 3.5.10-r0 |
          | ex_aws | 2.7.0 | lockfile | EEF-CVE-2026-2 (Medium) | 2.8.0 |

          4 findings do not block: 1 high or critical without a fixed version, 1 of lower severity, 2 accepted. `findings.json` lists them.

          Accepts that have expired or expire within 14 days:

          | ID | Package | Until | Reason |
          | --- | --- | --- | --- |
          | CVE-2026-117656 | assent | 2026-11-20 | dev \| only |
          | EEF-CVE-2026-2 | any | 2026-11-19 (expired) | expired |
          | CVE-2026-13 | any | 2026-12-04 | not reachable |
        '';
      };

      vuln-summary-clear = render "summary-clear" {
        filter = ''[] | report({accepts: []}; "api"; "quick"; "2026-11-20"; []) | summary'';
        input = json "none" null;
        expected = ''
          ## Vulnerability scan: api (lockfiles only)

          No blocking findings.
        '';
      };
    };
  };
}
