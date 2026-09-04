#!/usr/bin/env bats
# reporting.bats — lib/reporting.sh's generic table/plain formatter,
# against a fixed fixture dataset (per docs/architecture/10-testing-
# strategy.md's reporting.bats description).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${REPO_ROOT}/lib/reporting.sh"
}

@test "report_table aligns columns wider than their header" {
  run bash -c 'source "'"${REPO_ROOT}"'/lib/reporting.sh"; printf "alice|active\nbob|disabled\n" | report_table "USERNAME|STATUS"'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "USERNAME  STATUS    " ]]
  [[ "${lines[1]}" == "alice     active    " ]]
  [[ "${lines[2]}" == "bob       disabled  " ]]
}

@test "report_table prints just the header when there are no data rows" {
  run bash -c 'source "'"${REPO_ROOT}"'/lib/reporting.sh"; printf "" | report_table "USERNAME|STATUS"'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "USERNAME  STATUS  " ]]
}


@test "report_table skips blank input lines" {
  run bash -c 'source "'"${REPO_ROOT}"'/lib/reporting.sh"; printf "alice|active\n\nbob|disabled\n" | report_table "USERNAME|STATUS"'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "report_plain passes pipe-delimited rows through unaligned" {
  run bash -c 'printf "alice|active\nbob|disabled\n" | ( source "'"${REPO_ROOT}"'/lib/reporting.sh"; report_plain )'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "alice|active" ]]
  [[ "${lines[1]}" == "bob|disabled" ]]
}
