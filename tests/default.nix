# Evaluates flake-ci in a fixture consumer flake and exposes that consumer's
# tool self-tests (./checks.nix) as flake-ci's own checks.
{
  ciModule,
  inputs,
}: {
  perSystem = {
    lib,
    system,
    ...
  }: let
    consumer =
      inputs.flake-parts.lib.mkFlake {
        inputs = inputs // {self = inputs.self // {outPath = ./fixture;};};
      } {
        systems = [system];
        imports = [
          ciModule
          ./checks.nix
        ];
        ci.release = {
          enable = true;
          repository = "example/app";
          checkVersionInvariance = true;
          appToken = {
            clientIdVariable = "RELEASE_APP_CLIENT_ID";
            privateKeySecret = "RELEASE_APP_PRIVATE_KEY";
          };
          notify = {
            repository = "example/ops";
            prebuildEventType = "prebuild";
          };
        };
        ci.commits = {
          scopes = {
            changelog = ["api" "app"];
            other = ["ci"];
          };
          nonShippedPaths = [
            "docs/*"
            "*.md"
            "api/priv/seed/*"
          ];
        };
        # All differ from their defaults so the fixture-flake-check-job check can tell them apart.
        ci.github.flakeCheck = {
          runner = "ubuntu-22.04";
          timeoutMinutes = 45;
          reclaimDisk = "background";
          queue = true;
          matrix = true;
          prebuildShared = true;
          pullRequests.enable = true;
        };
        ci.signoff.skipChecks = ["commitlint"];
        perSystem = {pkgs, ...}: {
          ci.vuln.targets = {
            api.lockfiles = ["/src/api/mix.lock"];
            host.closures = [pkgs.hello];
          };
        };
        # All differ from their defaults so the fixture-vuln-workflow check can tell them apart.
        ci.github.vuln = {
          enable = true;
          schedule = "7 6 * * *";
          fullScanPaths = ["flake.lock" "modules/**"];
          quick.schedule = "11 */4 * * *";
          nixpkgsKeys = ["nixpkgs" "nixpkgs-small"];
          timeoutMinutes = 90;
          nothingButNix = true;
          inputToken = {
            clientIdVariable = "SCAN_APP_CLIENT_ID";
            privateKeySecret = "SCAN_APP_PRIVATE_KEY";
            repositories = ["platform" "other"];
          };
        };
        # Exercise the non-default cache here; flake-ci's own generated workflows cover the default.
        ci.github.cache = "hestia";
        ci.github.hestiaGc.pushTtlDays = 3;
        # ./fixture commits this workflow; the fixture-workflow-orphans and fixture-actionlint checks cover it.
        ci.github.handWritten = ["manual"];
        ci.github.inputUpdates = {
          plain-input.schedule = "17 4 * * *";
          app-input = {
            schedule = "17 4 * * *";
            appToken = {
              clientIdVariable = "UPDATE_APP_CLIENT_ID";
              privateKeySecret = "UPDATE_APP_PRIVATE_KEY";
            };
          };
        };
      };
    plainConsumer =
      inputs.flake-parts.lib.mkFlake {
        inputs = inputs // {self = inputs.self // {outPath = ./fixture;};};
      } {
        systems = [system];
        imports = [ciModule];
      };
    unfilteredPrConsumer =
      inputs.flake-parts.lib.mkFlake {
        inputs = inputs // {self = inputs.self // {outPath = ./fixture;};};
      } {
        systems = [system];
        imports = [ciModule];
        ci.github.flakeCheck.pullRequests = {
          enable = true;
          skipChecks = [];
        };
        ci.signoff.skipChecks = ["commitlint"];
      };
  in {
    checks = let
      prChecks = consumer.prChecks.${system};
      allChecks = consumer.checks.${system};
    in
      assert allChecks ? commitlint;
      assert !(prChecks ? commitlint);
      assert prChecks.workflow-orphans.drvPath == allChecks.workflow-orphans.drvPath;
      assert prChecks.workflow-orphans.meta.hestia.group == "light";
      assert !(plainConsumer ? prChecks);
      assert !(unfilteredPrConsumer ? prChecks);
        lib.mapAttrs' (name: lib.nameValuePair "fixture-${name}") (
          lib.getAttrs ["commitlint" "pr-title-guardrails" "release-lifecycle" "release-version" "workflow-behavior" "actionlint" "workflow-orphans" "flake-check-job" "flake-check-disabled" "matrix-job" "prebuild-shared" "flake-check-pr" "signoff-pr" "flake-ci-groups" "hestia-cache" "input-update-token" "vuln-workflow"] allChecks
        );
  };
}
