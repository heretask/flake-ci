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
          appToken = {
            clientIdVariable = "RELEASE_APP_CLIENT_ID";
            privateKeySecret = "RELEASE_APP_PRIVATE_KEY";
          };
          notify = {
            repository = "example/ops";
            prebuildEventType = "prebuild";
          };
        };
        ci.commits.scopes = {
          changelog = ["api" "app"];
          other = ["ci"];
        };
        # All differ from their defaults so the fixture-flake-check-job check can tell them apart.
        ci.github.flakeCheck = {
          runner = "ubuntu-22.04";
          timeoutMinutes = 45;
          reclaimDisk = "background";
          queue = true;
          matrix = true;
        };
        # Exercise the non-default cache here; flake-ci's own generated workflows cover the default.
        ci.github.cache = "hestia";
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
  in {
    checks = lib.mapAttrs' (name: lib.nameValuePair "fixture-${name}") (
      lib.getAttrs ["commitlint" "release-lifecycle" "workflow-behavior" "actionlint" "workflow-orphans" "flake-check-job" "flake-check-disabled" "matrix-job" "flake-ci-groups" "hestia-cache" "input-update-token"] consumer.checks.${system}
    );
  };
}
