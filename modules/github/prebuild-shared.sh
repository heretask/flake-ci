# Builds the uncached derivations that more than one matrix job depends on, so the jobs fetch them
# instead of each building its own copy. Expects MATRIX (hestia's matrix JSON) and NIX_BUILD.
# Never fails the job: a derivation that does not build is reported by the jobs that need it.
prebuild_shared() {
  local work jobs i installables
  work=$(mktemp -d) || return
  mapfile -t jobs < <(jq -r '.include[].installables' <<<"$MATRIX")
  if ((${#jobs[@]} < 2)); then
    echo "Fewer than two build jobs: nothing is shared."
    return 0
  fi

  for i in "${!jobs[@]}"; do
    read -ra installables <<<"${jobs[i]}"
    printf '%s\n' "${installables[@]}" >>"$work/installables"
    # A job's closure once, however many of its checks need a derivation.
    nix-store --query --requisites "${installables[@]%^*}" >"$work/requisites" || return
    grep '\.drv$' "$work/requisites" | sort -u >"$work/closure.$i"
  done

  # The derivations no cache has, across all jobs.
  nix build --dry-run --stdin <"$work/installables" >"$work/dry-run" 2>&1 || {
    cat "$work/dry-run"
    return 1
  }
  sed -n 's|^ *\(/nix/store/.*\.drv\)$|\1|p' "$work/dry-run" | sort -u >"$work/missing"
  sort "$work"/closure.* | uniq -d | comm -12 - "$work/missing" >"$work/shared"

  if [[ ! -s $work/shared ]]; then
    echo "No uncached derivation is shared between build jobs."
    return 0
  fi
  echo "Building $(wc -l <"$work/shared") derivation(s) that several build jobs need:"
  cat "$work/shared"
  # shellcheck disable=SC2086 # NIX_BUILD is a command line.
  sed 's/$/^*/' "$work/shared" | $NIX_BUILD --no-link --keep-going --stdin
}

if ! prebuild_shared; then
  echo "::warning title=Shared dependencies::Not every shared dependency was built here; each build job builds what it still needs."
fi
