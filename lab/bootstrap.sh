#!/usr/bin/env bash
# Bootstrap Vault lab: init, DR replication, PR replication
# Uses PKCS11 auto-unseal (SoftHSM2) — no manual unseal required.
set -euo pipefail

PRIMARY="http://localhost:8200"
DR="http://localhost:8202"
PR="http://localhost:8204"
CREDS_FILE="$(dirname "$0")/.vault-creds"

wait_for_vault() {
  local addr=$1
  local name=$2
  echo -n "Waiting for $name..."
  for i in $(seq 1 30); do
    local out
    out=$(VAULT_ADDR=$addr vault status -format=json 2>/dev/null || true)
    if echo "$out" | grep -q '"initialized"'; then
      echo " ready"
      return 0
    fi
    sleep 2
    echo -n "."
  done
  echo " timeout"
  exit 1
}

wait_for_unseal() {
  local addr=$1
  local name=$2
  echo -n "Waiting for $name to auto-unseal..."
  for i in $(seq 1 20); do
    local sealed
    local st
    st=$(VAULT_ADDR=$addr vault status -format=json 2>/dev/null || true)
    sealed=$(echo "$st" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed',True))" 2>/dev/null || echo "True")
    if [ "$sealed" = "False" ]; then
      echo " unsealed"
      return 0
    fi
    sleep 2
    echo -n "."
  done
  echo " timeout — check PKCS11/SoftHSM2 setup"
  exit 1
}

init_vault() {
  local addr=$1
  local name=$2
  local var_prefix=$3
  local json_file
  json_file="$(dirname "$0")/.${name}-init.json"

  echo ""
  echo "=== $name ==="
  wait_for_vault "$addr" "$name"

  local already_init
  already_init=$(VAULT_ADDR=$addr vault status -format=json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['initialized'])" || echo "False")

  local recovery_key root_token

  if [ "$already_init" = "True" ]; then
    if [ ! -f "$json_file" ]; then
      echo "ERROR: $name already initialised but $json_file not found — wipe data/ and re-run"
      exit 1
    fi
    echo "$name already initialised — loading keys from $json_file"
    recovery_key=$(python3 -c "import json; d=json.load(open('$json_file')); print(d['recovery_keys_b64'][0])")
    root_token=$(python3 -c "import json; d=json.load(open('$json_file')); print(d['root_token'])")
  else
    local init_out
    init_out=$(VAULT_ADDR=$addr vault operator init \
      -recovery-shares=1 -recovery-threshold=1 -format=json)
    echo "$init_out" > "$json_file"
    chmod 600 "$json_file"
    recovery_key=$(echo "$init_out" | python3 -c "import sys,json; print(json.load(sys.stdin)['recovery_keys_b64'][0])")
    root_token=$(echo "$init_out" | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")
    echo "  Init complete — keys saved to $json_file"
  fi

  wait_for_unseal "$addr" "$name"

  echo "  Recovery key : $recovery_key"
  echo "  Root token   : $root_token"

  echo "${var_prefix}_ADDR=$addr" >> "$CREDS_FILE"
  echo "${var_prefix}_RECOVERY_KEY=$recovery_key" >> "$CREDS_FILE"
  echo "${var_prefix}_TOKEN=$root_token" >> "$CREDS_FILE"
}

# ── Start ──────────────────────────────────────────────────────────────────
echo "Vault Lab Bootstrap (Transit Auto-Unseal)"
echo "========================================="

rm -f "$CREDS_FILE"
touch "$CREDS_FILE"
chmod 600 "$CREDS_FILE"

init_vault "$PRIMARY" "vault-primary" "PRIMARY"
init_vault "$DR"      "vault-dr"      "DR"
init_vault "$PR"      "vault-pr"      "PR"

source "$CREDS_FILE"

echo ""
echo "=== Setting up DR Replication ==="
VAULT_ADDR=$PRIMARY VAULT_TOKEN=$PRIMARY_TOKEN \
  vault write -f sys/replication/dr/primary/enable

sleep 3

DR_WRAP_TOKEN=$(VAULT_ADDR=$PRIMARY VAULT_TOKEN=$PRIMARY_TOKEN \
  vault write -format=json sys/replication/dr/primary/secondary-token id=vault-dr \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['wrap_info']['token'])")

VAULT_ADDR=$DR VAULT_TOKEN=$DR_TOKEN \
  vault write sys/replication/dr/secondary/enable token="$DR_WRAP_TOKEN" \
  primary_api_addr="http://vault-primary:8200"

echo "DR replication enabled — vault-dr is secondary"

echo ""
echo "=== Setting up Performance Replication ==="
VAULT_ADDR=$PRIMARY VAULT_TOKEN=$PRIMARY_TOKEN \
  vault write -f sys/replication/performance/primary/enable

sleep 3

PR_WRAP_TOKEN=$(VAULT_ADDR=$PRIMARY VAULT_TOKEN=$PRIMARY_TOKEN \
  vault write -format=json sys/replication/performance/primary/secondary-token id=vault-pr \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['wrap_info']['token'])")

VAULT_ADDR=$PR VAULT_TOKEN=$PR_TOKEN \
  vault write sys/replication/performance/secondary/enable token="$PR_WRAP_TOKEN" \
  primary_api_addr="http://vault-primary:8200"

echo "PR replication enabled — vault-pr is performance secondary"

echo ""
echo "=== Bootstrap Complete ==="
echo ""
echo "Credentials saved to: $CREDS_FILE"
echo ""
echo "Quick access:"
echo "  export VAULT_ADDR=$PRIMARY"
echo "  export VAULT_TOKEN=$PRIMARY_TOKEN"
echo ""
echo "UIs:"
echo "  Primary : http://localhost:8200"
echo "  DR      : http://localhost:8202"
echo "  PR      : http://localhost:8204"
