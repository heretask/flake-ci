# The findings read from scanner output, and what blocks. vuln.sh, tests/vuln.nix and the self-test
# include it.

def severity_rank: {Critical: 4, High: 3, Medium: 2, Low: 1}[.] // 0;

# vulnxscan and osv-scanner give a CVSS score; the labels are grype's.
def cvss_label:
  (tonumber? // 0) as $score
  | if $score >= 9 then "Critical" elif $score >= 7 then "High" elif $score >= 4 then "Medium" elif $score > 0 then "Low" else "Unknown" end;

# "6.18.64" is release 64 of the 6.18 series; "7.3" and "7.3-rc1" are release 0 of theirs.
def kernel_release:
  [capture("^(?<series>[0-9]+\\.[0-9]+)(\\.(?<patch>[0-9]+))?")][0]
  | if . then {series, patch: ((.patch // "0") | tonumber)} else null end;

# A kernel advisory lists one fix per release series. Only a later release of the installed series
# is a fix that updating brings, so the others are dropped and the finding counts as not fixed.
def series_fixes($installed):
  ($installed | kernel_release) as $have
  | if $have then map(select(kernel_release | . != null and .series == $have.series and .patch > $have.patch)) else . end;

# The fixed versions one vulnxscan observation lists. Alpine sometimes fixes a CVE by patching its own
# build, "3.5.9-r1" for upstream 3.5.9. No upstream release carries that fix, so no update brings
# it and it does not count.
def observed_fixes:
  . as $o
  | .fix_versions
  | split(", ")[]
  | select(. != "" and ($o.scanner != "alpine" or sub("-r[0-9]+$"; "") != $o.version));

# One finding per vulnxscan finding that no nixpkgs patch resolves. Only grype's observations, from
# NVD ("grype") and from the Alpine pass ("alpine"), say whether a fixed version exists, so what
# vulnix or OSV alone report never blocks.
def vulnxscan_findings:
  (.observations | map(select(.fix_state == "fixed")) | group_by(.finding_id) | map({key: .[0].finding_id, value: (map(observed_fixes) | unique)}) | from_entries) as $fixes
  | .findings[]
  | select(.suppressed_by_patch_evidence | not)
  | .version as $version
  | ($fixes[.finding_id] // []) as $fixed
  | {
      lane: "closure",
      id: .vuln_id,
      aliases: [],
      ecosystem: "nix",
      package,
      version,
      severity: (.severity | cvss_label),
      fixedIn: (if .package == "linux" then $fixed | series_fixes($version) else $fixed end),
      sources: .scanners
    };

# One finding per grype match in a directory. `fixedIn` is empty unless grype knows a fixed version.
def grype_findings:
  .matches[]
  | .artifact as $a
  | .vulnerability as $v
  | {
      lane: "dir",
      id: $v.id,
      aliases: ([.relatedVulnerabilities[]?.id] | unique - [$v.id]),
      ecosystem: $a.type,
      package: $a.name,
      version: $a.version,
      severity: $v.severity,
      fixedIn: (if $v.fix.state == "fixed" then $v.fix.versions else [] end),
      sources: [$v.namespace]
    };

# One finding per group of aliases osv-scanner reports for a package.
def osv_findings($lane):
  .results[]?.packages[]
  | .package as $p
  | (.vulnerabilities // []) as $vulns
  | .groups[]
  | .ids as $ids
  | {
      lane: $lane,
      id: $ids[0],
      aliases: ($ids + (.aliases // []) | unique - [$ids[0]]),
      ecosystem: $p.ecosystem,
      package: $p.name,
      version: $p.version,
      severity: (.max_severity | cvss_label),
      fixedIn: ([$vulns[] | select(.id | IN($ids[])) | .affected[]? | select(.package.name == $p.name) | .ranges[]?.events[]?.fixed // empty] | unique),
      sources: ["osv"]
    };

# A package two closures ship is one finding.
def merged:
  group_by([.lane, .ecosystem, .package, .version, .id])
  | map(
      .[0] + {
        aliases: (map(.aliases[]) | unique),
        fixedIn: (map(.fixedIn[]) | unique),
        sources: (map(.sources[]) | unique),
        severity: (max_by(.severity | severity_rank) | .severity)
      }
    );

# The first accept that names the finding's ID or an alias and has not passed its `until`.
def accepted($accepts; $today):
  . as $finding
  | first(
      $accepts[]
      | select(.until >= $today and (.id | IN($finding.id, $finding.aliases[])) and (.package == null or .package == $finding.package))
      | {reason, until}
    )
    // null;

# osv lanes block on any finding. grype lanes block on high and critical findings a fixed version resolves.
def blocking:
  .accepted == null
  and (if .lane == "closure" or .lane == "dir" then .fixedIn != [] and (.severity | severity_rank) >= 3 else true end);

# Input: every lane's findings. $errors: the parts of the scan that failed. $today is "YYYY-MM-DD".
def report($manifest; $target; $mode; $today; $errors):
  ("\($today)T00:00:00Z" | fromdate + 14 * 86400 | strftime("%Y-%m-%d")) as $soon
  | {
      schema: 1,
      target: $target,
      mode: $mode,
      date: $today,
      complete: ($errors == []),
      errors: $errors,
      findings: (
        merged
        | map(.accepted = accepted($manifest.accepts; $today) | .blocking = blocking)
        | sort_by([(.blocking | not), -(.severity | severity_rank), .package, .version, .id, .lane])
      ),
      accepts: [
        $manifest.accepts[]
        | {id, package, reason, until, state: (if .until < $today then "expired" elif .until <= $soon then "expiring" else "live" end)}
      ]
    };

def cell: tostring | gsub("\\|"; "\\|") | gsub("\\s+"; " ");
def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";

# Markdown for a terminal and a job summary, from `report`.
def summary:
  (.findings | map(select(.blocking))) as $blocking
  | (.findings | map(select(.blocking | not))) as $rest
  | ($rest | map(select(.accepted))) as $accepted
  | ($rest - $accepted) as $open
  | (.accepts | map(select(.state != "live"))) as $due
  | "## Vulnerability scan: \(.target)\(if .mode == "quick" then " (lockfiles only)" else "" end)",
    "",
    (if .complete then empty else "**Incomplete.** Part of the scan failed, so findings can be missing:", "", (.errors[] | "- \(cell)"), "" end),
    (
      if $blocking == [] then "No blocking findings\(if .complete then "" else " in the parts that ran" end)."
      else
        "**\(plural($blocking | length; "blocking finding"))** in \(plural($blocking | map(.package) | unique | length; "package")):",
        "",
        "| Package | Version | Lane | Findings | Fixed in |",
        "| --- | --- | --- | --- | --- |",
        (
          $blocking
          | group_by([.package, .version])
          | sort_by([-(map(.severity | severity_rank) | max), .[0].package, .[0].version])[]
          | (unique_by(.id) | sort_by([-(.severity | severity_rank), .id])) as $ids
          | "| \(.[0].package | cell) | \(.[0].version | cell) | \(map(.lane) | unique | join(", ")) | \($ids[:15] | map("\(.id) (\(.severity))") | join(", "))\(if ($ids | length) > 15 then " and \(($ids | length) - 15) more" else "" end) | \(map(.fixedIn[]) | unique | if length > 8 then .[:8] + ["…"] else . end | join(", ") | cell) |"
        )
      end
    ),
    (
      if $rest == [] then empty
      else
        "",
        "\(plural($rest | length; "finding")) \(if ($rest | length) == 1 then "does" else "do" end) not block: \(
          [
            ($open | map(select((.severity | severity_rank) >= 3)) | length | select(. > 0) | "\(.) high or critical without a fixed version"),
            ($open | map(select((.severity | severity_rank) < 3)) | length | select(. > 0) | "\(.) of lower severity"),
            ($accepted | length | select(. > 0) | "\(.) accepted")
          ]
          | join(", ")
        ). `findings.json` lists them."
      end
    ),
    (
      if $due == [] then empty
      else
        "",
        "Accepts that have expired or expire within 14 days:",
        "",
        "| ID | Package | Until | Reason |",
        "| --- | --- | --- | --- |",
        ($due[] | "| \(.id | cell) | \(.package // "any" | cell) | \(.until)\(if .state == "expired" then " (expired)" else "" end) | \(.reason | cell) |")
      end
    );
