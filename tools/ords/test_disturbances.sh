#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Smoke tests for the disturbance CRUD endpoints:
#   POST   https://narcis.gov.si/ords/narcis/disturbances/
#   PUT    https://narcis.gov.si/ords/narcis/disturbances/<id>
#   DELETE https://narcis.gov.si/ords/narcis/disturbances/<id>
#
# Verifies:
#   - 401 with no creds / bogus creds.
#   - 201 on a fresh POST (when credentials are supplied).
#   - 200 on a duplicate POST with the same UUID (idempotent re-create).
#   - 200 on PUT with the same UUID.
#   - 204 on DELETE.
#   - 404 on PUT/DELETE for a missing UUID.
#
# Usage:
#   bash tools/ords/test_disturbances.sh
#       Runs failure-path tests only (no credentials needed).
#
#   APP_AUTH_EMAIL=alexis.zrimec@gov.si \
#   APP_AUTH_PASSWORD='...' \
#       bash tools/ords/test_disturbances.sh
#       Also runs the success-path lifecycle (POST -> POST again -> PUT -> DELETE).
#
#   APP_AUTH_BASE=https://other.host/ords/narcis/disturbances/ \
#       bash tools/ords/test_disturbances.sh
#       Override the base URL.
#
# Exit status: 0 if all probes pass, otherwise the count of failed probes.
# Requires: curl, python3 (both ship with macOS), uuidgen.
#-------------------------------------------------------------------------------

set -u

BASE="${APP_AUTH_BASE:-https://narcis.gov.si/ords/narcis/disturbances/}"
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
probe 'POST without auth header' POST '' 401 \
  '{"id":"00000000-0000-0000-0000-000000000000","latitude":45.79,"longitude":14.36,"locationAccuracy":"Natančna","observedAt":"2026-04-25T12:00:00Z","types":[],"description":"x","observers":["x"],"actionTaken":"Brez ukrepanja"}'

probe 'POST with bogus creds' POST '' 401 \
  '{"id":"00000000-0000-0000-0000-000000000000","latitude":45.79,"longitude":14.36,"locationAccuracy":"Natančna","observedAt":"2026-04-25T12:00:00Z","types":[],"description":"x","observers":["x"],"actionTaken":"Brez ukrepanja"}' \
  'noone@example.invalid' 'wrong'

probe 'DELETE without auth header' DELETE '00000000-0000-0000-0000-000000000000' 401

# 2. Success-path lifecycle - only if credentials provided in env.
if [ -n "${APP_AUTH_EMAIL:-}" ] && [ -n "${APP_AUTH_PASSWORD:-}" ]; then
  TEST_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  printf '\n(test record id: %s)\n' "$TEST_ID"

  POST_BODY=$(cat <<EOF
{"id":"${TEST_ID}","latitude":45.79,"longitude":14.36,"locationAccuracy":"Natančna","observedAt":"2026-04-25T12:00:00Z","types":[{"groupCode":"1","typeCode":"a"}],"description":"smoke test","observers":["Smoke Test"],"actionTaken":"Brez ukrepanja","proposedType":null}
EOF
)

  probe 'POST fresh (201 created)' POST '' 201 "$POST_BODY" \
    "$APP_AUTH_EMAIL" "$APP_AUTH_PASSWORD"

  probe 'POST duplicate UUID (200 idempotent)' POST '' 200 "$POST_BODY" \
    "$APP_AUTH_EMAIL" "$APP_AUTH_PASSWORD"

  PUT_BODY=$(cat <<EOF
{"latitude":45.80,"longitude":14.37,"locationAccuracy":"Približna","observedAt":"2026-04-25T13:00:00Z","types":[{"groupCode":"1","typeCode":"b"}],"description":"smoke test (updated)","observers":["Smoke Test"],"actionTaken":"Ustno opozorilo"}
EOF
)

  probe 'PUT existing record (200 updated)' PUT "$TEST_ID" 200 "$PUT_BODY" \
    "$APP_AUTH_EMAIL" "$APP_AUTH_PASSWORD"

  probe 'DELETE existing record (204)' DELETE "$TEST_ID" 204 '' \
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
