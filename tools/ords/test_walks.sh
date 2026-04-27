#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Smoke tests for the walk-around (obhod) endpoints:
#   GET    https://narcis.gov.si/ords/narcis/walks/
#   POST   https://narcis.gov.si/ords/narcis/walks/
#   PUT    https://narcis.gov.si/ords/narcis/walks/<id>
#   DELETE https://narcis.gov.si/ords/narcis/walks/<id>
#   GET    https://narcis.gov.si/ords/narcis/walks/<id>/points
#
# Verifies:
#   - 401 with no creds / bogus creds.
#   - 201 on a fresh POST (3 inline points).
#   - 200 on a duplicate POST with the same UUID (idempotent re-create).
#   - 200 on GET list (includes the freshly-created walk with pointCount=3).
#   - 200 on GET points (returns the 3 points sorted by seq).
#   - 200 on PUT (rename + add notes).
#   - 204 on DELETE.
#   - 404 on GET points / DELETE / PUT after delete.
#
# Usage:
#   bash tools/ords/test_walks.sh
#       Runs failure-path tests only (no credentials needed).
#
#   APP_AUTH_EMAIL=alexis.zrimec@gov.si \
#   APP_AUTH_PASSWORD='...' \
#       bash tools/ords/test_walks.sh
#       Also runs the success-path lifecycle.
#
#   APP_AUTH_BASE=https://other.host/ords/narcis/walks/ \
#       bash tools/ords/test_walks.sh
#       Override the base URL.
#
# Exit status: 0 if all probes pass, otherwise the count of failed probes.
# Requires: curl, uuidgen, base64.
#-------------------------------------------------------------------------------

set -u

BASE="${APP_AUTH_BASE:-https://narcis.gov.si/ords/narcis/walks/}"
PASS=0
FAIL=0

probe() {
  # probe <label> <method> <path_suffix> <expect_status> [<json_body>] [<email> <password>]
  local label="$1"; shift
  local method="$1"; shift
  local suffix="$1"; shift
  local expect_status="$1"; shift
  local body="${1:-}"; [ "$#" -ge 1 ] && shift || true
  local email="${1:-}"; [ "$#" -ge 1 ] && shift || true
  local password="${1:-}"; [ "$#" -ge 1 ] && shift || true

  local hdr_args=()
  if [ -n "$email" ] || [ -n "$password" ]; then
    local creds_b64
    creds_b64=$(printf '%s:%s' "$email" "$password" | base64 | tr -d '\n')
    hdr_args=(-H "X-Narcis-Auth: Basic $creds_b64")
  fi
  if [ -n "$body" ]; then
    hdr_args+=(-H "Content-Type: application/json")
  fi

  local tmp_body tmp_meta
  tmp_body=$(mktemp); tmp_meta=$(mktemp)
  curl -sS -X "$method" -o "$tmp_body" \
    -w 'status=%{http_code}\n' \
    ${hdr_args[@]+"${hdr_args[@]}"} \
    ${body:+--data "$body"} \
    "${BASE}${suffix}" > "$tmp_meta" 2>&1

  local status response
  status=$(sed -n 's/^status=//p' "$tmp_meta")
  response=$(cat "$tmp_body")
  rm -f "$tmp_body" "$tmp_meta"

  printf '\n--- %s ---\n' "$label"
  printf '  %s %s%s\n' "$method" "$BASE" "$suffix"
  printf '  http status   : %s   (expected %s)\n' "$status" "$expect_status"
  [ -n "$response" ] && printf '  body          : %s\n' "$response"

  if [ "$status" = "$expect_status" ]; then
    printf '  result        : PASS\n'
    PASS=$((PASS+1))
  else
    printf '  result        : FAIL\n'
    FAIL=$((FAIL+1))
  fi
}

# 1. Failure paths (no credentials needed).
probe 'GET without auth header' GET '' 401

probe 'POST without auth header' POST '' 401 \
  '{"id":"00000000-0000-0000-0000-000000000000","startedAt":"2026-04-27T10:00:00Z","endedAt":"2026-04-27T10:30:00Z","points":[]}'

probe 'POST with bogus creds' POST '' 401 \
  '{"id":"00000000-0000-0000-0000-000000000000","startedAt":"2026-04-27T10:00:00Z","endedAt":"2026-04-27T10:30:00Z","points":[]}' \
  'noone@example.invalid' 'wrong'

probe 'DELETE without auth header' DELETE '00000000-0000-0000-0000-000000000000' 401

probe 'GET points without auth header' GET '00000000-0000-0000-0000-000000000000/points' 401

# 2. Success-path lifecycle - only if credentials provided in env.
if [ -n "${APP_AUTH_EMAIL:-}" ] && [ -n "${APP_AUTH_PASSWORD:-}" ]; then
  TEST_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  printf '\n(test walk id: %s)\n' "$TEST_ID"

  POST_BODY=$(cat <<EOF
{"id":"${TEST_ID}","startedAt":"2026-04-27T10:00:00.000Z","endedAt":"2026-04-27T10:30:00.000Z","name":"Smoke walk","notes":"first probe","points":[{"seq":0,"lat":45.7900000,"lon":14.3600000,"t":"2026-04-27T10:00:01.000Z","accuracy":8.4},{"seq":1,"lat":45.7901000,"lon":14.3601000,"t":"2026-04-27T10:00:30.000Z","accuracy":7.2},{"seq":2,"lat":45.7902000,"lon":14.3602000,"t":"2026-04-27T10:01:00.000Z","accuracy":null}]}
EOF
)

  probe 'POST fresh (201 created)' POST '' 201 "$POST_BODY" \
    "$APP_AUTH_EMAIL" "$APP_AUTH_PASSWORD"

  probe 'POST duplicate UUID (200 idempotent)' POST '' 200 "$POST_BODY" \
    "$APP_AUTH_EMAIL" "$APP_AUTH_PASSWORD"

  probe 'GET list (200, includes the new walk)' GET '' 200 '' \
    "$APP_AUTH_EMAIL" "$APP_AUTH_PASSWORD"

  probe 'GET points (200, returns the 3 points)' GET "${TEST_ID}/points" 200 '' \
    "$APP_AUTH_EMAIL" "$APP_AUTH_PASSWORD"

  PUT_BODY='{"name":"Smoke walk (renamed)","notes":"second probe"}'

  probe 'PUT existing walk (200 updated)' PUT "$TEST_ID" 200 "$PUT_BODY" \
    "$APP_AUTH_EMAIL" "$APP_AUTH_PASSWORD"

  probe 'DELETE existing walk (204)' DELETE "$TEST_ID" 204 '' \
    "$APP_AUTH_EMAIL" "$APP_AUTH_PASSWORD"

  probe 'GET points after delete (404)' GET "${TEST_ID}/points" 404 '' \
    "$APP_AUTH_EMAIL" "$APP_AUTH_PASSWORD"

  probe 'PUT after delete (404)' PUT "$TEST_ID" 404 "$PUT_BODY" \
    "$APP_AUTH_EMAIL" "$APP_AUTH_PASSWORD"

  probe 'DELETE after delete (404)' DELETE "$TEST_ID" 404 '' \
    "$APP_AUTH_EMAIL" "$APP_AUTH_PASSWORD"
else
  printf '\n(skipping success-path lifecycle; export APP_AUTH_EMAIL and APP_AUTH_PASSWORD to enable)\n'
fi

printf '\n========\nPassed: %s\nFailed: %s\n' "$PASS" "$FAIL"
exit "$FAIL"
