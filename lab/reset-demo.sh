#!/usr/bin/env bash
# Reset all clusters to the pre-demo state so the demo can be re-run.
# Safe to run at any point — handles partial failures gracefully.
set -euo pipefail
cd "$(dirname "$0")"

source .vault-creds

PRIMARY_ADDR=http://localhost:8200
DR_ADDR=http://localhost:8202
PR_ADDR=http://localhost:8204

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()   { printf "  ${GRN}✓${NC}  %s\n" "$*"; }
info() { printf "  ${DIM}…${NC}  %s\n" "$*"; }
warn() { printf "  ${YLW}!${NC}  %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC}  %s\n" "$*"; }

echo ""
printf "  ${BLD}Demo Reset — restoring pre-demo topology${NC}\n"
echo ""

# ── Step 1: Ensure vault-primary is running and unsealed ──────
printf "  ${BLD}[1/6] vault-primary${NC}\n"

if ! docker compose ps vault-primary 2>/dev/null | grep -q "running"; then
  info "Starting vault-primary..."
  docker compose start vault-primary >/dev/null 2>&1
  sleep 5
fi

_st=$(VAULT_ADDR=$PRIMARY_ADDR vault status -format=json 2>/dev/null || true)
PRIMARY_SEALED=$(echo "$_st" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed',True))" 2>/dev/null || echo "True")

if [ "$PRIMARY_SEALED" != "False" ]; then
  info "Unsealing vault-primary..."
  VAULT_ADDR=$PRIMARY_ADDR vault operator unseal "$PRIMARY_UNSEAL_KEY" >/dev/null 2>&1 || true
  sleep 3
fi

_st=$(VAULT_ADDR=$PRIMARY_ADDR vault status -format=json 2>/dev/null || true)
PRIMARY_STATUS=$(echo "$_st" | python3 -c "import sys,json; d=json.load(sys.stdin); print('active' if not d.get('sealed') else 'sealed')" 2>/dev/null || echo "unreachable")

if [ "$PRIMARY_STATUS" = "active" ]; then
  ok "vault-primary is active"
else
  fail "vault-primary is $PRIMARY_STATUS — cannot continue"
  exit 1
fi

# ── Step 2: Ensure vault-dr is running and unsealed ───────────
printf "\n  ${BLD}[2/6] vault-dr${NC}\n"

if ! docker compose ps vault-dr 2>/dev/null | grep -q "running"; then
  info "Starting vault-dr..."
  docker compose start vault-dr >/dev/null 2>&1
  sleep 5
fi

VAULT_ADDR=$DR_ADDR vault operator unseal "$PRIMARY_UNSEAL_KEY" >/dev/null 2>&1 || true
sleep 2
ok "vault-dr is up"

# ── Step 3: Ensure vault-pr is running and unsealed ───────────
printf "\n  ${BLD}[3/6] vault-pr${NC}\n"

if ! docker compose ps vault-pr 2>/dev/null | grep -q "running"; then
  info "Starting vault-pr..."
  docker compose start vault-pr >/dev/null 2>&1
  sleep 5
fi

VAULT_ADDR=$PR_ADDR vault operator unseal "$PRIMARY_UNSEAL_KEY" >/dev/null 2>&1 || true
sleep 2
ok "vault-pr is up"

# ── Step 4: Restore DR replication (vault-dr as secondary) ────
printf "\n  ${BLD}[4/6] DR replication${NC}\n"

_dr_repl=$(VAULT_ADDR=$DR_ADDR vault read -format=json sys/replication/status 2>/dev/null || true)
DR_MODE=$(echo "$_dr_repl" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'].get('dr',{}).get('mode','unknown'))" 2>/dev/null || echo "unknown")
DR_PR_MODE=$(echo "$_dr_repl" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'].get('performance',{}).get('mode','disabled'))" 2>/dev/null || echo "disabled")

DR_CONN=$(VAULT_ADDR=$DR_ADDR vault read -format=json sys/replication/dr/status 2>/dev/null \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)['data']
secs=d.get('primaries',[]) or d.get('secondaries',[])
print(secs[0].get('connection_status','') if secs else '')
" 2>/dev/null || echo "")

if [ "$DR_MODE" = "secondary" ] && [ "$DR_CONN" = "connected" ]; then
  ok "vault-dr is already a connected DR secondary — no action needed"
else
  info "vault-dr DR mode='$DR_MODE' PR mode='$DR_PR_MODE' — re-establishing as DR secondary..."

  # Tear down any performance primary state on vault-dr
  if [ "$DR_PR_MODE" = "primary" ]; then
    info "Disabling performance primary on vault-dr..."
    VAULT_ADDR=$DR_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
      vault write -f sys/replication/performance/primary/disable >/dev/null 2>&1 || true
    sleep 4
    VAULT_ADDR=$DR_ADDR vault operator unseal "$PRIMARY_UNSEAL_KEY" >/dev/null 2>&1 || true
    sleep 2
  fi

  # Tear down any DR primary state on vault-dr
  if [ "$DR_MODE" = "primary" ]; then
    info "Disabling DR primary on vault-dr..."
    VAULT_ADDR=$DR_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
      vault write -f sys/replication/dr/primary/disable >/dev/null 2>&1 || true
    sleep 3
    VAULT_ADDR=$DR_ADDR vault operator unseal "$PRIMARY_UNSEAL_KEY" >/dev/null 2>&1 || true
    sleep 2
  fi

  # Revoke vault-dr on primary (idempotent)
  info "Revoking old vault-dr secondary on primary..."
  VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
    vault write -f sys/replication/dr/primary/revoke-secondary id=vault-dr >/dev/null 2>&1 || true
  sleep 2

  # Generate new secondary token
  info "Generating DR secondary token..."
  DR_WRAP=$(VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
    vault write -format=json sys/replication/dr/primary/secondary-token id=vault-dr \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['wrap_info']['token'])")

  # Enable secondary
  info "Enrolling vault-dr as DR secondary..."
  VAULT_ADDR=$DR_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
    vault write sys/replication/dr/secondary/enable \
    token="$DR_WRAP" \
    primary_api_addr=http://vault-primary:8200 >/dev/null 2>&1 || true
  sleep 8
  VAULT_ADDR=$DR_ADDR vault operator unseal "$PRIMARY_UNSEAL_KEY" >/dev/null 2>&1 || true
  sleep 3

  # Verify
  _dr_st=$(VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
    vault read -format=json sys/replication/dr/status 2>/dev/null || true)
  DR_MODE2=$(echo "$_dr_st" | python3 -c "
import sys,json
d=json.load(sys.stdin)['data']
secs=d.get('secondaries',[])
print(secs[0].get('connection_status','unknown') if secs else 'not enrolled')
" 2>/dev/null || echo "unknown")

  if [ "$DR_MODE2" = "connected" ]; then
    ok "vault-dr enrolled as DR secondary (connected)"
  else
    warn "vault-dr secondary connection status: $DR_MODE2 (may still be syncing)"
  fi
fi

# ── Step 5: Restore PR replication (vault-pr → vault-primary) ─
# Always wipe and re-init vault-pr — PR secondary token stores are cluster-specific
# (primary tokens don't validate on secondaries) and the demo leaves vault-pr in an
# unpredictable state after DR failover. A fresh init + full snapshot is the only
# reliable path back to a clean secondary.
printf "\n  ${BLD}[5/6] PR replication${NC}\n"

info "Wiping and re-initialising vault-pr for a clean secondary..."
VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
  vault write -f sys/replication/performance/primary/revoke-secondary id=vault-pr >/dev/null 2>&1 || true
docker compose stop vault-pr >/dev/null 2>&1
rm -rf data/pr
docker compose start vault-pr >/dev/null 2>&1
sleep 5

_pr_init_json=$(VAULT_ADDR=$PR_ADDR vault operator init \
  -key-shares=1 -key-threshold=1 -format=json 2>/dev/null || echo "")
if [ -z "$_pr_init_json" ]; then
  warn "vault-pr init failed — skipping PR replication restore"
else
  _new_pr_unseal=$(echo "$_pr_init_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][0])")
  _new_pr_root=$(echo "$_pr_init_json"   | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")
  VAULT_ADDR=$PR_ADDR vault operator unseal "$_new_pr_unseal" >/dev/null

  # Save new vault-pr credentials
  sed -i '' "s|^PR_UNSEAL_KEY=.*|PR_UNSEAL_KEY=$_new_pr_unseal|" .vault-creds
  sed -i '' "s|^PR_TOKEN=.*|PR_TOKEN=$_new_pr_root|" .vault-creds
  PR_UNSEAL_KEY="$_new_pr_unseal"
  PR_TOKEN="$_new_pr_root"

  PR_WRAP=$(VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
    vault write -format=json sys/replication/performance/primary/secondary-token id=vault-pr \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['wrap_info']['token'])")

  VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_new_pr_root \
    vault write sys/replication/performance/secondary/enable \
    token="$PR_WRAP" \
    primary_api_addr=http://vault-primary:8200 >/dev/null 2>&1

  info "Waiting 45s for full snapshot sync..."
  sleep 45
  VAULT_ADDR=$PR_ADDR vault operator unseal "$PRIMARY_UNSEAL_KEY" >/dev/null 2>&1 || true
  sleep 5

  PR_CONN2=$(VAULT_ADDR=$PR_ADDR vault read -format=json sys/replication/performance/status 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)['data']
prims=d.get('primaries',[])
print(prims[0].get('connection_status','unknown') if prims else 'not enrolled')
" 2>/dev/null || echo "unknown")

  if [ "$PR_CONN2" = "connected" ]; then
    ok "vault-pr initialised as PR secondary of vault-primary (connected)"
  else
    warn "vault-pr connection status: $PR_CONN2 (may still be syncing)"
  fi
fi

# ── Step 6: LDAP library check-in (release any checked-out accounts)
printf "\n  ${BLD}[6/6] LDAP library cleanup${NC}\n"

CHECKED_OUT=$(VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
  vault read -format=json ldap/library/breakglass-windows/status 2>/dev/null \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)['data']
out=[name for name,info in d.items() if not info.get('available',True)]
print(' '.join(out))
" 2>/dev/null || echo "")

if [ -n "$CHECKED_OUT" ]; then
  for ACCT in $CHECKED_OUT; do
    info "Force-checking in $ACCT..."
    VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
      vault write -f "ldap/library/breakglass-windows/check-in" \
      service_account_names="$ACCT" >/dev/null 2>&1 || true
  done
  ok "LDAP accounts returned to library"
else
  ok "All LDAP library accounts are available"
fi

# ── Final summary ──────────────────────────────────────────────
echo ""
printf "  ${BLD}Reset complete — final topology:${NC}\n"
echo ""

PRIMARY_DR=$(VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
  vault read -format=json sys/replication/dr/status 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d.get('mode','?'), '/', len(d.get('secondaries',[])), 'secondaries')" 2>/dev/null || echo "?")

PRIMARY_PR=$(VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
  vault read -format=json sys/replication/performance/status 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d.get('mode','?'), '/', len(d.get('secondaries',[])), 'secondaries')" 2>/dev/null || echo "?")

DR_ST=$(VAULT_ADDR=$DR_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
  vault read -format=json sys/replication/dr/status 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d.get('mode','?'), d.get('state',''))" 2>/dev/null || echo "?")

PR_ST=$(VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$PR_TOKEN \
  vault read -format=json sys/replication/performance/status 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d.get('mode','?'), d.get('state',''))" 2>/dev/null || echo "?")

printf "  ${GRN}vault-primary${NC}  DR:   %s\n" "$PRIMARY_DR"
printf "  ${GRN}vault-primary${NC}  PR:   %s\n" "$PRIMARY_PR"
printf "  ${GRN}vault-dr     ${NC}  DR:   %s\n" "$DR_ST"
printf "  ${GRN}vault-pr     ${NC}  PR:   %s\n" "$PR_ST"
echo ""
printf "  Run ${BLD}./demo.sh${NC} to start the demo from the beginning.\n"
printf "  Run ${BLD}./demo.sh --section 3${NC} to jump straight to DR.\n"
echo ""
