#!/usr/bin/env bash
# One-time Vault configuration for the demo
# Run once after bootstrap.sh and ldap-setup.sh
set -euo pipefail
cd "$(dirname "$0")"

source .vault-creds
export VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN

RHEL_IP="192.168.234.133"
RHEL_USER="ansible"
RHEL_KEY="$HOME/.ssh/lab_key"

echo "=== Vault Demo Setup ==="
echo ""

# ── Secret Engines ────────────────────────────────────────────
echo "--- Enabling secret engines ---"
vault secrets enable -version=2 -path=secret kv 2>/dev/null || echo "(kv already enabled)"
vault secrets enable ssh 2>/dev/null || echo "(ssh already enabled)"
vault plugin register -download -version="0.1.0+ent" secret vault-plugin-secrets-os 2>/dev/null || echo "(os plugin already registered)"
vault secrets enable -path=os -plugin-version="0.1.0+ent" vault-plugin-secrets-os 2>/dev/null || echo "(os already enabled)"

# ── Auth Methods ──────────────────────────────────────────────
echo "--- Enabling auth methods ---"
vault auth enable approle 2>/dev/null || echo "(approle already enabled)"

# ── Ansible Policy ────────────────────────────────────────────
echo "--- Creating Ansible policy ---"
vault policy write ansible-rotation - <<'EOF'
path "secret/data/ansible/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "secret/metadata/ansible/*" {
  capabilities = ["read", "list"]
}
path "ssh/creds/otp-rhel" {
  capabilities = ["create", "update"]
}
EOF
echo "Policy 'ansible-rotation' created"

# ── AppRole ───────────────────────────────────────────────────
echo ""
echo "--- Creating AppRole for Ansible ---"
vault write auth/approle/role/ansible \
  token_policies="ansible-rotation" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=24h

ROLE_ID=$(vault read -field=role_id auth/approle/role/ansible/role-id)
SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/ansible/secret-id)

cat > .ansible-approle <<EOF
ANSIBLE_ROLE_ID=$ROLE_ID
ANSIBLE_SECRET_ID=$SECRET_ID
EOF
chmod 600 .ansible-approle
echo "AppRole 'ansible' created — creds saved to .ansible-approle"

# ── SSH Key Pair (initial) ────────────────────────────────────
echo ""
echo "--- Generating initial SSH key pair ---"
rm -f /tmp/demo_vault_key /tmp/demo_vault_key.pub
ssh-keygen -t ed25519 -f /tmp/demo_vault_key -N "" -C "vault-managed" -q

echo "Deploying initial public key to RHEL..."
scp -i "$RHEL_KEY" -o StrictHostKeyChecking=no \
  /tmp/demo_vault_key.pub "$RHEL_USER@$RHEL_IP:/tmp/vault_demo.pub"

ssh -i "$RHEL_KEY" -o StrictHostKeyChecking=no "$RHEL_USER@$RHEL_IP" '
  mkdir -p ~/.ssh
  { grep -v "vault-managed" ~/.ssh/authorized_keys 2>/dev/null; cat /tmp/vault_demo.pub; } \
    > /tmp/ak.tmp && mv /tmp/ak.tmp ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
  rm -f /tmp/vault_demo.pub
'

vault kv put secret/ansible/ssh-key \
  private_key="$(cat /tmp/demo_vault_key)" \
  public_key="$(cat /tmp/demo_vault_key.pub)"

rm -f /tmp/demo_vault_key /tmp/demo_vault_key.pub
echo "Initial SSH key stored in Vault (version 1)"

# ── SNMP Community String ─────────────────────────────────────
echo ""
echo "--- Storing initial SNMP community string ---"
vault kv put secret/ansible/snmp \
  community_string="corp-monitor-init"
echo "SNMP community string stored in Vault"

# ── SSH OTP Role ──────────────────────────────────────────────
echo ""
echo "--- Configuring SSH OTP role ---"
vault write ssh/roles/otp-rhel \
  key_type=otp \
  default_user=ansible \
  cidr_list="0.0.0.0/0"
echo "SSH OTP role 'otp-rhel' created"

# ── OS Secrets Engine — RHEL host + accounts ──────────────────
echo ""
echo "--- Ensuring breakglass-rhel user exists on RHEL host ---"
ssh -i "$RHEL_KEY" -o StrictHostKeyChecking=no "$RHEL_USER@$RHEL_IP" '
  id breakglass-rhel >/dev/null 2>&1 || sudo useradd -m breakglass-rhel
  echo "Breakglass123!" | sudo passwd --stdin breakglass-rhel 2>/dev/null || \
    echo "Breakglass123!" | sudo chpasswd 2>/dev/null || true
  sudo passwd -u breakglass-rhel 2>/dev/null || true
'
echo "breakglass-rhel user ready on RHEL"

echo ""
echo "--- Configuring OS secrets engine ---"
vault write os/config ssh_host_key_trust_on_first_use=true
vault write os/hosts/rhel-target \
  address=$RHEL_IP \
  port=22 \
  rotation_period=720h
vault delete os/hosts/rhel-target/accounts/breakglass-rhel 2>/dev/null || true
vault delete os/hosts/rhel-target/accounts/ansible 2>/dev/null || true
vault write os/hosts/rhel-target/accounts/ansible \
  username=ansible \
  password="password"
vault write os/hosts/rhel-target/accounts/breakglass-rhel \
  username=breakglass-rhel \
  password="Breakglass123!" \
  parent_account_ref=ansible \
  rotation_period=720h
echo "OS engine configured — rhel-target registered with breakglass-rhel account"


# ── Control Groups — Identity Setup ──────────────────────────
echo ""
echo "--- Enabling userpass auth for demo identities ---"
vault auth enable userpass 2>/dev/null || echo "(userpass already enabled)"

echo ""
echo "--- Creating break-glass policies ---"
vault policy write breakglass-requestor - <<'EOF'
# Requestor: reading this path triggers Control Group — returns wrapping token, not credential
path "os/hosts/rhel-target/accounts/breakglass-rhel/creds" {
  capabilities = ["read"]
  control_group = {
    ttl = "1h"
    factor "security-approval" {
      identity {
        group_names = ["security-team"]
        approvals   = 1
      }
    }
  }
}
EOF
echo "Policy 'breakglass-requestor' created"

vault policy write security-approver - <<'EOF'
# Approver: can authorize control-group requests and check status
path "sys/control-group/authorize" {
  capabilities = ["create", "update"]
}
path "sys/control-group/request" {
  capabilities = ["create", "update"]
}
EOF
echo "Policy 'security-approver' created"

echo ""
echo "--- Creating demo userpass accounts ---"
vault write auth/userpass/users/operator \
  password="operator123" \
  token_policies="breakglass-requestor"
echo "User 'operator' created (password: operator123)"

vault write auth/userpass/users/sec-approver \
  password="approver123" \
  token_policies="security-approver"
echo "User 'sec-approver' created (password: approver123)"

# pr-admin: used by demo/reset scripts to obtain a native vault-pr root token
# (PR secondary tokens are cluster-specific — primary tokens do not validate on secondaries)
vault policy write pr-admin - <<'EOF'
path "sys/generate-root/*" { capabilities = ["create","update","read","delete","sudo"] }
path "sys/replication/*"   { capabilities = ["create","update","read","delete","sudo"] }
path "local-secret/*"                    { capabilities = ["create","read","update","delete","list"] }
path "sys/mounts/*"                      { capabilities = ["create","update","sudo"] }
path "sys/internal/ui/mounts/local-secret/*" { capabilities = ["read"] }
EOF
vault write auth/userpass/users/pr-admin \
  password="pradmin123" \
  token_policies="pr-admin"
echo "User 'pr-admin' created (for PR secondary root-token bootstrap)"

echo ""
echo "--- Wiring identity entities and security-team group ---"
USERPASS_ACCESSOR=$(vault auth list -format=json 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print((d.get('userpass/') or {}).get('accessor',''))")

# Create entities (idempotent — on update vault returns data:null, so fall back to read-by-name)
vault write identity/entity name="operator" policies="breakglass-requestor" >/dev/null 2>&1 || true
OPERATOR_ID=$(vault read -format=json identity/entity/name/operator | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])")

vault write identity/entity name="sec-approver" policies="security-approver" >/dev/null 2>&1 || true
APPROVER_ID=$(vault read -format=json identity/entity/name/sec-approver | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])")

# Link userpass login names to entities
vault write identity/entity-alias \
  name="operator" \
  canonical_id="$OPERATOR_ID" \
  mount_accessor="$USERPASS_ACCESSOR" 2>/dev/null || \
  echo "(operator alias already exists)"

vault write identity/entity-alias \
  name="sec-approver" \
  canonical_id="$APPROVER_ID" \
  mount_accessor="$USERPASS_ACCESSOR" 2>/dev/null || \
  echo "(sec-approver alias already exists)"

# Create security-team group — approver entity is a member
vault write identity/group \
  name="security-team" \
  member_entity_ids="$APPROVER_ID"
echo "Group 'security-team' created with 'sec-approver' as member"

# ── Local KV mount on vault-pr ────────────────────────────────
echo ""
echo "--- Enabling local KV mount on vault-pr ---"
_pr_admin_token=$(VAULT_ADDR=$PR_ADDR vault login \
  -method=userpass -format=json username=pr-admin password=pradmin123 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")
VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_pr_admin_token \
  vault secrets enable -local -path=local-secret kv-v2 2>/dev/null || \
  echo "(local-secret already enabled)"
VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_pr_admin_token \
  vault write local-secret/data/demo message="PR-local data — not replicated"
echo "Local KV mount 'local-secret' ready on vault-pr"

echo ""
echo "=== Setup complete — run ./demo.sh to start the demo ==="
