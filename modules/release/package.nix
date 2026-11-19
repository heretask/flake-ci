{
  pkgs,
  scopes,
}:
pkgs.writeShellApplication {
  name = "release";
  runtimeInputs = [
    pkgs.git
    pkgs.cocogitto
    pkgs.python3
  ];
  text = ''
    export RELEASE_CHANGELOG_SCOPES=${pkgs.lib.escapeShellArg (toString scopes.changelog)}
    export RELEASE_OMITTED_SCOPES=${pkgs.lib.escapeShellArg (toString scopes.other)}
    exec ${pkgs.python3}/bin/python3 ${./release.py} "$@"
  '';
}
