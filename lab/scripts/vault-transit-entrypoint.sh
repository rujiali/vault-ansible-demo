#!/bin/sh
export VAULT_ADDR=http://127.0.0.1:8200
INIT_FILE=/vault/data/init.json
SEAL_TOKEN_FILE=/vault/data/.seal-token
READY_FILE=/vault/data/.ready

rm -f "$READY_FILE"

vault server -config=/vault/config/vault-transit.hcl &
VAULT_PID=$!

# Wait until vault API responds (exit 2 = sealed/uninit is fine, exit 1 = not up yet)
echo "vault-transit: waiting for API..."
while true; do
  vault status >/dev/null 2>&1; ec=$?
  [ "$ec" -ne 1 ] && break
  sleep 1
done
echo "vault-transit: API ready"

# Initialize on first run
if [ ! -f "$INIT_FILE" ]; then
  echo "vault-transit: initialising..."
  vault operator init -key-shares=1 -key-threshold=1 -format=json > "$INIT_FILE"
  chmod 600 "$INIT_FILE"
fi

UNSEAL_KEY=$(awk -F'"' '/unseal_keys_b64/{getline; gsub(/[^A-Za-z0-9+\/=]/, ""); print; exit}' "$INIT_FILE")
ROOT_TOKEN=$(awk -F'"' '/root_token/{print $4}' "$INIT_FILE")

# Unseal if needed
vault status 2>/dev/null | grep -q "Sealed.*true" && vault operator unseal "$UNSEAL_KEY" >/dev/null

export VAULT_TOKEN=$ROOT_TOKEN

# Ensure transit mount and key exist
vault secrets enable transit 2>/dev/null || true
vault write -f transit/keys/vault-unseal-key 2>/dev/null || true

# Write root token as seal token (root tokens never expire; persists via init.json)
echo "$ROOT_TOKEN" > "$SEAL_TOKEN_FILE"
chmod 600 "$SEAL_TOKEN_FILE"

# Signal ready — healthcheck waits for this file
touch "$READY_FILE"
echo "vault-transit: ready"
wait $VAULT_PID
