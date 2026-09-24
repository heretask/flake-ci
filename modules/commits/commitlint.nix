{
  commits,
  pkgs,
}: let
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
      "description-max-length" = {
        level = "error";
        length = commits.maxLength;
      };
    };
  };
in
  pkgs.writeShellApplication {
    name = "commitlint";
    runtimeInputs = [pkgs.commitlint-rs];
    text = ''
      exec commitlint --config ${config} "$@"
    '';
  }
