#!/usr/bin/env bash
# ============================================================
# Vault Enterprise Demo — Sections 1 & 2
# Run from: lab/   (cd vault-ansible-demo/lab && ./demo.sh)
# Prerequisites: bootstrap.sh, ldap-setup.sh, vault-setup.sh
# ============================================================
cd "$(dirname "$0")"

# ── Colours ──────────────────────────────────────────────────
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; MAG='\033[0;35m'; WHT='\033[1;37m'

# ── Helpers ───────────────────────────────────────────────────
press() {
  echo ""
  printf "${YLW}  ▶  Press any key to continue...${NC}"
  read -rsn1
  echo ""
  echo ""
}

banner() {
  local pad="══════════════════════════════════════════════════════════"
  echo ""
  printf "${BLU}%s${NC}\n" "$pad"
  printf "${BOLD}${WHT}  %s${NC}\n" "$1"
  printf "${BLU}%s${NC}\n" "$pad"
  echo ""
}

section() {
  echo ""
  printf "${MAG}  ┌─────────────────────────────────────────────────────┐${NC}\n"
  printf "${MAG}  │${NC}  ${BOLD}%-51s${NC}${MAG}│${NC}\n" "$1"
  printf "${MAG}  └─────────────────────────────────────────────────────┘${NC}\n"
  echo ""
}

step()  { printf "${CYN}  ▷  %s${NC}\n" "$1"; }
note()  { printf "${DIM}     ℹ  %s${NC}\n" "$1"; echo ""; }
label() { printf "${WHT}     %-20s${NC}%s\n" "$1" "$2"; }

cmd() {
  echo ""
  printf "${GRN}  \$ %s${NC}\n" "$1"
  echo ""
  eval "$1"
  echo ""
}

# ── Load credentials ─────────────────────────────────────────
source .vault-creds
export VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN
RHEL_IP="192.168.234.133"
ANSIBLE_INV="../ansible/inventory/hosts.yml"
ANSIBLE_PB="../ansible/playbooks"

# ── Preflight check ───────────────────────────────────────────
if ! vault kv get secret/ansible/ssh-key &>/dev/null; then
  printf "${RED}ERROR: Run vault-setup.sh first.${NC}\n"
  exit 1
fi

# =============================================================
# INTRO
# =============================================================
clear
banner "Vault Enterprise 2.0 — Operational Security Demo"

printf "  ${BOLD}Lab topology:${NC}\n\n"
printf "  ${WHT}Mac (Ansible + Vault CLI)${NC}\n"
printf "     │\n"
printf "     ├── ${CYN}Vault Primary  :8200${NC}  (Enterprise 2.0)\n"
printf "     │       ├── KV v2        SSH keys + SNMP  (AAP-orchestrated rotation)\n"
printf "     │       ├── OS engine    RHEL local account password rotation\n"
printf "     │       ├── LDAP         Windows break-glass + password rotation\n"
printf "     │       └── AppRole auth (simulating AAP + OIDC)\n"
printf "     │\n"
printf "     ├── ${GRN}RHEL 10 VM     :22${NC}   (%s)\n" "$RHEL_IP"
printf "     └── ${BLU}OpenLDAP       :389${NC}  (simulates Windows AD)\n"
echo ""
printf "  ${BOLD}Two rotation models:${NC}\n"
printf "  ${YLW}  AAP-orchestrated:${NC}  SSH key pairs, SNMP strings  (Vault = store)\n"
printf "  ${GRN}  Vault-native:${NC}      RHEL local accounts (OS Engine), Windows AD (LDAP Engine)\n"
echo ""
note "Production: AAP authenticates via OIDC + Vault Credential Plugin"
note "This lab:   AppRole authentication — same Vault API surface"

press

# =============================================================
# SECTION 1 — ANSIBLE-BASED AUTOMATION
# =============================================================
clear
banner "SECTION 1 — Ansible-Based Automation"

printf "  ${BOLD}Two rotation models on this slide (deck slide ④):${NC}\n\n"
printf "  ${YLW}  AAP-Orchestrated${NC}  — Ansible generates/rotates, Vault is the store\n"
printf "             SSH key pairs  →  Vault KV v2\n"
printf "             SNMP strings   →  Vault KV v2\n"
echo ""
printf "  ${GRN}  Vault-Native${NC}      — Vault connects directly to target, no AAP needed\n"
printf "             RHEL local accounts  →  OS Secrets Engine (SSH)\n"
printf "             Windows AD accounts  →  AD Secrets Engine (LDAP)\n"
echo ""

press

# ── 1.1 AppRole Authentication ────────────────────────────────
section "1.1  AppRole Authentication  (AAP → Vault)"

printf "  ${YLW}  Production:${NC}  AAP authenticates to Vault via ${BOLD}OIDC${NC}\n"
printf "             No secrets stored in AAP — token issued at job launch, discarded on completion.\n"
printf "  ${DIM}  This lab:${NC}   AppRole — same Vault policy and API surface, different auth method.\n"
echo ""

press

step "Ansible policy — scoped to only what Ansible needs:"
cmd "vault policy read ansible-rotation"

press

step "AppRole role-id — the stable identity of the Ansible 'application':"
cmd "vault read auth/approle/role/ansible/role-id"

press

step "Simulating AppRole login (what AAP does at job launch time):"
ROLE_ID=$(vault read -field=role_id auth/approle/role/ansible/role-id)
SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/ansible/secret-id)
cmd "vault write auth/approle/login role_id=$ROLE_ID secret_id=$SECRET_ID"
note "AAP discards this token after the playbook completes — zero long-lived credentials"

press

# ── 1.2 SSH Key Pair Rotation ─────────────────────────────────
clear
section "1.2  SSH Key Pair Rotation  (KV v2 + Ansible)"

step "Current SSH key version in Vault (last 5 versions):"
echo ""
printf "${GRN}  \$ vault kv metadata get secret/ansible/ssh-key${NC}\n\n"
vault kv metadata get -format=json secret/ansible/ssh-key | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
print(f'current_version    {d[\"current_version\"]}')
print(f'oldest_version     {d[\"oldest_version\"]}')
print(f'created_time       {d[\"created_time\"]}')
print(f'updated_time       {d[\"updated_time\"]}')
print()
print('version    created_time                         deletion_time    destroyed')
print('-------    ------------                         -------------    ---------')
versions = d.get('versions', {})
recent = sorted(versions.keys(), key=int)[-5:]
for v in recent:
    info = versions[v]
    print(f'{v:<10} {info[\"created_time\"]:<40} {info[\"deletion_time\"] or \"n/a\":<16} {info[\"destroyed\"]}')
"
echo ""

press

step "Running Ansible — generates new ed25519 pair, deploys pubkey to RHEL, stores privkey in Vault:"
cmd "ansible-playbook -i $ANSIBLE_INV $ANSIBLE_PB/ssh-key-rotation.yml"

press

step "New version stored — private key never touched the filesystem:"
echo ""
printf "${GRN}  \$ vault kv metadata get secret/ansible/ssh-key${NC}\n\n"
vault kv metadata get -format=json secret/ansible/ssh-key | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
print(f'current_version    {d[\"current_version\"]}')
print(f'oldest_version     {d[\"oldest_version\"]}')
print(f'created_time       {d[\"created_time\"]}')
print(f'updated_time       {d[\"updated_time\"]}')
print()
print('version    created_time                         deletion_time    destroyed')
print('-------    ------------                         -------------    ---------')
versions = d.get('versions', {})
recent = sorted(versions.keys(), key=int)[-5:]
for v in recent:
    info = versions[v]
    print(f'{v:<10} {info[\"created_time\"]:<40} {info[\"deletion_time\"] or \"n/a\":<16} {info[\"destroyed\"]}')
"
echo ""

press

step "Previous version still retrievable — full audit trail:"
CURRENT_VER=$(vault kv metadata get -format=json secret/ansible/ssh-key | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['current_version'])")
PREV_VER=$((CURRENT_VER - 1))
cmd "vault kv get -version=$PREV_VER secret/ansible/ssh-key"

press

# ── 1.3 SNMP Community String Rotation ───────────────────────
clear
section "1.3  SNMP Community String Rotation  (KV v2 + Ansible)"

step "Current SNMP community string in Vault:"
cmd "vault kv get secret/ansible/snmp"

press

step "Running Ansible — generates new string, deploys config to RHEL, stores in Vault:"
cmd "ansible-playbook -i $ANSIBLE_INV $ANSIBLE_PB/snmp-rotation.yml"

press

step "New community string stored in Vault:"
cmd "vault kv get secret/ansible/snmp"

press

step "Same string deployed to RHEL config file — Vault and target are in sync:"
cmd "ssh -i ~/.ssh/lab_key ansible@$RHEL_IP 'cat ~/snmpd.conf'"

press

# ── 1.4 RHEL Break-Glass Rotation  (OS Secrets Engine) ────────
clear
section "1.4  RHEL Break-Glass Rotation  (OS Secrets Engine)"

printf "  ${DIM}  Vault-native — Vault SSHs into RHEL as the management account and rotates${NC}\n"
printf "  ${DIM}  the break-glass password directly. No AAP playbook required.${NC}\n"
echo ""

step "Account registered in Vault — 30-day automated rotation schedule:"
cmd "vault read os/hosts/rhel-target/accounts/breakglass-rhel"

press

step "Current password stored in Vault:"
OLD_PASS=$(vault read -field=password os/hosts/rhel-target/accounts/breakglass-rhel/creds)
cmd "vault read os/hosts/rhel-target/accounts/breakglass-rhel/creds"

press

step "Trigger rotation — Vault SSHs into RHEL and sets a new random password:"
cmd "vault write -f os/hosts/rhel-target/accounts/breakglass-rhel/rotate"

press

step "New password in Vault — old one is now invalid on RHEL:"
NEW_PASS=$(vault read -field=password os/hosts/rhel-target/accounts/breakglass-rhel/creds)
cmd "vault read os/hosts/rhel-target/accounts/breakglass-rhel/creds"
echo ""
printf "  ${DIM}  Previous password:  %s${NC}\n" "$OLD_PASS"
printf "  ${GRN}  New password:       %s${NC}\n" "$NEW_PASS"
echo ""
note "Rotation happened entirely within Vault — no Ansible playbook, no human set this password"

press

# ── 1.5 Windows Break-Glass Rotation  (AD Secrets Engine) ─────
clear
section "1.5  Windows Break-Glass Rotation  (AD / LDAP Secrets Engine)"

printf "  ${DIM}  Vault-native — Vault connects to AD via LDAP. No agent, no WinRM required.${NC}\n"
printf "  ${DIM}  Library checkout pattern: account reserved per session, rotated on check-in.${NC}\n"
echo ""

step "Library configuration — two AD accounts in the pool:"
cmd "vault read ldap/library/breakglass-windows"

press

step "Current status — both accounts available:"
cmd "vault read ldap/library/breakglass-windows/status"

press

step "Operator checks out an account — Vault issues time-limited credential:"
echo ""
printf "${GRN}  \$ vault write -f ldap/library/breakglass-windows/check-out${NC}\n\n"
CHECKOUT_JSON=$(vault write -format=json -f ldap/library/breakglass-windows/check-out)
ACCT=$(echo "$CHECKOUT_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['data']['service_account_name'])")
WIN_PASS=$(echo "$CHECKOUT_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['data']['password'])")
label "account :" "$ACCT"
label "password:" "$WIN_PASS"
echo ""
note "Account locked to this operator — no other operator can check out the same account"

press

step "Library status — $ACCT unavailable while checked out:"
cmd "vault read ldap/library/breakglass-windows/status"

press

step "Session complete — operator checks in, Vault rotates AD password immediately:"
cmd "vault write -f ldap/library/breakglass-windows/check-in service_account_names=$ACCT"
note "Vault connects to AD via LDAP and changes the password — no AAP, no WinRM"

press

step "Next checkout issues a brand new password — old credential permanently invalidated:"
echo ""
printf "${GRN}  \$ vault write -f ldap/library/breakglass-windows/check-out${NC}\n\n"
CHECKOUT2_JSON=$(vault write -format=json -f ldap/library/breakglass-windows/check-out)
ACCT2=$(echo "$CHECKOUT2_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['data']['service_account_name'])")
WIN_PASS2=$(echo "$CHECKOUT2_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['data']['password'])")
label "account :" "$ACCT2"
label "password:" "$WIN_PASS2"
echo ""
printf "  ${DIM}  Previous session password:  %s${NC}\n" "$WIN_PASS"
printf "  ${GRN}  New password after check-in: %s${NC}\n" "$WIN_PASS2"
echo ""
note "Break-glass session credential permanently invalidated on check-in"

press

step "Check in to clean up:"
cmd "vault write -f ldap/library/breakglass-windows/check-in service_account_names=$ACCT2"

press

# =============================================================
# SECTION 2 — BREAK-GLASS ACCESS WORKFLOW
# =============================================================
clear
banner "SECTION 2 — Break-Glass Access Workflow"

printf "  ${BOLD}End-to-end privileged access — request, authorise, audit, rotate${NC}\n\n"
printf "  ${CYN}  Step 1:${NC}  operator requests credential  → Vault returns ${YLW}wrapping token${NC}, not password\n"
printf "  ${CYN}  Step 2:${NC}  Control Group holds request   → TTL clock starts (1h)\n"
printf "  ${MAG}  Step 3:${NC}  sec-approver authorises       → accessor approved in Vault\n"
printf "  ${CYN}  Step 4:${NC}  operator unwraps              → credential released\n"
printf "  ${GRN}  Step 5:${NC}  post-use rotation             → old password invalidated immediately\n"
echo ""

press

# ── 2.1 Control Group Policy ──────────────────────────────────
clear
section "2.1  Control Group Policy — The Approval Gate"

step "Policy protecting the RHEL break-glass credential path:"
cmd "vault policy read breakglass-requestor"
note "Reading this path returns a wrapping token — the credential is blocked until approved"
note "approvals = 1 → one security-team member must authorise before unwrap succeeds"

press

# ── 2.2 Operator Requests Access ─────────────────────────────
clear
section "2.2  Operator Requests Break-Glass Access"

step "Operator logs in to Vault:"
cmd "vault login -method=userpass username=operator password=operator123"
REQUESTOR_TOKEN=$(vault login -method=userpass -format=json \
  username=operator password=operator123 | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")
export VAULT_TOKEN=$PRIMARY_TOKEN

press

step "Operator reads RHEL creds — Control Group intercepts, returns wrapping token:"
cmd "VAULT_TOKEN=$REQUESTOR_TOKEN vault read os/hosts/rhel-target/accounts/breakglass-rhel/creds"

CG_JSON=$(VAULT_TOKEN="$REQUESTOR_TOKEN" vault read \
  -format=json os/hosts/rhel-target/accounts/breakglass-rhel/creds)
WRAPPING_TOKEN=$(echo "$CG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['wrap_info']['token'])")
ACCESSOR=$(echo "$CG_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['wrap_info']['accessor'])")

note "RHEL password is NOT in this response — locked in Vault until approved"
note "Operator sends the accessor to security team out-of-band (ticket / Slack)"

press

# ── 2.3 Approver Authorises ───────────────────────────────────
clear
section "2.3  Security Team Approves the Request"

step "Approver logs in to Vault:"
cmd "vault login -method=userpass username=sec-approver password=approver123"
APPROVER_TOKEN=$(vault login -method=userpass -format=json \
  username=sec-approver password=approver123 | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")
export VAULT_TOKEN=$PRIMARY_TOKEN

press

step "Approver authorises — identity and timestamp recorded in Vault audit log:"
cmd "VAULT_TOKEN=$APPROVER_TOKEN vault write sys/control-group/authorize accessor=$ACCESSOR"
note "If min_approvals=2, a second approver must repeat this step"

press

# ── 2.4 Operator Unwraps ──────────────────────────────────────
clear
section "2.4  Operator Unwraps — Credential Released"

step "All approvals met — operator unwraps the token to reveal the RHEL credential:"
cmd "vault unwrap $WRAPPING_TOKEN"
note "Wrapping token is single-use — replaying it returns an error"
note "Without step 2.3, this returns: 'wrapping token is not yet authorized'"

press

# ── 2.5 Post-Use Rotation — RHEL ─────────────────────────────
clear
section "2.5  Post-Use Rotation — RHEL + Windows  (slide ⑪)"

step "RHEL — break-glass session complete, rotate immediately:"
cmd "vault write -f os/hosts/rhel-target/accounts/breakglass-rhel/rotate"
note "Vault SSHs into RHEL and sets a new random password — old credential now invalid"

press

step "Confirm new password — the one just unwrapped no longer works:"
cmd "vault read os/hosts/rhel-target/accounts/breakglass-rhel/creds"

press

step "Windows — same pattern, rotation triggered by check-in:"
note "Shown in Section 1.5 — check-in immediately rotates the AD password via LDAP"
note "Same result: session credential permanently invalidated, account available for next checkout"

press


# =============================================================
# SUMMARY
# =============================================================
clear
banner "Demo Complete"

printf "  ${BOLD}Section 1 — Ansible-Based Automation${NC}\n"
printf "  %-4s AppRole auth       Simulates AAP OIDC — scoped policy, token discarded after job\n" "✓"
printf "  %-4s SSH key rotation   KV v2 + Ansible → ed25519 rotated, pubkey deployed to RHEL\n" "✓"
printf "  %-4s SNMP rotation      KV v2 + Ansible → new string deployed, version stored\n" "✓"
printf "  %-4s RHEL break-glass   OS Engine → password rotated directly via SSH, no AAP\n" "✓"
printf "  %-4s Windows break-glass LDAP library → checkout/check-in, rotated on return\n" "✓"
echo ""
printf "  ${BOLD}Section 2 — Break-Glass Access Workflow${NC}\n"
printf "  %-4s Control Group      Policy gate → wrapping token returned, never raw credential\n" "✓"
printf "  %-4s Request            operator reads path → gets accessor + wrapping token\n" "✓"
printf "  %-4s Approve            sec-approver calls authorize → identity logged in audit\n" "✓"
printf "  %-4s Unwrap             credential released only after all approvals met\n" "✓"
printf "  %-4s Post-use rotation  RHEL rotated via OS Engine, Windows via LDAP check-in\n" "✓"
echo ""
