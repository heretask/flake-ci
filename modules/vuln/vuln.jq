# Renders a target manifest and sbomnix SBOMs into scanner inputs. vuln.sh and tests/vuln.nix include it.

# An accept past its `until` drops out, so its finding blocks again. $today is "YYYY-MM-DD".
def live($today): [.accepts[] | select(.until >= $today)];

# osv-scanner can only ignore by ID, so `package` does not narrow these.
def osv_toml($today): live($today)[] | "[[IgnoredVulns]]\nid = \(.id | @json)\nreason = \(.reason | @json)\n";

def accept_rules($today):
  live($today) | map({vulnerability: .id, "include-aliases": true, reason} + if .package then {package: {name: .package}} else {} end);

# sbomnix records the CVEs a nixpkgs patch resolves. They are fixed in that build only, so each rule
# names the component's version, and the `-r0` version the Alpine projection gives it.
def patched_rules:
  [
    (.metadata.component, .components[])
    | .name as $name
    | .version as $version
    | .pedigree.patches[]?.resolves[]?.id
    | {vulnerability: ., package: {name: $name, version: ($version, "\($version)-r0")}, reason: "patched in nixpkgs"}
  ]
  | unique;

# grype matches apk packages against the Alpine secdb, which can list a fix before NVD has a CPE.
# syft takes the version from `.version`, not the purl, so both carry the `-r0` release.
def alpine:
  (.metadata.component, .components[]) |= (
    del(.cpe)
    | if (.version // "") != "" then .version += "-r0" | .purl = "pkg:apk/alpine/\(.name)@\(.version)?distro=alpine-3.24" else . end
  );
