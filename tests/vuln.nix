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

    # libssh2 1.11.1 is the closure root and patched; 1.11.0 is in the same closure unpatched.
    sbom = {
      metadata.component = {
        name = "libssh2";
        version = "1.11.1";
        purl = "pkg:nix/libssh2@1.11.1";
        pedigree.patches = [
          {
            type = "unofficial";
            resolves = [
              {
                type = "security";
                id = "CVE-2026-7598";
              }
            ];
          }
        ];
      };
      components = [
        {
          name = "libssh2";
          version = "1.11.0";
          purl = "pkg:nix/libssh2@1.11.0";
          cpe = "cpe:2.3:a:libssh2:libssh2:1.11.0:*:*:*:*:*:*:*";
        }
        {
          name = "curl";
          version = "8.23.0";
          purl = "pkg:nix/curl@8.23.0";
          cpe = "cpe:2.3:a:haxx:curl:8.23.0:*:*:*:*:*:*:*";
          pedigree.patches = [
            {
              type = "unofficial";
              resolves = [
                {
                  type = "security";
                  id = "CVE-2026-1001";
                }
              ];
            }
            {type = "unofficial";}
          ];
        }
        {
          name = "source";
          version = "";
          purl = "pkg:nix/source";
        }
      ];
    };
    patched = name: version: id: {
      vulnerability = id;
      package = {inherit name version;};
      reason = "patched in nixpkgs";
    };
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

      vuln-accepts-osv = render "accepts-osv" {
        filter = ''osv_toml("2026-11-20")'';
        input = json "manifest" {
          accepts = [
            {
              id = "EEF-CVE-2026-117656";
              package = "assent";
              reason = "dev only";
              until = "2026-11-20";
            }
            accept
            {
              id = "CVE-2025-3";
              package = null;
              reason = "expired";
              until = "2026-11-19";
            }
          ];
        };
        expected = ''
          [[IgnoredVulns]]
          id = "EEF-CVE-2026-117656"
          reason = "dev only"

          [[IgnoredVulns]]
          id = "CVE-2026-1"
          reason = "no fix yet"

        '';
      };

      vuln-accepts-grype = render "accepts-grype" {
        filter = ''accept_rules("2026-11-20")'';
        input = json "manifest" {
          accepts = [
            {
              id = "EEF-CVE-2026-117656";
              package = "assent";
              reason = "dev only";
              until = "2026-11-20";
            }
            accept
            {
              id = "CVE-2025-3";
              package = "expired";
              reason = "expired";
              until = "2026-11-19";
            }
          ];
        };
        expected = [
          {
            vulnerability = "EEF-CVE-2026-117656";
            include-aliases = true;
            reason = "dev only";
            package.name = "assent";
          }
          {
            vulnerability = "CVE-2026-1";
            include-aliases = true;
            reason = "no fix yet";
          }
        ];
      };

      # No rule names libssh2 1.11.0, so its CVE-2026-7598 still fails the scan.
      vuln-patched = render "patched" {
        filter = "patched_rules";
        input = json "sbom" sbom;
        expected = [
          (patched "curl" "8.23.0" "CVE-2026-1001")
          (patched "curl" "8.23.0-r0" "CVE-2026-1001")
          (patched "libssh2" "1.11.1" "CVE-2026-7598")
          (patched "libssh2" "1.11.1-r0" "CVE-2026-7598")
        ];
      };

      vuln-alpine = render "alpine" {
        filter = "alpine";
        input = json "sbom" sbom;
        expected =
          sbom
          // {
            metadata.component =
              sbom.metadata.component
              // {
                version = "1.11.1-r0";
                purl = "pkg:apk/alpine/libssh2@1.11.1-r0?distro=alpine-3.24";
              };
            components = [
              {
                name = "libssh2";
                version = "1.11.0-r0";
                purl = "pkg:apk/alpine/libssh2@1.11.0-r0?distro=alpine-3.24";
              }
              (builtins.removeAttrs (builtins.elemAt sbom.components 1) ["cpe"]
                // {
                  version = "8.23.0-r0";
                  purl = "pkg:apk/alpine/curl@8.23.0-r0?distro=alpine-3.24";
                })
              (builtins.elemAt sbom.components 2)
            ];
          };
      };
    };
  };
}
