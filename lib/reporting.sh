#!/usr/bin/env bash
# reporting.sh — shared table/plain formatter layer (Phase 8 —
# docs/architecture/00-overview.md's "Structured output everywhere"
# principle). JSON output stays bespoke per-command (built with `jq`
# directly, as user.sh/macs.sh/cert.sh already do) since its shape
# varies too much per command to be worth forcing through one generic
# builder; what genuinely IS shared and was duplicated ad hoc across
# earlier phases (user_list, mac_list, cert_list each hand-rolled their
# own `printf '%-Ns'` column widths) is the aligned-table renderer.
#
# Earlier phases' table output is left as-is here — not a regression,
# just not retrofitted onto this layer in the same change that
# introduces it. New reporting commands (`mac report`, and Phase 9's
# `status`) build on this from the start.

if [[ -n "${__CYFERIO_REPORTING_LOADED:-}" ]]; then
  return 0
fi
__CYFERIO_REPORTING_LOADED=1

# report_table "HEADER1|HEADER2|..." — reads pipe-delimited data rows
# from stdin (the same convention db_query/db_*_list already return),
# one record per line, and prints a header + aligned table with column
# widths computed from the actual data (not hardcoded per-command). A
# field legitimately containing '|' is not supported, same constraint
# database.sh's own '|' separator already carries.
report_table() {
  local header="$1"
  local -a headers
  IFS='|' read -ra headers <<<"${header}"

  local -a widths=()
  local i
  for i in "${!headers[@]}"; do
    widths[i]=${#headers[i]}
  done

  local -a rows=()
  local line
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    rows+=("${line}")
    local -a cols
    IFS='|' read -ra cols <<<"${line}"
    for i in "${!cols[@]}"; do
      if [[ ${#cols[i]} -gt ${widths[i]:-0} ]]; then
        widths[i]=${#cols[i]}
      fi
    done
  done

  local fmt=""
  for i in "${!headers[@]}"; do
    fmt+="%-${widths[i]}s  "
  done

  # shellcheck disable=SC2059  # $fmt is a computed column spec, not user data
  printf -- "${fmt}\n" "${headers[@]}"
  for line in "${rows[@]}"; do
    local -a cols
    IFS='|' read -ra cols <<<"${line}"
    # shellcheck disable=SC2059
    printf -- "${fmt}\n" "${cols[@]}"
  done
}

# report_plain — passthrough of stdin's pipe-delimited rows, unaligned:
# for scripts that want to `cut`/`awk` a reporting command's output
# without a table's padding getting in the way (the third of the three
# formats 00-overview.md promises on every reporting command).
report_plain() {
  cat
}
