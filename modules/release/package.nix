{pkgs}:
pkgs.writeShellApplication {
  name = "release";
  runtimeInputs = [
    pkgs.git
    pkgs.cocogitto
    pkgs.python3
  ];
  text = ''
    exec ${pkgs.python3}/bin/python3 ${./release.py} "$@"
  '';
}
