#!/usr/bin/env bash
# Bootstrap Vault lab: init, unseal, DR replication, PR replication
set -euo pipefail

PRIMARY="http://localhost:8200"
DR="http://localhost:8202"
PR="http://localhost:8204"
CREDS_FILE="$(dirname "$0")/.vault-creds"

wait_for_vault() {
  local addr=$1
  local name=$2
  local output
  echo -n "Waiting for $name..."
  for i in $(seq 1 30); do
    output=$(VAULT_ADDR=$addr vault status -format=json 2>/dev/null) || true
    if echo "$output" | grep -q '"initialized"'; then
      echo " ready"
      return 0
    fi
    sleep 2
    echo -n "."
  done
  echo " timeout"
  exit 1
}

init_and_unseal() {
  local addr=$1
  local name=$2
  local var_prefix=$3

  echo ""
  echo "=== $name ==="
  wait_for_vault "$addr" "$name"

  local already_init status_out
  status_out=$(VAULT_ADDR=$addr vault status -format=json 2>/dev/null) || true
  already_init=$(echo "$status_out" | python3 -c "import sys,json; print(json.load(sys.stdin)['initialized'])")
  if [ "$already_init" = "True" ]; then
    echo "$name already initialized — skipping"
    return
  fi

  local init_out
  init_out=$(VAULT_ADDR=$addr vault operator init -key-shares=1 -key-threshold=1 -format=json)
  local unseal_key root_token
  unseal_key=$(echo "$init_out" | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][0])")
  root_token=$(echo "$init_out" | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")

  VAULT_ADDR=$addr vault operator unseal "$unseal_key"
  echo "  Unseal key : $unseal_key"
  echo "  Root token : $root_token"

  # Append to creds file
  echo "${var_prefix}_ADDR=$addr" >> "$CREDS_FILE"
  echo "${var_prefix}_UNSEAL_KEY=$unseal_key" >> "$CREDS_FILE"
  echo "${var_prefix}_TOKEN=$root_token" >> "$CREDS_FILE"
}

# ── Start ──────────────────────────────────────────────────────────────────
echo "Vault Lab Bootstrap"
echo "==================="

# Clear old creds
rm -f "$CREDS_FILE"
touch "$CREDS_FILE"
chmod 600 "$CREDS_FILE"

init_and_unseal "$PRIMARY" "vault-primary" "PRIMARY"
init_and_unseal "$DR"      "vault-dr"      "DR"
init_and_unseal "$PR"      "vault-pr"      "PR"

# Load creds
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
