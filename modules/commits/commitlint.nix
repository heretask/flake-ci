{
  commits,
  pkgs,
}: let
  # No description-max-length rule: commitlint-rs counts bytes and rejects a
  # description of exactly the limit, so it disagrees with the PR-title pattern.
  # The wrapper below checks the length itself.
  config = (pkgs.formats.yaml {}).generate "commitlint.yaml" {
    rules = {
      type = {
        level = "error";
        options = builtins.attrNames commits.types;
      };
      "type-format" = {
        level = "error";
        format = "^[a-z][a-z0-9-]*$";
      };
      "type-empty".level = "error";
      "subject-empty".level = "error";
      "description-empty".level = "error";
    };
  };
in
  pkgs.writeShellApplication {
    name = "commitlint";
    runtimeInputs = [pkgs.commitlint-rs];
    text = ''
      squash_merged=false
      if [[ "''${1-}" == --squash-merged ]]; then
        squash_merged=true
        shift
      fi
      if [[ $# -gt 0 ]]; then
        echo "usage: commitlint [--squash-merged] < commit-message" >&2
        exit 2
      fi

      message=$(cat)
      subject=''${message%%$'\n'*}
      rest=''${message#"$subject"}

      # GitHub appends " (#<PR number>)" to the PR title when it squash-merges.
      # The PR-title check never saw that suffix, so it does not count here.
      if $squash_merged && [[ "$subject" =~ ^(.*)\ \(#[0-9]+\)$ ]]; then
        subject=''${BASH_REMATCH[1]}
      fi

      printf '%s%s\n' "$subject" "$rest" | commitlint --config ${config}

      # Count characters in any locale: drop the UTF-8 continuation bytes.
      description=''${subject#*: }
      LC_ALL=C
      characters=''${description//[$'\x80'-$'\xbf']/}
      length=''${#characters}
      if ((length > ${toString commits.maxLength})); then
        # A pushed commit cannot be reworded, so its length is only reported.
        if $squash_merged; then
          echo "warning: description is $length characters, the limit is ${toString commits.maxLength}" >&2
        else
          echo "description is $length characters, the limit is ${toString commits.maxLength}" >&2
          exit 1
        fi
      fi
    '';
  }
