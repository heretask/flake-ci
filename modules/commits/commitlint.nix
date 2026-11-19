{
  commits,
  pkgs,
}:
pkgs.writeShellApplication {
  name = "commitlint";
  text = ''
    ${commits.titleCheck}

    squash_merged=
    if [[ "''${1-}" == --squash-merged ]]; then
      squash_merged=--squash-merged
      shift
    fi
    if [[ $# -gt 0 ]]; then
      echo "usage: commitlint [--squash-merged] < commit-message" >&2
      exit 2
    fi

    message=$(cat)
    check_title "''${message%%$'\n'*}" $squash_merged
  '';
}
