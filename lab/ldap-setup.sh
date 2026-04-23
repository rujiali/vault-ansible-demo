#!/usr/bin/env bash
# Seed OpenLDAP with break-glass accounts and configure Vault AD Secrets Engine
set -euo pipefail

LDAP_HOST="localhost"
LDAP_PORT="389"
LDAP_ADMIN_DN="cn=admin,dc=corp,dc=example,dc=com"
LDAP_ADMIN_PASS="admin"
LDAP_BASE="dc=corp,dc=example,dc=com"

VAULT_ADDR="${PRIMARY_ADDR:-http://localhost:8200}"
VAULT_TOKEN="${PRIMARY_TOKEN:-}"

if [ -z "$VAULT_TOKEN" ]; then
  source "$(dirname "$0")/.vault-creds" 2>/dev/null || true
  VAULT_TOKEN="${PRIMARY_TOKEN:-}"
fi

if [ -z "$VAULT_TOKEN" ]; then
  echo "ERROR: VAULT_TOKEN not set. Run: source .vault-creds"
  exit 1
fi

echo "=== Waiting for OpenLDAP ==="
for i in $(seq 1 20); do
  if ldapsearch -x -H "ldap://$LDAP_HOST:$LDAP_PORT" \
    -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASS" \
    -b "$LDAP_BASE" "(objectClass=*)" dn &>/dev/null; then
    echo "OpenLDAP ready"
    break
  fi
  echo -n "."
  sleep 3
done

echo ""
echo "=== Seeding LDAP entries ==="
ldapadd -x -H "ldap://$LDAP_HOST:$LDAP_PORT" \
  -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASS" \
  -f "$(dirname "$0")/ldap-seed.ldif" 2>/dev/null \
  && echo "Entries added" || echo "Entries may already exist — skipping"

echo ""
echo "=== Configuring Vault AD Secrets Engine ==="
export VAULT_ADDR VAULT_TOKEN

# Enable LDAP secrets engine (Vault 2.0: "ldap" v2.0.0+builtin.vault supersedes "openldap" v0.18.0)
vault secrets enable ldap 2>/dev/null || echo "LDAP engine already enabled"

# Configure connection to OpenLDAP
vault write ldap/config \
  binddn="cn=admin,dc=corp,dc=example,dc=com" \
  bindpass="admin" \
  url="ldap://openldap:389" \
  userdn="ou=BreakGlass,dc=corp,dc=example,dc=com" \
  insecure_tls=true \
  starttls=false \
  schema=openldap

echo "LDAP engine configured"

# Create static roles for break-glass accounts
vault write ldap/static-role/breakglass-windows-01 \
  dn="cn=breakglass-win01,ou=BreakGlass,dc=corp,dc=example,dc=com" \
  username="breakglass-win01" \
  rotation_period=24h

vault write ldap/static-role/breakglass-windows-02 \
  dn="cn=breakglass-win02,ou=BreakGlass,dc=corp,dc=example,dc=com" \
  username="breakglass-win02" \
  rotation_period=24h

echo "Static roles created"

echo ""
echo "=== Verify ==="
vault read ldap/static-cred/breakglass-windows-01

echo ""
echo "=== LDAP Setup Complete ==="
echo ""
echo "Read current password:  vault read ldap/static-cred/breakglass-windows-01"
echo "Manual rotation:        vault write -f ldap/rotate-role/breakglass-windows-01"
