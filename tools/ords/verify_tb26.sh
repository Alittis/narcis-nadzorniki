#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# TB-26 half 1 — post-deploy verification for the widened GET-list handler.
#
# READ-ONLY. Issues exactly one GET against
#   https://narcis.gov.si/ords/narcis/disturbances/
# and writes nothing, anywhere. Safe to re-run.
#
# Checks, in the order the runbook (TB-26_DEPLOY.md) lists them:
#   1. the endpoint still returns 200 and the pre-existing payload is intact
#   2. reviewed records carry reviewedBy + reviewedAt
#   3. reviewedAt is a well-formed Z-tagged UTC instant, printed next to its
#      Europe/Ljubljana rendering so it can be eyeballed against the backoffice
#   4. opombaUradna appears NOWHERE in the response (TB-26 half 2 is not shipped)
#
# Usage:
#   bash tools/ords/verify_tb26.sh
#     Prompts for the password with hidden input (nothing lands in shell history).
#
#   APP_AUTH_EMAIL=... APP_AUTH_PASSWORD=... bash tools/ords/verify_tb26.sh
#     Non-interactive, matching the sibling test_*.sh convention.
#
# Exit status: 0 if every check passes, otherwise the number of failures.
# Requires: curl, python3 (both ship with macOS).
#-------------------------------------------------------------------------------

set -u

BASE="${APP_AUTH_BASE:-https://narcis.gov.si/ords/narcis/disturbances/}"
PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '        %s\n' "$1"; }

EMAIL="${APP_AUTH_EMAIL:-}"
if [ -z "$EMAIL" ]; then
  printf 'NarcIS e-mail: '
  read -r EMAIL
fi

PASSWORD="${APP_AUTH_PASSWORD:-}"
if [ -z "$PASSWORD" ]; then
  printf 'NarcIS password (hidden): '
  read -rs PASSWORD
  printf '\n'
fi

if [ -z "$EMAIL" ] || [ -z "$PASSWORD" ]; then
  printf 'Both an e-mail and a password are required.\n' >&2
  exit 1
fi

CREDS_B64=$(printf '%s:%s' "$EMAIL" "$PASSWORD" | base64 | tr -d '\n')
BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT

printf '\nGET %s\n\n' "$BASE"
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -H "X-Narcis-Auth: Basic $CREDS_B64" "$BASE")
unset PASSWORD CREDS_B64

if [ "$CODE" != "200" ]; then
  bad "HTTP $CODE (expected 200)"
  head -c 400 "$BODY"; printf '\n'
  exit 1
fi
ok "HTTP 200"

# 4. the note must not be on the wire — grep the raw bytes, before any parsing
if grep -qi 'opomba' "$BODY"; then
  bad "'opomba' appears in the response — OPOMBA_URADNA must NOT be sent (TB-26 half 2 is not shipped)"
else
  ok "opombaUradna absent from the wire, as intended"
fi

python3 - "$BODY" <<'PY'
import json, sys, datetime

raw = open(sys.argv[1], encoding='utf-8').read()
doc = json.loads(raw)
recs = doc['records'] if isinstance(doc, dict) else doc

def ok(m):   print(f'  \033[32mPASS\033[0m  {m}')
def note(m): print(f'        {m}')

fails = 0
print(f'  ----  {len(recs)} record(s) returned')

# 1. pre-existing payload intact
required = ['id','latitude','longitude','observedAt','createdAt','caseStatus','actionTaken']
missing = [k for k in required if recs and k not in recs[0]]
if missing:
    print(f'  \033[31mFAIL\033[0m  first record is missing pre-existing keys: {missing}'); fails += 1
else:
    ok('pre-existing payload keys still present (no regression)')

# 2 + 3. the review stamp
reviewed = [r for r in recs if r.get('reviewedBy') or r.get('reviewedAt')]
if not reviewed:
    print('  \033[33mNOTE\033[0m  no record carries a review stamp yet.')
    note('This is NOT a failure if the back office has not reviewed anything in')
    note('this org. It IS a failure if you know a record was reviewed — that')
    note('would mean the handler did not actually re-publish.')
else:
    ok(f'{len(reviewed)} record(s) carry a review stamp')
    bad_ts = 0
    for r in reviewed[:5]:
        ts = r.get('reviewedAt')
        who = r.get('reviewedBy')
        if not ts:
            print(f'  \033[31mFAIL\033[0m  {r["id"][:8]}… has reviewedBy but no reviewedAt'); fails += 1
            continue
        if not ts.endswith('Z'):
            print(f'  \033[31mFAIL\033[0m  reviewedAt not Z-tagged: {ts}'); fails += 1; bad_ts += 1
            continue
        utc = datetime.datetime.fromisoformat(ts.replace('Z','+00:00'))
        # Europe/Ljubljana is UTC+1 winter / +2 summer; approximate with the
        # host's own local conversion, which is what the phone will show.
        local = utc.astimezone()
        note(f'{r["id"][:8]}…  {r.get("caseStatus","?"):<22} {who}')
        note(f'          UTC on the wire : {ts}')
        note(f'          shows on phone  : {local.strftime("%d.%m.%Y %H:%M")}')
    if bad_ts == 0:
        ok('every reviewedAt is a well-formed Z-tagged UTC instant')

print()
print('  \033[1mEYEBALL THIS, it is the one thing no script can settle:\033[0m')
print('  open the same record in the web backoffice and compare "shows on phone"')
print('  against the obravnavano time it displays. They must be the SAME')
print('  wall-clock. A 1 h or 2 h gap means OBRAVNAVANO is not stored UTC after')
print('  all and the serializer double-shifts — roll back and re-open TB-26.')

sys.exit(1 if fails else 0)
PY
PY_STATUS=$?

printf '\n%d passed, %d failed (plus the python checks above: exit %d)\n' "$PASS" "$FAIL" "$PY_STATUS"
[ "$FAIL" -eq 0 ] && [ "$PY_STATUS" -eq 0 ] && exit 0
exit $((FAIL + PY_STATUS))
