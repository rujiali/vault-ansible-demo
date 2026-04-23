#!/bin/sh
# Initialise SoftHSM2 token (shared volume) then start Vault.
# All clusters share the same token/key — vault-dr and vault-pr adopt
# vault-primary's master key via replication and unseal with the same PKCS11 key.
set -e

export SOFTHSM2_CONF=/vault/softhsm/softhsm2.conf

mkdir -p /vault/softhsm/tokens

if [ ! -f "$SOFTHSM2_CONF" ]; then
  cat > "$SOFTHSM2_CONF" <<EOF
directories.tokendir = /vault/softhsm/tokens
objectstore.backend = file
log.level = ERROR
EOF
fi

if ! softhsm2-util --show-slots 2>/dev/null | grep -q "vault-hsm"; then
  softhsm2-util --init-token --free \
    --label "vault-hsm" \
    --pin 1234 \
    --so-pin 1234
fi

exec vault server -config=/vault/config/vault.hcl
