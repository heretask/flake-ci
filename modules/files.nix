# Generated, committed files (mightyiam/files): one `files:<path>` check per file.
{
  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: {
    # Replaces the upstream checks, which read the committed file out of the whole flake source:
    # every commit changed all of them, so a build matrix rebuilt each on its own runner. Here a
    # check depends on its own committed file and its generated source, and all share one runner.
    checks = lib.flip lib.mapAttrs' config.files.file (
      path: {source, ...}: let
        committed = config.files.gitToplevel + "/${path}";
        meta.hestia.group = "light";
      in
        lib.nameValuePair "files:${path}" (lib.mkForce (
          if !builtins.pathExists committed
          then
            pkgs.runCommandLocal "flake-file-check" {inherit meta;} ''
              echo ${lib.escapeShellArg "${path} is missing, run: nix run .#write-files"} >&2
              exit 1
            ''
          else
            pkgs.runCommandLocal "flake-file-check" {
              inherit meta source;
              committed = builtins.path {
                path = committed;
                name = "committed";
              };
            } ''
              if ! diff -u --label ${lib.escapeShellArg "${path} (committed)"} "$committed" --label ${lib.escapeShellArg "${path} (generated)"} "$source"; then
                echo ${lib.escapeShellArg "${path} is stale, run: nix run .#write-files"} >&2
                exit 1
              fi
              touch "$out"
            ''
        ))
    );

    # The upstream writer finds the root with `git rev-parse`, which fails in
    # non-colocated jj workspaces; point Git at the workspace's backing repo.
    apps.write-files = {
      meta.description = "Write generated repository files";
      type = "app";
      program = lib.getExe (pkgs.writeShellApplication {
        name = "write-files";
        runtimeInputs = [pkgs.jujutsu];
        text = ''
          if root="$(jj workspace root 2>/dev/null)" && git_dir="$(jj git root 2>/dev/null)"; then
            export GIT_DIR="$git_dir" GIT_WORK_TREE="$root"
          fi
          exec ${lib.getExe config.files.writer.drv}
        '';
      });
    };
  };
}
