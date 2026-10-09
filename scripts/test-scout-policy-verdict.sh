#!/usr/bin/env bash
# Unit tests for scripts/scout-policy-verdict.sh (#98). The fixture rows are
# copied from a real `docker scout policy` run (drift run 37739416333).
set -euo pipefail

verdict="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scout-policy-verdict.sh"
fails=0

table() { # $1 = status of the CVE row, $2 = status of the copyleft row
  cat <<EOF
    ! 'docker scout policy' is experimental and its behaviour might change in the future
Policy status  FAILED  (6/7 policies met)

 Status │                     Policy                     │           Results
────────┼────────────────────────────────────────────────┼─────────────────────────────
 ✓      │ Default non-root user                          │
 $2      │ No copyleft licenses                           │    0 packages
 $1      │ Fixable critical or high vulnerabilities found │    0C    11H     0M     0L
 ✓      │ No high-profile vulnerabilities                │    0C     0H     0M     0L
EOF
}

check() { # $1 = name, $2 = expected verdict, $3 = VEX_CLEAN, stdin = policy output
  local got
  got="$(bash "$verdict" "$3" || true)"
  if [ "$got" = "$2" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: want $2, got $got"; fails=$((fails + 1))
  fi
}

table '!' '✓' | check "only the CVE row fails, probe clean"      vex-only yes
table '!' '✓' | check "only the CVE row fails, probe found C/H"  fail     no
table '!' '!' | check "CVE row and another row fail"            fail     yes
table '✓' '!' | check "another row fails"                       fail     yes
table '✓' '✓' | check "no failing row parsed"                   fail     yes
printf ''     | check "empty output"                            fail     yes

if [ "$fails" -ne 0 ]; then
  echo "scout-policy-verdict: $fails test(s) failed" >&2
  exit 1
fi
echo "scout-policy-verdict: OK"
