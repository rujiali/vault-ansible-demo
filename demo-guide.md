# Vault Enterprise Operational Security — Demo Guide

## Environment Assumptions

| Component | Value |
|---|---|
| Primary Vault | `https://vault-primary:8200` |
| DR Cluster | `https://vault-dr:8200` |
| PR Cluster A | `https://vault-pr-a:8200` |
| RHEL host 1 | `rhel-target` (192.168.234.133) |
| RHEL host | `rhel-target` (192.168.234.133) |
| Windows host 1 | `win-node-01` (192.168.1.20) |
| Windows host 2 | `win-node-02` (192.168.1.21) |
| Network device | `core-sw-01` (192.168.1.254) |
| Vault token | `$VAULT_TOKEN` (root for demo, AppRole in prod) |

```bash
export VAULT_ADDR="https://vault-primary:8200"
export VAULT_TOKEN="<root_token>"
```

---

## Section 1 — Ansible-Based Automation

### 1.1 Prerequisites

> **Production vs Lab**
> The client runs **Ansible Automation Platform (AAP) on-prem**. AAP integrates with Vault via the [HashiCorp Vault Credential Plugin](https://docs.ansible.com/automation-controller/latest/html/userguide/credential_plugins.html) — AAP fetches credentials from Vault at job runtime and injects them into playbooks automatically. Playbooks do not call Vault directly in production.
>
> This lab uses **CLI Ansible** on your Mac to demonstrate the same logic. The playbooks are identical; AAP just wraps them with scheduling, RBAC, and audit logging at the platform level.

**Lab: Install Ansible and collection (Mac)**
```bash
brew install ansible
pip3 install hvac
ansible-galaxy collection install community.hashi_vault community.windows
```

**Configure AppRole auth for Ansible**
```bash
# Enable AppRole
vault auth enable approle

# Create policy for Ansible
vault policy write ansible-policy - <<EOF
# SSH signing
path "ssh/sign/batch-role" {
  capabilities = ["create", "update"]
}

# OS secrets engine — read creds and rotate
path "os/hosts/+/accounts/+/creds" {
  capabilities = ["read"]
}
path "os/hosts/+/accounts/+/rotate" {
  capabilities = ["create", "update"]
}

# KV — SNMP and Windows break-glass
path "kv/data/network/snmp/*" {
  capabilities = ["read", "create", "update"]
}
path "kv/data/breakglass/windows/*" {
  capabilities = ["read", "create", "update"]
}
path "kv/metadata/network/snmp/*" {
  capabilities = ["read", "list"]
}
EOF

# Create AppRole
vault write auth/approle/role/ansible-role \
  token_policies="ansible-policy" \
  token_ttl="1h" \
  token_max_ttl="4h"

# Get Role ID and Secret ID
vault read auth/approle/role/ansible-role/role-id
vault write -f auth/approle/role/ansible-role/secret-id
```

**Ansible vault_addr configuration (`ansible.cfg`)**
```ini
[defaults]
vault_addr = https://vault-primary:8200
```

---

### 1.2 SSH Key Rotation (Vault KV — Key Pair Rotation)

> The client uses SSH public/private key pairs, not CA-signed certificates. Vault KV v2 is the source of truth for private keys. Ansible generates new key pairs, deploys the public key to the target host, and writes the private key to Vault only after confirming the new key works.

#### Setup Vault KV for SSH Keys

```bash
# Enable KV v2 (if not already enabled)
vault secrets enable -path=kv kv-v2

# Seed initial SSH key pair for each host
# Generate an initial key pair for bootstrapping
ssh-keygen -t ed25519 -f /tmp/initial_key -N ""

vault kv put kv/ssh/rhel-target \
  private_key="$(cat /tmp/initial_key)" \
  public_key="$(cat /tmp/initial_key.pub)" \
  rotated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Deploy initial public key to RHEL host (one-time bootstrap)
ssh-copy-id -i /tmp/initial_key.pub svc_ansible@<rhel-ip>

# Clean up local key files
rm -f /tmp/initial_key /tmp/initial_key.pub
```

#### Ansible Playbook — SSH Key Pair Rotation (Batch)

```yaml
# playbooks/rotate-ssh-keys.yml
---
- hosts: rhel_targets
  gather_facts: false
  vars:
    vault_addr: "{{ lookup('env', 'VAULT_ADDR') }}"
    role_id:    "{{ lookup('env', 'VAULT_ROLE_ID') }}"
    secret_id:  "{{ lookup('env', 'VAULT_SECRET_ID') }}"
    ssh_user:   "svc_ansible"

  tasks:
    - name: Authenticate to Vault via AppRole
      community.hashi_vault.vault_login:
        url:         "{{ vault_addr }}"
        auth_method: approle
        role_id:     "{{ role_id }}"
        secret_id:   "{{ secret_id }}"
      register: vault_login
      delegate_to: localhost
      run_once: true

    - name: Generate new ed25519 key pair
      community.crypto.openssh_keypair:
        path:  "/tmp/new_key_{{ inventory_hostname }}"
        type:  ed25519
        force: true
      delegate_to: localhost

    - name: Read new public key
      set_fact:
        new_pub_key: "{{ lookup('file', '/tmp/new_key_' + inventory_hostname + '.pub') }}"
      delegate_to: localhost

    - name: Add new public key to authorized_keys on host
      ansible.posix.authorized_key:
        user:  "{{ ssh_user }}"
        key:   "{{ new_pub_key }}"
        state: present

    - name: Verify new key works (test connection)
      ansible.builtin.command:
        cmd: >
          ssh -i /tmp/new_key_{{ inventory_hostname }}
          -o StrictHostKeyChecking=no
          -o BatchMode=yes
          {{ ssh_user }}@{{ ansible_host }} "echo ok"
      register: key_test
      delegate_to: localhost
      changed_when: false

    - name: Remove old public key from authorized_keys
      ansible.posix.authorized_key:
        user:          "{{ ssh_user }}"
        key:           "{{ lookup('community.hashi_vault.hashi_vault', 'kv2_get kv/ssh/' + inventory_hostname + ' token=' + vault_login.login.auth.client_token).secret.public_key }}"
        state:         absent
      when: key_test.stdout == "ok"

    - name: Write new private key to Vault KV (only after host confirms)
      community.hashi_vault.vault_kv2_write:
        url:                "{{ vault_addr }}"
        token:              "{{ vault_login.login.auth.client_token }}"
        engine_mount_point: kv
        path:               "ssh/{{ inventory_hostname }}"
        data:
          private_key: "{{ lookup('file', '/tmp/new_key_' + inventory_hostname) }}"
          public_key:  "{{ new_pub_key }}"
          rotated_at:  "{{ ansible_date_time.iso8601 }}"
      when: key_test.stdout == "ok"
      delegate_to: localhost

    - name: Clean up temporary key files
      ansible.builtin.file:
        path:  "{{ item }}"
        state: absent
      loop:
        - "/tmp/new_key_{{ inventory_hostname }}"
        - "/tmp/new_key_{{ inventory_hostname }}.pub"
      delegate_to: localhost
```

#### Demo Flow — SSH Key Rotation

```bash
# Show current key version in Vault before rotation
vault kv get kv/ssh/rhel-target
# Note: version = N, rotated_at = <old timestamp>

# Run the playbook across all RHEL targets
ansible-playbook playbooks/rotate-ssh-keys.yml -i inventory/hosts.yml

# Verify new key version in Vault
vault kv get kv/ssh/rhel-target
# version = N+1, rotated_at = <now>

# View full rotation history
vault kv metadata get kv/ssh/rhel-target

# Verify old key no longer works
OLD_KEY=$(vault kv get -version=N -field=private_key kv/ssh/rhel-target)
echo "$OLD_KEY" > /tmp/old_key && chmod 600 /tmp/old_key
ssh -i /tmp/old_key svc_ansible@<rhel-ip>  # should fail
rm /tmp/old_key
```

---

### 1.3 SNMP Credential Rotation

#### Setup Vault KV for SNMP

```bash
# Enable KV v2
vault secrets enable -path=kv kv-v2

# Seed initial SNMP credentials
vault kv put kv/network/snmp/core-sw-01 \
  community="initial-community-string" \
  snmpv3_user="vaultadmin" \
  snmpv3_auth_pass="InitialAuth123!" \
  snmpv3_priv_pass="InitialPriv123!" \
  last_rotated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

#### Ansible Playbook — SNMP Credential Rotation

```yaml
# playbooks/snmp-rotation.yml
---
- hosts: localhost
  vars:
    vault_addr: "{{ lookup('env', 'VAULT_ADDR') }}"
    snmp_devices:
      - core-sw-01
      - dist-sw-01
      - access-sw-01

  tasks:
    - name: Authenticate to Vault
      community.hashi_vault.vault_login:
        url: "{{ vault_addr }}"
        auth_method: approle
        role_id:   "{{ lookup('env', 'VAULT_ROLE_ID') }}"
        secret_id: "{{ lookup('env', 'VAULT_SECRET_ID') }}"
      register: vault_login

    - name: Rotate SNMP credentials for each device
      loop: "{{ snmp_devices }}"
      include_tasks: tasks/rotate-snmp.yml
      loop_control:
        loop_var: device
```

```yaml
# tasks/rotate-snmp.yml
- name: Read current credential from Vault
  community.hashi_vault.vault_kv2_get:
    url:   "{{ vault_addr }}"
    token: "{{ vault_login.login.auth.client_token }}"
    engine_mount_point: kv
    path:  "network/snmp/{{ device }}"
  register: current_cred

- name: Generate new SNMP community string
  set_fact:
    new_community: "{{ lookup('password', '/dev/null length=24 chars=ascii_letters,digits') }}"
    new_auth_pass:  "{{ lookup('password', '/dev/null length=20 chars=ascii_letters,digits') }}"
    new_priv_pass:  "{{ lookup('password', '/dev/null length=20 chars=ascii_letters,digits') }}"

- name: Push new credential to network device
  # Replace with your network device management module
  # e.g. cisco.ios.ios_config, arista.eos.eos_config
  community.network.net_put:
    src: "snmp-config.j2"
  vars:
    snmp_community: "{{ new_community }}"
  register: device_update

- name: Write new credential to Vault KV (only after device confirms)
  community.hashi_vault.vault_kv2_write:
    url:   "{{ vault_addr }}"
    token: "{{ vault_login.login.auth.client_token }}"
    engine_mount_point: kv
    path:  "network/snmp/{{ device }}"
    data:
      community:       "{{ new_community }}"
      snmpv3_auth_pass: "{{ new_auth_pass }}"
      snmpv3_priv_pass: "{{ new_priv_pass }}"
      last_rotated:    "{{ ansible_date_time.iso8601 }}"
  when: device_update is succeeded
```

#### Verify Version History

```bash
# Read current version
vault kv get kv/network/snmp/core-sw-01

# View all versions
vault kv metadata get kv/network/snmp/core-sw-01

# Read a previous version
vault kv get -version=1 kv/network/snmp/core-sw-01
```

---

### 1.4 Break-Glass Credential Rotation — RHEL (OS Secrets Engine)

#### Setup OS Secrets Engine

```bash
# Download and register plugin (linux arm64 — adjust for your arch)
mkdir -p /path/to/plugins
curl -sO https://releases.hashicorp.com/vault-plugin-secrets-os/0.1.0+ent/vault-plugin-secrets-os_0.1.0+ent_linux_arm64.zip
unzip vault-plugin-secrets-os_0.1.0+ent_linux_arm64.zip -d /path/to/plugins
chmod +x /path/to/plugins/vault-plugin-secrets-os

SHA256=$(sha256sum /path/to/plugins/vault-plugin-secrets-os | cut -d' ' -f1)
vault plugin register -sha256=$SHA256 -command=vault-plugin-secrets-os secret os
vault secrets enable -path=os vault-plugin-secrets-os

# Register RHEL host (Vault connects via SSH using management account)
SSH_HOST_KEY=$(ssh-keyscan -t ed25519 192.168.234.133 2>/dev/null | awk '{print $2" "$3}')
vault write os/hosts/rhel-target \
  address=192.168.234.133 \
  username=ansible \
  private_key=@~/.ssh/lab_key \
  ssh_host_key="$SSH_HOST_KEY"

# Register break-glass account with 30-day rotation
vault write os/hosts/rhel-target/accounts/breakglass-rhel \
  username=breakglass-rhel \
  password="InitialBreakglass123!" \
  rotation_period=2592000
```

#### Ansible Playbook — Trigger Ad-Hoc Rotation

```yaml
# playbooks/rotate-breakglass-rhel.yml
---
- hosts: localhost
  vars:
    rhel_hosts:
      - rhel-target

  tasks:
    - name: Authenticate to Vault
      community.hashi_vault.vault_login:
        url: "{{ lookup('env', 'VAULT_ADDR') }}"
        auth_method: approle
        role_id:   "{{ lookup('env', 'VAULT_ROLE_ID') }}"
        secret_id: "{{ lookup('env', 'VAULT_SECRET_ID') }}"
      register: vault_login

    - name: Trigger break-glass rotation on each RHEL host
      community.hashi_vault.vault_write:
        url:   "{{ lookup('env', 'VAULT_ADDR') }}"
        token: "{{ vault_login.login.auth.client_token }}"
        path:  "os/hosts/{{ item }}/accounts/breakglass-rhel/rotate"
      loop: "{{ rhel_hosts }}"

    - name: Read new credentials
      community.hashi_vault.vault_read:
        url:   "{{ lookup('env', 'VAULT_ADDR') }}"
        token: "{{ vault_login.login.auth.client_token }}"
        path:  "os/hosts/{{ item }}/accounts/breakglass-rhel/creds"
      loop: "{{ rhel_hosts }}"
      register: new_creds

    - name: Show rotation result (demo only — do not log in prod)
      debug:
        msg: "{{ item.item }}: rotation complete — new credential stored in Vault"
      loop: "{{ new_creds.results }}"
```

#### Demo Commands — RHEL Break-Glass Rotation

```bash
# Show current credential
vault read os/hosts/rhel-target/accounts/breakglass-rhel/creds

# Trigger rotation manually
vault write -f os/hosts/rhel-target/accounts/breakglass-rhel/rotate

# Read new credential
vault read os/hosts/rhel-target/accounts/breakglass-rhel/creds

# Show version history
vault read os/hosts/rhel-target/accounts/breakglass-rhel/versions

# Verify old password no longer works
ssh breakglass-rhel@192.168.234.133  # old password — should fail

# Verify new password works
# (use credential from vault read above)
```

---

### 1.5 Break-Glass Credential Rotation — Windows (AD Secrets Engine)

> The client uses AD-managed accounts on Windows. Vault's **Active Directory (AD) Secrets Engine** manages these natively via LDAP — no Ansible or WinRM required for rotation. The **library checkout** pattern is used for break-glass: accounts are checked out for a session and auto-rotated on check-in.

#### Setup AD Secrets Engine

```bash
# Enable AD secrets engine
vault secrets enable ad

# Configure AD connection
vault write ad/config \
  binddn="CN=vault-svc,OU=ServiceAccounts,DC=corp,DC=example,DC=com" \
  bindpass="VaultServicePassword!" \
  url="ldaps://dc01.corp.example.com" \
  userdn="OU=BreakGlass,DC=corp,DC=example,DC=com" \
  insecure_tls=false \
  certificate=@/etc/vault.d/ad-ca.pem

# Create a library set for break-glass accounts
# Library sets group accounts available for checkout
vault write openldap/library/breakglass-windows \
  service_account_names="breakglass-win01@corp.example.com,breakglass-win02@corp.example.com" \
  ttl=8h \
  max_ttl=24h \
  disable_check_in_enforcement=false
```

#### Demo Commands — Windows Break-Glass Checkout Flow

```bash
# Show library status — all accounts available
vault read openldap/library/breakglass-windows/status

# Check out a break-glass account (requestor gets credential)
vault write -f openldap/library/breakglass-windows/check-out
# Returns: service_account_name, password, lease_id

# Show library status — account now checked out
vault read openldap/library/breakglass-windows/status

# Use credential for RDP/break-glass access
# (connect to Windows host using returned AD credentials)

# Check in after use — triggers immediate password rotation
vault write -f openldap/library/breakglass-windows/check-in \
  service_account_names="breakglass-win01@corp.example.com"

# Vault rotates the AD password immediately via LDAP
# Old password invalidated — account available for next checkout
vault read openldap/library/breakglass-windows/status
```

#### Scheduled Rotation (Outside Break-Glass)

```bash
# Vault also rotates AD account passwords on a schedule
# regardless of checkout activity
vault write ad/roles/breakglass-win01 \
  service_account_name="breakglass-win01@corp.example.com" \
  ttl=24h

# Trigger manual rotation
vault rotate-root ad
```

---

## Section 2 — Break-Glass Access Workflow

### 2.1 Setup — Policies, Control Groups, Identity

```bash
# Create identity groups
vault write identity/group \
  name="security-team" \
  policies="security-team-policy"

vault write identity/group \
  name="break-glass-requestors" \
  policies="break-glass-requestor-policy"

# Policy: requestor (can request but not read directly)
vault policy write break-glass-requestor-policy - <<EOF
# RHEL break-glass — wrapped response only
path "os/hosts/+/accounts/breakglass-rhel/creds" {
  capabilities = ["read"]
  control_group = {
    ttl = "1h"
    factor "dual-approval" {
      identity {
        group_names = ["security-team"]
        approvals   = 2
      }
    }
  }
}

# Windows break-glass — AD library checkout (dual approval via control group)
path "openldap/library/breakglass-windows/check-out" {
  capabilities = ["create", "update"]
  control_group = {
    ttl = "1h"
    factor "dual-approval" {
      identity {
        group_names = ["security-team"]
        approvals   = 2
      }
    }
  }
}

# Allow unwrapping
path "sys/wrapping/unwrap" {
  capabilities = ["update"]
}
EOF

# Policy: approver (security team)
vault policy write security-team-policy - <<EOF
path "sys/control-group/authorize" {
  capabilities = ["create", "update"]
}
path "sys/control-group/request" {
  capabilities = ["create", "update"]
}
EOF
```

### 2.2 Demo Flow — Full Break-Glass Workflow

```bash
# ── Step 1: Requestor attempts to read break-glass credential ──
# Login as requestor
vault login -method=userpass username=alice password=alice123
export REQUESTOR_TOKEN=$(vault print token)

# Attempt to read credential — Vault returns a wrapping token, not the credential
WRAP_TOKEN=$(vault read -wrap-ttl=1h \
  os/hosts/rhel-target/accounts/breakglass-rhel/creds \
  -format=json | jq -r '.wrap_info.token')

echo "Wrapping token: $WRAP_TOKEN"
# Note: alice cannot unwrap this yet — approval required

# ── Step 2: Requestor sends wrapping token to approvers ──
# Out-of-band: email / Slack / ticket with $WRAP_TOKEN
# Approver needs the accessor to approve

ACCESSOR=$(vault token lookup -format=json $WRAP_TOKEN | jq -r '.data.accessor')
echo "Accessor for approvers: $ACCESSOR"

# ── Step 3: First approver authorises ──
vault login -method=userpass username=bob password=bob123
vault write sys/control-group/authorize accessor=$ACCESSOR

# ── Step 4: Second approver authorises ──
vault login -method=userpass username=carol password=carol123
vault write sys/control-group/authorize accessor=$ACCESSOR

# ── Step 5: Requestor checks approval status ──
export VAULT_TOKEN=$REQUESTOR_TOKEN
vault write sys/control-group/request accessor=$ACCESSOR
# approved = true once both approvers have authorised

# ── Step 6: Requestor unwraps — gets the credential ──
vault unwrap $WRAP_TOKEN

# ── Step 7: Credential is used for break-glass access ──
# SSH to RHEL host using retrieved credential

# ── Step 8: Rotate credential after use ──
# See Section 2.5 for full post-use rotation procedure (RHEL + Windows)
vault write -f os/hosts/rhel-target/accounts/breakglass-rhel/rotate
```

### 2.3 Show Audit Trail

```bash
# Enable audit log (if not already enabled)
vault audit enable file file_path=/var/log/vault/audit.log

# After the above workflow, inspect the audit log
tail -50 /var/log/vault/audit.log | jq 'select(.request.path | contains("control-group"))'

# What you will see:
# - alice's request with timestamp
# - bob's approval with identity
# - carol's approval with identity
# - alice's unwrap with timestamp
```

### 2.4 Vault Unavailable — Offline Break-Glass

```bash
# Demonstrate what happens when Vault is sealed
vault operator seal

# Attempt to request break-glass credential
vault read os/hosts/rhel-target/accounts/breakglass-rhel/creds
# Error: Vault is sealed

# ── Offline procedure ──
# 1. Incident commander declares Vault-unavailable event
# 2. Two custodians retrieve physical emergency credential envelope
# 3. Document access in incident register:
#    - Time of access
#    - Who accessed
#    - Which host
#    - Reason
# 4. Use static emergency credential for break-glass access

# ── After Vault restores ──
vault operator unseal  # provide unseal key(s)

# Immediately rotate the offline credential that was used
vault write -f os/hosts/rhel-target/accounts/breakglass-rhel/rotate

# Rotate Windows AD account via AD Secrets Engine
vault write -f openldap/library/breakglass-windows/check-in \
  service_account_names="breakglass-win01@corp.example.com"
```

### 2.5 Post-Use Credential Rotation

> **Policy:** The credential used during break-glass access must be rotated immediately after the session ends. This ensures the retrieved credential cannot be reused for unauthorised access and closes the audit trail cleanly.
>
> In production, an AAP job template is triggered by the requestor (or security team) at session close. In the lab, run the commands below manually.

#### RHEL — OS Secrets Engine (Vault-native rotation)

Vault rotates the password directly on the RHEL host. No Ansible required.

```bash
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN=$PRIMARY_TOKEN

# Verify current credential version before rotation
vault read os/hosts/rhel-target/accounts/breakglass-rhel/creds
# Note: current_version = N

# Trigger rotation — Vault connects to RHEL host and changes the password
vault write -f os/hosts/rhel-target/accounts/breakglass-rhel/rotate

# Verify new credential is issued (version incremented)
vault read os/hosts/rhel-target/accounts/breakglass-rhel/creds
# current_version = N+1

# Verify old password no longer works on the host
ssh breakglass-rhel@<rhel-ip>   # use OLD password — should fail with "Permission denied"
```

What this demonstrates:
- Vault owns the rotation — no human sets the new password
- Old credential is invalidated the moment rotation is called
- Version history in Vault shows exactly when rotation occurred

---

#### Windows — AD Secrets Engine (Vault-native)

Vault rotates the AD account password directly via LDAP on check-in. No AAP or WinRM required.

```bash
# Show library status — account currently checked out
vault read openldap/library/breakglass-windows/status
# breakglass-win01: checked_out=true, lease_id=<id>

# Check in after use — Vault rotates the AD password immediately
vault write -f openldap/library/breakglass-windows/check-in \
  service_account_names="breakglass-win01@corp.example.com"

# Verify library status — account available again
vault read openldap/library/breakglass-windows/status
# breakglass-win01: checked_out=false

# Verify old password no longer works
# (attempt RDP/login with old credential — should fail)
```
```

---

#### Demonstrating the Full Cycle (both hosts)

```bash
# Show: break-glass credential was used (audit log confirms access)
tail -20 /var/log/vault/audit.log | jq 'select(.request.path | contains("breakglass"))'

# Rotate RHEL
vault write -f os/hosts/rhel-target/accounts/breakglass-rhel/rotate

# Rotate Windows (Ansible)
ansible-playbook playbooks/rotate-breakglass-windows.yml -i inventory/hosts.yml

# Confirm both credentials are on new versions
vault read os/hosts/rhel-target/accounts/breakglass-rhel/creds
vault kv get kv/breakglass/windows/win-node-01

# Show: rotation events appear in audit log
tail -20 /var/log/vault/audit.log | jq 'select(.request.path | contains("rotate") or (.request.path | contains("breakglass")))'
```

**Key message for the audience:** The credential lifecycle is closed — access is requested, dual-approved, used, and immediately rotated. Every step is in the Vault audit log with identity and timestamp. No standing access, no reusable credentials.

---

## Section 3 — Disaster Recovery Operations

### 3.1 Pre-requisites — Enable DR Replication

```bash
# On Primary: enable DR replication
export VAULT_ADDR="https://vault-primary:8200"
vault write -f sys/replication/dr/primary/enable

# Generate secondary activation token
vault write sys/replication/dr/primary/secondary-token id="dr-cluster"
# Save the token — needed on the DR cluster

# On DR cluster: activate as secondary
export VAULT_ADDR="https://vault-dr:8200"
vault write sys/replication/dr/secondary/enable \
  token="<secondary_token_from_above>" \
  primary_api_addr="https://vault-primary:8200"

# Verify replication status
vault read sys/replication/dr/status
```

### 3.2 Demo — Activating DR & Promoting DR Cluster

```bash
# ── Simulate primary failure ──
# (In demo: seal or stop the primary Vault process)
export VAULT_ADDR="https://vault-primary:8200"
vault operator seal

# ── On DR cluster: generate DR operation token ──
export VAULT_ADDR="https://vault-dr:8200"

# If primary is accessible, generate via primary:
# vault operator generate-root -dr-token

# If primary is unreachable, use existing DR secondary token
# (stored securely during DR setup)

# ── Promote DR cluster to primary ──
vault operator raft promote-dr \
  -dr-operation-token="<dr_operation_token>"

# Verify DR cluster is now active primary
vault status
vault read sys/replication/dr/status
# replication_mode = "primary"

# ── Update DNS / load balancer ──
# Point vault.internal → vault-dr:8200
# This step is MANUAL — Vault does not update DNS
echo "Update DNS: vault.internal → $(dig +short vault-dr)"

# ── Verify the new primary is serving requests ──
export VAULT_ADDR="https://vault-dr:8200"
vault secrets list
vault kv get kv/breakglass/windows/win-node-01
```

### 3.3 Demo — Re-pointing PR Clusters to New Primary

```bash
# ── On PR Cluster A ──
export VAULT_ADDR="https://vault-pr-a:8200"

# Check current replication status
vault read sys/replication/performance/status
# primary_cluster_addr = vault-primary (old)

# Disable performance replication
vault write -f sys/replication/performance/secondary/disable

# ── On new primary (promoted DR cluster) ── 
export VAULT_ADDR="https://vault-dr:8200"

# Generate new secondary activation token for PR cluster A
vault write sys/replication/performance/primary/secondary-token \
  id="pr-cluster-a"
# Save: NEW_TOKEN

# ── Back on PR Cluster A ──
export VAULT_ADDR="https://vault-pr-a:8200"

# Re-enable replication against new primary
vault write sys/replication/performance/secondary/enable \
  token="<NEW_TOKEN>" \
  primary_api_addr="https://vault-dr:8200"

# Verify replication is active against new primary
vault read sys/replication/performance/status
# primary_cluster_addr = vault-dr (new primary)

# Test read on PR cluster
vault kv get kv/network/snmp/core-sw-01
```

---

## Section 4 — Local Clusters & Autonomous Operation

### 4.1 Setup — Performance Replication

```bash
# On Primary: enable PR replication
export VAULT_ADDR="https://vault-primary:8200"
vault write -f sys/replication/performance/primary/enable

# Create PR secondary token
vault write sys/replication/performance/primary/secondary-token \
  id="pr-cluster-a"
# Save: PR_TOKEN

# On PR Cluster A: activate
export VAULT_ADDR="https://vault-pr-a:8200"
vault write sys/replication/performance/secondary/enable \
  token="<PR_TOKEN>" \
  primary_api_addr="https://vault-primary:8200"

# Verify
vault read sys/replication/performance/status
```

### 4.2 Demo — Autonomous Operation During Disconnect

```bash
# ── Pre-disconnect: write a secret on primary ──
export VAULT_ADDR="https://vault-primary:8200"
vault kv put kv/test/autonomous-demo value="pre-disconnect-value"

# Verify it replicated to PR cluster
export VAULT_ADDR="https://vault-pr-a:8200"
vault kv get kv/test/autonomous-demo
# value = pre-disconnect-value ✓

# ── Simulate primary disconnect ──
# (Block network connectivity from PR cluster to primary)
# In demo: stop primary Vault or block firewall rule

# ── While disconnected: reads still work ──
export VAULT_ADDR="https://vault-pr-a:8200"
vault kv get kv/test/autonomous-demo
# value = pre-disconnect-value ✓ (served from local cache)

# ── While disconnected: writes fail ──
vault kv put kv/test/new-secret value="written-during-disconnect"
# Error: failed to forward request to active node
# Confirms: writes cannot proceed without primary

# ── Write happens on primary during disconnect ──
export VAULT_ADDR="https://vault-primary:8200"
vault kv put kv/test/autonomous-demo value="updated-during-disconnect"

# ── Restore connectivity ──
# (Restore network / restart primary)

# ── PR cluster automatically resyncs ──
export VAULT_ADDR="https://vault-pr-a:8200"
vault read sys/replication/performance/status
# connection_state = "ready"

# Read the updated secret — now reflects primary's value
vault kv get kv/test/autonomous-demo
# value = updated-during-disconnect ✓ (auto-synced, no manual intervention)
```

### 4.3 Demonstrate Propagation Model

```bash
# Show secrets are centrally managed — updates MUST go to primary
export VAULT_ADDR="https://vault-primary:8200"

# Update break-glass credential on primary
vault kv put kv/breakglass/windows/win-node-01 \
  username="Administrator" \
  password="NewCentralPassword123!" \
  last_rotated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Within seconds, change is visible on PR cluster
export VAULT_ADDR="https://vault-pr-a:8200"
vault kv get kv/breakglass/windows/win-node-01
# password = NewCentralPassword123! ✓

# Demonstrate: attempting to write on PR cluster forwards to primary
# (write goes to primary transparently if connected)
vault kv put kv/test/pr-write-test value="written-on-pr"
# Succeeds — but it was forwarded to primary and replicated back

# Confirm the write landed on primary
export VAULT_ADDR="https://vault-primary:8200"
vault kv get kv/test/pr-write-test
# value = written-on-pr ✓
```

---

## Section 5 — Operational Best Practices

### 5.1 Auto-Unseal (HSM / Transit Seal)

```bash
# vault.hcl configuration for Transit Seal (software HSM)
cat > /etc/vault.d/vault.hcl <<EOF
ui            = true
disable_mlock = false

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-primary-01"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/etc/vault.d/tls/vault.crt"
  tls_key_file  = "/etc/vault.d/tls/vault.key"
}

# Transit Seal (software HSM — for demo)
seal "transit" {
  address         = "https://vault-hsm:8200"
  token           = "<hsm_token>"
  disable_renewal = "false"
  key_name        = "vault-seal-key"
  mount_path      = "transit/"
}
EOF

# Start Vault
systemctl start vault

# On restart, Vault auto-unseals by calling vault-hsm
# No human intervention required
vault status
# Sealed = false (auto-unsealed)
```

### 5.2 Manual Unseal (Fallback — Shamir Key Shares)

```bash
# Show current seal status
vault status

# Unseal with key shares (requires quorum — e.g. 3 of 5)
vault operator unseal <unseal_key_1>
vault operator unseal <unseal_key_2>
vault operator unseal <unseal_key_3>

# Verify unsealed
vault status
# Sealed = false

# Check health endpoint (useful for monitoring)
curl -s https://vault-primary:8200/v1/sys/health | jq '{
  sealed: .sealed,
  standby: .standby,
  version: .version,
  cluster_name: .cluster_name
}'
```

### 5.3 Backup — Raft Snapshot

```bash
# Take a manual snapshot
vault operator raft snapshot save \
  /var/backups/vault/vault-snapshot-$(date +%Y%m%d-%H%M%S).gz

# Verify snapshot integrity
vault operator raft snapshot inspect \
  /var/backups/vault/vault-snapshot-20260417-120000.gz

# Automated backup via cron (add to /etc/cron.d/vault-backup)
cat > /etc/cron.d/vault-backup <<EOF
0 2 * * * vault /usr/bin/vault operator raft snapshot save \
  /var/backups/vault/vault-snapshot-\$(date +\%Y\%m\%d-\%H\%M\%S).gz \
  && find /var/backups/vault -name "*.gz" -mtime +30 -delete
EOF

# Upload snapshot to secure storage (example: S3-compatible)
aws s3 cp \
  /var/backups/vault/vault-snapshot-20260417-120000.gz \
  s3://vault-backups-secure/snapshots/ \
  --sse aws:kms
```

### 5.4 Restore from Snapshot

```bash
# ── Scenario: Vault data corrupted or accidental deletion ──

# Step 1: Ensure Vault is initialised but running
vault status

# Step 2: Restore from snapshot
vault operator raft snapshot restore \
  /var/backups/vault/vault-snapshot-20260417-120000.gz

# Note: This restores ALL data to the state at snapshot time
# Any changes after the snapshot are lost

# Step 3: Verify data restored
vault kv list kv/
vault kv get kv/breakglass/windows/win-node-01
vault secrets list

# Step 4: Verify replication is still active after restore
vault read sys/replication/performance/status
vault read sys/replication/dr/status

# Step 5: If replication shows issues after restore,
# re-establish secondary connections (see Section 3.3)
```

### 5.5 Health Check & Monitoring

```bash
# Vault health endpoint (no auth required)
curl -s $VAULT_ADDR/v1/sys/health | jq

# Response codes:
# 200 = initialised, unsealed, active
# 429 = unsealed, standby
# 472 = DR replication secondary — not an error
# 473 = performance standby — not an error
# 501 = not initialised
# 503 = sealed

# Key metrics to monitor
vault operator metrics | grep -E "vault\.(core|replication|secret)"

# Check replication lag
vault read sys/replication/performance/status | grep -E "known_secondaries|connection_state|last_wal"
vault read sys/replication/dr/status | grep -E "known_secondaries|connection_state"
```

---

## Quick Reference

### Key API Endpoints

| Operation | Method | Path |
|---|---|---|
| SSH sign certificate | POST | `/v1/ssh/sign/<role>` |
| OS secrets rotate | POST | `/v1/os/hosts/<h>/accounts/<a>/rotate` |
| OS secrets read creds | GET | `/v1/os/hosts/<h>/accounts/<a>/creds` |
| KV v2 read | GET | `/v1/kv/data/<path>` |
| KV v2 write | POST | `/v1/kv/data/<path>` |
| KV v2 version history | GET | `/v1/kv/metadata/<path>` |
| Control group authorize | POST | `/v1/sys/control-group/authorize` |
| Control group status | POST | `/v1/sys/control-group/request` |
| Unwrap token | POST | `/v1/sys/wrapping/unwrap` |
| DR promote | POST | `/v1/sys/replication/dr/secondary/promote` |
| PR enable secondary | POST | `/v1/sys/replication/performance/secondary/enable` |
| Raft snapshot save | GET | `/v1/sys/storage/raft/snapshot` |
| Health check | GET | `/v1/sys/health` |

### Ansible Modules (community.hashi_vault)

| Module | Use |
|---|---|
| `vault_login` | Authenticate (AppRole, LDAP, etc.) |
| `vault_read` | Read any Vault path |
| `vault_write` | Write to any Vault path |
| `vault_kv2_get` | Read KV v2 secret |
| `vault_kv2_write` | Write KV v2 secret |
| `vault_kv2_delete` | Delete KV v2 secret |
