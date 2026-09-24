# Generated, committed files (mightyiam/files): one `files:<path>` check per file.
{
  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: {
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
