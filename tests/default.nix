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
          notify.repository = "example/ops";
        };
        # Both differ from their defaults so the fixture-flake-check-job check can tell them apart.
        ci.github.flakeCheck = {
          runner = "ubuntu-22.04";
          timeoutMinutes = 45;
        };
      };
  in {
    checks = lib.mapAttrs' (name: lib.nameValuePair "fixture-${name}") (
      lib.getAttrs ["commitlint" "release-lifecycle" "workflow-behavior" "actionlint" "flake-check-job"] consumer.checks.${system}
    );
  };
}
