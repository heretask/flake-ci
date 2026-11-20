# Prepended by default.nix: system, vuln_jq (directory holding vuln.jq).
if (($# == 0 || $# > 2)) || { (($# == 2)) && [[ $2 != --quick ]]; }; then
  echo "Usage: vuln <target> [--quick]" >&2
  exit 2
fi
target=$1
quick=${2:-}

manifest=$(nix eval --json ".#vuln.$system.\"$target\"")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
today=$(date -u +%F)
rc=0

render() { jq -L "$vuln_jq" "include \"vuln\"; $1" "${@:2}"; }
realise() { nix build --no-link --print-out-paths "$1"; }

render "osv_toml(\"$today\")" -r <<<"$manifest" >"$work/osv.toml"
render "accept_rules(\"$today\")" <<<"$manifest" >"$work/accepts.json"
jq '{ignore: .}' "$work/accepts.json" >"$work/grype.yaml"

mapfile -t lockfiles < <(jq -r '.lockfiles[]' <<<"$manifest")
if ((${#lockfiles[@]})); then
  echo "vuln: lockfiles ${lockfiles[*]}" >&2
  osv-scanner scan source --config "$work/osv.toml" "${lockfiles[@]/#/--lockfile=}" || rc=1
fi
[[ $quick == --quick ]] && exit "$rc"

grype_gate() { grype "$1" --config "$2" --fail-on high --only-fixed || rc=1; }

mapfile -t closures < <(jq -r '.closures[]' <<<"$manifest")
for i in "${!closures[@]}"; do
  out=$(realise "${closures[i]}")
  echo "vuln: closure $out" >&2
  sbom=$work/closure-$i.cdx.json
  sbomnix "$out" --cdx "$sbom" --csv /dev/null --spdx /dev/null >&2
  render '{ignore: (.[0] + (.[1] | patched_rules))}' -s "$work/accepts.json" "$sbom" >"$work/closure-$i.yaml"
  grype_gate "sbom:$sbom" "$work/closure-$i.yaml"
  echo "vuln: closure $out (Alpine secdb)" >&2
  render alpine "$sbom" >"$work/closure-$i.alpine.cdx.json"
  grype_gate "sbom:$work/closure-$i.alpine.cdx.json" "$work/closure-$i.yaml"
done

mapfile -t dirs < <(jq -r '.dirs[]' <<<"$manifest")
for d in "${dirs[@]}"; do
  out=$(realise "$d")
  echo "vuln: dir $out" >&2
  grype_gate "dir:$out" "$work/grype.yaml"
done
exit "$rc"
