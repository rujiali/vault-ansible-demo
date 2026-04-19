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

# Enable OpenLDAP secrets engine (licensed as "OpenLDAP Secrets Engine" in Vault 2.0-ent)
vault secrets enable openldap 2>/dev/null || echo "OpenLDAP engine already enabled"

# Configure connection to OpenLDAP
vault write openldap/config \
  binddn="cn=admin,dc=corp,dc=example,dc=com" \
  bindpass="admin" \
  url="ldap://openldap:389" \
  userdn="ou=BreakGlass,dc=corp,dc=example,dc=com" \
  insecure_tls=true \
  starttls=false \
  schema=openldap

echo "OpenLDAP engine configured"

# Create library set for break-glass accounts
vault write openldap/library/breakglass-windows \
  service_account_names="breakglass-win01,breakglass-win02" \
  ttl=8h \
  max_ttl=24h \
  disable_check_in_enforcement=false

echo "Library set 'breakglass-windows' created"

echo ""
echo "=== Verify ==="
vault read openldap/library/breakglass-windows/status

echo ""
echo "=== LDAP Setup Complete ==="
echo ""
echo "Test checkout:"
echo "  vault write -f openldap/library/breakglass-windows/check-out"
echo ""
echo "Test check-in:"
echo "  vault write -f openldap/library/breakglass-windows/check-in service_account_names=breakglass-win01"
