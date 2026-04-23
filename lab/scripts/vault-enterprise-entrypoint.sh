#!/bin/sh
SEAL_TOKEN_FILE=/transit-data/.seal-token
echo "waiting for transit seal token..."
until [ -f "$SEAL_TOKEN_FILE" ]; do sleep 1; done
SEAL_TOKEN=$(cat "$SEAL_TOKEN_FILE")
echo "seal token ready — starting vault"
# HCL does not interpolate ${VAR} — substitute token into config at runtime
sed "s|\${VAULT_TRANSIT_SEAL_TOKEN}|$SEAL_TOKEN|g" /vault/config/vault.hcl > /tmp/vault-resolved.hcl
exec vault server -config=/tmp/vault-resolved.hcl
