# Tool self-tests, evaluated against the fixture consumer in ./default.nix.
{config, ...}: let
  inherit (config.ci) commits github;
in {
  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: let
    commitlint = lib.getExe config.packages.commitlint;
    valid = ["feat(ci): validate commit messages" "revert(scope): description"];
    invalid = ["not conventional"];
  in {
    checks = {
      # commitlint and the PR-title pattern agree on the fixtures.
      commitlint = pkgs.runCommandLocal "commitlint-check" {inherit (commits) titlePattern;} ''
        ${lib.concatMapStringsSep "\n" (title: ''
            printf '%s\n' ${lib.escapeShellArg title} | ${commitlint}
            if ! [[ ${lib.escapeShellArg title} =~ $titlePattern ]]; then
              echo ${lib.escapeShellArg "title pattern rejected a valid fixture: ${title}"} >&2
              exit 1
            fi
          '')
          valid}

        ${lib.concatMapStringsSep "\n" (title: ''
            if printf '%s\n' ${lib.escapeShellArg title} | ${commitlint}; then
              status=0
            else
              status=$?
            fi
            if [[ $status -ne 1 ]]; then
              echo ${lib.escapeShellArg "commitlint returned unexpected status $status for an invalid fixture: ${title}"} >&2
              exit 1
            fi
            if [[ ${lib.escapeShellArg title} =~ $titlePattern ]]; then
              echo ${lib.escapeShellArg "title pattern accepted an invalid fixture: ${title}"} >&2
              exit 1
            fi
          '')
          invalid}

        touch "$out"
      '';

      release-lifecycle =
        pkgs.runCommand "release-lifecycle" {
          src = lib.fileset.toSource {
            root = ../modules/release;
            fileset = lib.fileset.unions [../modules/release/release.py ../modules/release/test_release.py];
          };
          cogToml = config.files.file."cog.toml".source;
          nativeBuildInputs = [pkgs.git pkgs.python3 pkgs.cocogitto];
        } ''
          export HOME="$TMPDIR"
          git config --global user.email test@example.com
          git config --global user.name Test
          cp -r "$src" ./release
          cp "$cogToml" ./cog.toml
          chmod -R u+w ./release
          cd ./release
          python3 -m unittest test_release.py
          touch "$out"
        '';

      workflow-behavior = pkgs.runCommand "workflow-behavior-check" {nativeBuildInputs = [pkgs.bash pkgs.python3];} ''
        python3 ${../modules/release/test_workflows.py} ${pkgs.writeText "workflows.json" (builtins.toJSON (
          lib.mapAttrs' (stem: lib.nameValuePair ".github/workflows/${stem}.yaml") github.workflows
        ))}
        touch "$out"
      '';
    };
  };
}
