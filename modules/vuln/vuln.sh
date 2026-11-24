# Prepended by default.nix: system, vuln_jq (directory holding vuln.jq).
usage() {
  echo "Usage: vuln <target> [--quick] [--out DIR]" >&2
  exit 2
}
target=""
mode=full
outdir=""
while (($#)); do
  case $1 in
    --quick) mode=quick ;;
    --out)
      (($# > 1)) || usage
      outdir=$2
      shift
      ;;
    -*) usage ;;
    *)
      [[ -z $target ]] || usage
      target=$1
      ;;
  esac
  shift
done
[[ -n $target ]] || usage

work=$(mktemp -d)
# Exit 1 says "scanned, and findings block". A scan that dies half-way must not say that.
finished=""
trap 'rm -rf "$work"; [[ -n $finished ]] || exit 3' EXIT
today=$(date -u +%F)
: >"$work/findings.jsonl"

errors=()
problem() {
  errors+=("$1")
  echo "vuln: $1" >&2
}
render() { jq -L "$vuln_jq" "include \"vuln\"; $1" "${@:2}"; }
realise() { nix build --no-link --print-out-paths "$1"; }

# osv <lane> <what> <osv-scanner argument>...
osv() {
  local status=0
  osv-scanner scan source --format json "${@:3}" >"$work/scan.json" || status=$?
  # 1 is "findings". Above it the scan failed; 128 is an input without packages.
  if ((status > 1)); then
    problem "$2: osv-scanner exited $status"
  else
    render "osv_findings(\"$1\")" -c "$work/scan.json" >>"$work/findings.jsonl"
  fi
}

# grype_scan <lane> <what> <input> [config]
grype_scan() {
  local status=0
  grype "$3" ${4:+--config "$4"} -o json >"$work/scan.json" || status=$?
  if ((status)); then
    problem "$2: grype exited $status"
  else
    render "grype_findings(\"$1\")" -c "$work/scan.json" >>"$work/findings.jsonl"
  fi
}

if ! manifest=$(nix eval --json ".#vuln.$system.\"$target\""); then
  problem "target $target: evaluation failed"
  manifest='{"closures": [], "dirs": [], "sboms": [], "lockfiles": [], "accepts": []}'
fi

mapfile -t lockfiles < <(jq -r '.lockfiles[]' <<<"$manifest")
if ((${#lockfiles[@]})); then
  echo "vuln: lockfiles ${lockfiles[*]}" >&2
  osv lockfile "lockfiles ${lockfiles[*]}" "${lockfiles[@]/#/--lockfile=}"
fi

if [[ $mode == full ]]; then
  mapfile -t sboms < <(jq -r '.sboms[]' <<<"$manifest")
  for i in "${!sboms[@]}"; do
    if ! out=$(realise "${sboms[i]}"); then
      problem "sbom ${sboms[i]}: build failed"
      continue
    fi
    echo "vuln: sbom $out" >&2
    # osv-scanner picks the parser by file name.
    cp "$out" "$work/sbom-$i.cdx.json"
    osv sbom "sbom $out" --lockfile="$work/sbom-$i.cdx.json"
  done

  mapfile -t closures < <(jq -r '.closures[]' <<<"$manifest")
  for i in "${!closures[@]}"; do
    if ! out=$(realise "${closures[i]}"); then
      problem "closure ${closures[i]}: build failed"
      continue
    fi
    echo "vuln: closure $out" >&2
    sbom=$work/closure-$i.cdx.json
    if ! sbomnix "$out" --cdx "$sbom" --csv /dev/null --spdx /dev/null >&2; then
      problem "closure $out: sbomnix failed"
      continue
    fi
    render '{ignore: patched_rules}' "$sbom" >"$work/closure-$i.yaml"
    grype_scan closure "closure $out" "sbom:$sbom" "$work/closure-$i.yaml"
    echo "vuln: closure $out (Alpine secdb)" >&2
    render alpine "$sbom" >"$work/closure-$i.alpine.cdx.json"
    grype_scan closure "closure $out (Alpine secdb)" "sbom:$work/closure-$i.alpine.cdx.json" "$work/closure-$i.yaml"
  done

  mapfile -t dirs < <(jq -r '.dirs[]' <<<"$manifest")
  for d in "${dirs[@]}"; do
    if ! out=$(realise "$d"); then
      problem "dir $d: build failed"
      continue
    fi
    echo "vuln: dir $out" >&2
    grype_scan dir "dir $out" "dir:$out"
  done
fi

# shellcheck disable=SC2016 # jq's variables, not the shell's
render 'report($manifest; $target; $mode; $today; $errors)' -s \
  --argjson manifest "$manifest" --arg target "$target" --arg mode "$mode" --arg today "$today" \
  --argjson errors "$(jq -n '$ARGS.positional' --args "${errors[@]}")" \
  "$work/findings.jsonl" >"$work/findings.json"
render summary -r "$work/findings.json" >"$work/summary.md"
cat "$work/summary.md"
if [[ -n $outdir ]]; then
  mkdir -p "$outdir"
  cp "$work/findings.json" "$work/summary.md" "$outdir/"
fi

finished=1
if ((${#errors[@]})); then
  exit 3
fi
if jq -e 'any(.findings[]; .blocking)' "$work/findings.json" >/dev/null; then
  exit 1
fi
exit 0
