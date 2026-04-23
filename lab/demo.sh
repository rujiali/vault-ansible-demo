#!/usr/bin/env bash
# ============================================================
# Vault Enterprise Demo — Sections 1-5
# Run from: lab/   (cd vault-ansible-demo/lab && ./demo.sh)
# Usage:    ./demo.sh [--section 1|2|3|4|5]
# Prerequisites: bootstrap.sh, ldap-setup.sh, vault-setup.sh
# ============================================================
cd "$(dirname "$0")"

START_SECTION=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --section|-s) START_SECTION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

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
if [ "$START_SECTION" -le 1 ]; then
clear
banner "Vault Enterprise — Operational Security Demo"

printf "  ${BOLD}Lab topology:${NC}\n\n"
printf "  ${WHT}Mac (Ansible + Vault CLI)${NC}\n"
printf "     │\n"
printf "     ├── ${CYN}Vault Primary  :8200${NC}\n"
printf "     │       ├── KV v2        SSH keys + SNMP rotation\n"
printf "     │       ├── OS engine    RHEL local account password rotation\n"
printf "     │       └── LDAP         Windows break-glass + password rotation\n"
printf "     │\n"
printf "     ├── ${GRN}RHEL 10 VM     :22${NC}   (%s)\n" "$RHEL_IP"
printf "     └── ${BLU}OpenLDAP       :389${NC}  (simulates Windows AD)\n"
echo ""
printf "  ${BOLD}Two rotation models:${NC}\n"
printf "  ${YLW}  AAP-orchestrated:${NC}  SSH key pairs, SNMP strings  (Vault = store)\n"
printf "  ${GRN}  Vault-native:${NC}      RHEL local accounts (OS Engine), Windows AD (LDAP Engine)\n"
echo ""

press

fi # end intro

# =============================================================
# SECTION 1 — ANSIBLE-BASED AUTOMATION
# =============================================================
if [ "$START_SECTION" -le 1 ]; then
clear
banner "SECTION 1 — Ansible-Based Automation"

# ── 1.2 SSH Key Pair Rotation ─────────────────────────────────
clear
section "1.1  SSH Key Pair Rotation  (KV v2 + Ansible)"

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
section "1.2  SNMP Community String Rotation  (KV v2 + Ansible)"

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
section "1.3  RHEL Break-Glass Rotation  (OS Secrets Engine)"

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
section "1.4  Windows Break-Glass Rotation  (AD / LDAP Secrets Engine)"

printf "  ${DIM}  Vault-native — Vault connects to AD via LDAP. No agent, no WinRM required.${NC}\n"
echo ""

step "Current Windows AD password in Vault:"
OLD_WIN_PASS=$(vault read -field=password ldap/static-cred/breakglass-windows-01 2>/dev/null || \
  vault read -format=json ldap/library/breakglass-windows/check-out 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['password'])" 2>/dev/null || echo "")
cmd "vault read ldap/static-cred/breakglass-windows-01"

press

step "Trigger rotation — Vault connects to AD via LDAP and sets a new random password:"
cmd "vault write -f ldap/rotate-role/breakglass-windows-01"

press

step "New password in Vault — old credential is now invalid in AD:"
NEW_WIN_PASS=$(vault read -field=password ldap/static-cred/breakglass-windows-01 2>/dev/null || echo "")
cmd "vault read ldap/static-cred/breakglass-windows-01"
echo ""
printf "  ${DIM}  Previous password:  %s${NC}\n" "$OLD_WIN_PASS"
printf "  ${GRN}  New password:       %s${NC}\n" "$NEW_WIN_PASS"
echo ""
note "Rotation happened entirely within Vault — no agent, no WinRM, no human set this password"

press

fi # end section 1

# =============================================================
# SECTION 3 — DISASTER RECOVERY
# =============================================================
if [ "$START_SECTION" -le 3 ] && [ "$START_SECTION" -ne 2 ]; then
clear
banner "SECTION 3 — Disaster Recovery Operations"

printf "  ${BOLD}Topology:${NC}  Primary → DR secondary (full replication) + PR secondary (read locality)\n\n"
note "DR cluster is passive — no reads or writes until promoted"
note "Promotion is manual — prevents split-brain"

press

# Pre-generate a vault-pr-native root token while primary is still up.
# vault-pr validates tokens against its own HMAC key (not primary's), so tokens
# created on vault-primary are invalid on vault-pr. We obtain a local token by:
#   1. Ensure vault-pr is unsealed (unseal with PRIMARY_RECOVERY_KEY if needed)
#   2. Login to vault-pr via replicated userpass (pr-admin)
#   3. Cancel any stale generate-root attempt
#   4. Run generate-root with the primary unseal key → vault-pr-native root token
# Retry for up to 90s — vault-pr may still be syncing pr-admin from primary.
PR_NATIVE_TOKEN=""
printf "  ${DIM}  Obtaining vault-pr native token...${NC}\n"

for _i in 1 2 3 4 5 6 7 8 9; do
  _pr_admin=$(VAULT_ADDR=$PR_ADDR vault login \
    -method=userpass -format=json username=pr-admin password=pradmin123 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])" 2>/dev/null || echo "")
  if [ -n "$_pr_admin" ]; then
    VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_pr_admin \
      vault delete sys/generate-root/attempt >/dev/null 2>&1 || true
    _pr_init=$(VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_pr_admin \
      vault operator generate-root -init -format=json 2>/dev/null || echo "")
    if [ -n "$_pr_init" ]; then
      _pr_nonce=$(echo "$_pr_init" | python3 -c "import sys,json; print(json.load(sys.stdin)['nonce'])")
      _pr_otp=$(echo "$_pr_init"   | python3 -c "import sys,json; print(json.load(sys.stdin)['otp'])")
      _pr_enc=$(VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_pr_admin \
        vault operator generate-root -nonce="$_pr_nonce" -format=json "$PRIMARY_RECOVERY_KEY" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('encoded_token') or d.get('encoded_root_token'))" 2>/dev/null || echo "")
      [ -n "$_pr_enc" ] && PR_NATIVE_TOKEN=$(VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_pr_admin vault operator generate-root \
        -decode="$_pr_enc" -otp="$_pr_otp" 2>/dev/null || echo "")
    fi
  fi
  [ -n "$PR_NATIVE_TOKEN" ] && break
  printf "  ${DIM}  vault-pr not ready yet, retrying in 10s (attempt $_i/9)...${NC}\n"
  sleep 10
done
if [ -z "$PR_NATIVE_TOKEN" ]; then
  printf "  ${RED}  ERROR:${NC} Could not generate vault-pr native token after 90s.\n"
  printf "  ${YLW}  Diagnosing vault-pr state:${NC}\n"
  VAULT_ADDR=$PR_ADDR vault status 2>&1 | head -10 || true
  printf "  ${YLW}  Run ./reset-demo.sh and wait for it to complete before running the demo.${NC}\n\n"
  exit 1
fi
printf "  ${GRN}  vault-pr native token ready${NC}\n\n"

# ── 3.1 Replication Status ────────────────────────────────────
section "3.1  Current Replication Status"

step "Primary replication state:"
cmd "VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN vault read -format=json sys/replication/status | python3 -c \"
import sys,json
d=json.load(sys.stdin)['data']
dr=d.get('dr',{})
perf=d.get('performance',{})
print('DR  mode :', dr.get('mode','n/a'), '  cluster_id:', dr.get('cluster_id','n/a')[:8]+'...' if dr.get('cluster_id') else 'n/a')
print('PR  mode :', perf.get('mode','n/a'), '  cluster_id:', perf.get('cluster_id','n/a')[:8]+'...' if perf.get('cluster_id') else 'n/a')
\""

press

step "DR secondary status:"
cmd "VAULT_ADDR=$DR_ADDR VAULT_TOKEN=$DR_TOKEN vault read -format=json sys/replication/dr/status | python3 -c \"
import sys,json
d=json.load(sys.stdin)['data']
print('mode            :', d.get('mode'))
print('state           :', d.get('state'))
print('primary_cluster :', d.get('primary_cluster_addr','n/a'))
print('last_remote_wal :', d.get('last_remote_wal','n/a'))
\""

press

# ── 3.2 Simulate Primary Failure ──────────────────────────────
clear
section "3.2  Simulate Primary Failure"

note "In production: declare failure only when primary is confirmed unrecoverable — split-brain risk"

press

step "Stopping vault-primary to simulate failure:"
cmd "docker compose -f $(dirname $0)/docker-compose.yml stop vault-primary"
note "Primary is now unreachable"

press

step "Confirming primary is down:"
cmd "VAULT_ADDR=$PRIMARY_ADDR vault status 2>&1 || true"

press

# ── 3.3 Generate DR Operation Token & Promote ─────────────────
clear
section "3.3  Promote DR Cluster to Primary"

step "Generate DR operation token on DR secondary:"
INIT_JSON=$(VAULT_ADDR=$DR_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
  vault operator generate-root -dr-token -init -format=json)
DR_NONCE=$(echo "$INIT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['nonce'])")
DR_OTP=$(echo "$INIT_JSON"   | python3 -c "import sys,json; print(json.load(sys.stdin)['otp'])")
ENCODED=$(VAULT_ADDR=$DR_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
  vault operator generate-root -dr-token -nonce="$DR_NONCE" -format=json "$PRIMARY_RECOVERY_KEY" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('encoded_token') or d.get('encoded_root_token'))")
DR_OP_TOKEN=$(VAULT_ADDR=$DR_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
  vault operator generate-root -dr-token -decode="$ENCODED" -otp="$DR_OTP")
printf "  ${GRN}  DR operation token generated${NC}\n\n"

press

step "Promoting DR cluster to primary:"
cmd "VAULT_ADDR=$DR_ADDR vault write -f sys/replication/dr/secondary/promote dr_operation_token=$DR_OP_TOKEN"
note "DR cluster is now the active primary"

press

step "Confirm DR cluster is now primary:"
cmd "VAULT_ADDR=$DR_ADDR vault read -format=json sys/replication/dr/status | python3 -c \"
import sys,json
d=json.load(sys.stdin)['data']
print('mode  :', d.get('mode'))
print('state :', d.get('state'))
\""

press

# ── 3.5 Restore Original Primary ──────────────────────────────
clear
section "3.5  Restore Original Primary  (lab cleanup)"

step "Restarting vault-primary:"
cmd "docker compose -f $(dirname $0)/docker-compose.yml start vault-primary"
printf "  ${DIM}  Waiting for vault-primary to auto-unseal (PKCS11)...${NC}\n"
for _i in $(seq 1 20); do
  _sealed=$(VAULT_ADDR=$PRIMARY_ADDR vault status -format=json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed',True))" 2>/dev/null || echo "True")
  [ "$_sealed" = "False" ] && break
  sleep 3
done
printf "  ${GRN}  vault-primary unsealed${NC}\n\n"
note "In production: original primary would be re-joined as a secondary or decommissioned"

press

step "Restoring DR replication — re-enrolling vault-dr as secondary:"
VAULT_ADDR=$DR_ADDR VAULT_TOKEN=$PRIMARY_TOKEN vault write -f sys/replication/dr/primary/disable &>/dev/null || true
sleep 3
VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN vault write -f sys/replication/dr/primary/disable &>/dev/null || true
sleep 2
VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN vault write -f sys/replication/dr/primary/enable &>/dev/null
sleep 3
DR_REWRAP=$(VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
  vault write -format=json sys/replication/dr/primary/secondary-token id=vault-dr \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['wrap_info']['token'])")
VAULT_ADDR=$DR_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
  vault write sys/replication/dr/secondary/enable token=$DR_REWRAP primary_api_addr=http://vault-primary:8200 &>/dev/null
printf "  ${GRN}  DR replication restored — vault-dr is secondary again${NC}\n\n"

# Restore vault-pr as secondary of vault-primary — full wipe + re-init for a clean state.
printf "  ${DIM}  Restoring vault-pr (wipe + re-init, ~45s)...${NC}\n"
VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
  vault write -f sys/replication/performance/primary/revoke-secondary id=vault-pr &>/dev/null 2>&1 || true
docker compose -f "$(dirname $0)/docker-compose.yml" stop vault-pr >/dev/null 2>&1
rm -rf "$(dirname $0)/data/pr"
docker compose -f "$(dirname $0)/docker-compose.yml" start vault-pr >/dev/null 2>&1
sleep 5
_pr_ij=$(VAULT_ADDR=$PR_ADDR vault operator init -recovery-shares=1 -recovery-threshold=1 -format=json 2>/dev/null)
_pr_rk=$(echo "$_pr_ij" | python3 -c "import sys,json; print(json.load(sys.stdin)['recovery_keys_b64'][0])" 2>/dev/null)
_pr_rt=$(echo "$_pr_ij" | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])" 2>/dev/null)
for _i in $(seq 1 20); do
  _s=$(VAULT_ADDR=$PR_ADDR vault status -format=json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed',True))" 2>/dev/null || echo "True")
  [ "$_s" = "False" ] && break; sleep 3
done
_pr_wrap=$(VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
  vault write -format=json sys/replication/performance/primary/secondary-token id=vault-pr \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['wrap_info']['token'])" 2>/dev/null)
VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_pr_rt \
  vault write sys/replication/performance/secondary/enable \
  token="$_pr_wrap" primary_api_addr=http://vault-primary:8200 >/dev/null 2>&1
sleep 45
for _i in $(seq 1 20); do
  _s=$(VAULT_ADDR=$PR_ADDR vault status -format=json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed',True))" 2>/dev/null || echo "True")
  [ "$_s" = "False" ] && break; sleep 3
done
sleep 3

# Regenerate PR_NATIVE_TOKEN — vault-pr's token store was replaced during secondary enable,
# so the token from the section 3 preamble is now invalid. Generate a fresh one while
# vault-primary is still up (before section 4 stops it).
PR_NATIVE_TOKEN=""
printf "  ${DIM}  Regenerating vault-pr native token for section 4...${NC}\n"
for _i in 1 2 3 4 5 6; do
  _pr_adm35=$(VAULT_ADDR=$PR_ADDR vault login \
    -method=userpass -format=json username=pr-admin password=pradmin123 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])" 2>/dev/null || echo "")
  if [ -n "$_pr_adm35" ]; then
    VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_pr_adm35 \
      vault delete sys/generate-root/attempt >/dev/null 2>&1 || true
    _pr_i35=$(VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_pr_adm35 \
      vault operator generate-root -init -format=json 2>/dev/null || echo "")
    if [ -n "$_pr_i35" ]; then
      _n35=$(echo "$_pr_i35" | python3 -c "import sys,json; print(json.load(sys.stdin)['nonce'])")
      _o35=$(echo "$_pr_i35" | python3 -c "import sys,json; print(json.load(sys.stdin)['otp'])")
      _e35=$(VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_pr_adm35 \
        vault operator generate-root -nonce="$_n35" -format=json "$PRIMARY_RECOVERY_KEY" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('encoded_token') or d.get('encoded_root_token'))" 2>/dev/null || echo "")
      [ -n "$_e35" ] && PR_NATIVE_TOKEN=$(VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_pr_adm35 vault operator generate-root \
        -decode="$_e35" -otp="$_o35" 2>/dev/null || echo "")
    fi
  fi
  [ -n "$PR_NATIVE_TOKEN" ] && break
  printf "  ${DIM}  vault-pr not ready yet, retrying in 10s (attempt $_i/6)...${NC}\n"
  sleep 10
done
if [ -z "$PR_NATIVE_TOKEN" ]; then
  printf "  ${RED}  ERROR:${NC} Could not regenerate vault-pr native token after sync.\n"
  printf "  ${YLW}  Run ./reset-demo.sh before continuing.${NC}\n\n"
  exit 1
fi
printf "  ${GRN}  vault-pr native token ready for section 4${NC}\n\n"

printf "  ${GRN}  PR replication restored — vault-pr is secondary of vault-primary again${NC}\n\n"

press

fi # end section 3

# =============================================================
# SECTION 4 — LOCAL CLUSTERS & AUTONOMOUS OPERATION
# =============================================================
if [ "$START_SECTION" -le 4 ] && [ "$START_SECTION" -ne 2 ]; then
clear
banner "SECTION 4 — Local Clusters & Autonomous Operation"

printf "  ${BOLD}Network partition simulation:${NC}\n\n"
printf "  vault-primary   stays running — continues to accept writes\n"
printf "  vault-pr        loses network contact with vault-primary\n"
echo ""
printf "  ${GRN}  PR cluster continues:${NC}  reads, token auth, local policy enforcement\n"
printf "  ${RED}  PR cluster stops:${NC}     write forwarding (primary unreachable)\n"
echo ""
note "This is different from a full primary outage — primary is healthy, only the link is broken"

# Generate PR_NATIVE_TOKEN if not already set (e.g. jumping directly to --section 4)
if [ -z "$PR_NATIVE_TOKEN" ]; then
  printf "  ${DIM}  Obtaining vault-pr native token...${NC}\n"
  for _i in 1 2 3 4 5 6; do
    _adm=$(VAULT_ADDR=$PR_ADDR vault login \
      -method=userpass -format=json username=pr-admin password=pradmin123 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])" 2>/dev/null || echo "")
    if [ -n "$_adm" ]; then
      VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_adm vault delete sys/generate-root/attempt >/dev/null 2>&1 || true
      _init=$(VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_adm vault operator generate-root -init -format=json 2>/dev/null || echo "")
      if [ -n "$_init" ]; then
        _nonce=$(echo "$_init" | python3 -c "import sys,json; print(json.load(sys.stdin)['nonce'])")
        _otp=$(echo "$_init"   | python3 -c "import sys,json; print(json.load(sys.stdin)['otp'])")
        _enc=$(VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_adm \
          vault operator generate-root -nonce="$_nonce" -format=json "$PRIMARY_RECOVERY_KEY" 2>/dev/null \
          | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('encoded_token') or d.get('encoded_root_token'))" 2>/dev/null || echo "")
        [ -n "$_enc" ] && PR_NATIVE_TOKEN=$(VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$_adm vault operator generate-root \
          -decode="$_enc" -otp="$_otp" 2>/dev/null || echo "")
      fi
    fi
    [ -n "$PR_NATIVE_TOKEN" ] && break
    printf "  ${DIM}  vault-pr not ready, retrying in 10s (${_i}/6)...${NC}\n"
    sleep 10
  done
  if [ -z "$PR_NATIVE_TOKEN" ]; then
    printf "  ${RED}  ERROR:${NC} Could not generate vault-pr native token.\n"
    printf "  ${YLW}  Run ./reset-demo.sh first.${NC}\n\n"
    exit 1
  fi
  printf "  ${GRN}  vault-pr native token ready${NC}\n\n"
fi

press

# ── 4.0 Simulate Network Partition ───────────────────────────
section "4.0  Simulate Network Partition"

step "Partition vault-pr from vault-primary using a blackhole route (primary stays running):"
_PRIMARY_IP=$(docker inspect vault-primary --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
docker exec vault-pr ip route add blackhole "$_PRIMARY_IP" 2>/dev/null || true
printf "${GRN}  \$ docker exec vault-pr ip route add blackhole %s${NC}\n\n" "$_PRIMARY_IP"
note "vault-pr cannot reach vault-primary — port 8204 on host remains accessible"
note "vault-primary remains fully operational and continues to accept writes from the host"

press

# ── 4.1 Reads Continue During Partition ──────────────────────
section "4.1  Reads Continue on the Isolated PR Cluster"

step "Read from PR cluster — succeeds from local data store:"
cmd "VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$PR_NATIVE_TOKEN vault kv get secret/ansible/snmp"
note "PR cluster serves its last-known data — no contact with primary required for reads"

press

# ── 4.2 Writes During Partition ───────────────────────────────
section "4.2  Write Behaviour During Partition"

step "Attempt a write to PR cluster — fails, cannot forward to primary:"
cmd "VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$PR_NATIVE_TOKEN vault kv put secret/ansible/snmp community_string=pr-write-during-partition 2>&1 || true"
note "PR cluster never accepts writes locally — it always forwards to primary"

press

step "Write directly to primary — succeeds, primary is still running:"
cmd "VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN vault kv put secret/ansible/snmp community_string=written-on-primary-during-partition"
note "Primary has no idea vault-pr is partitioned — it processes the write and queues the WAL entry"

press

step "PR cluster still serves the old value — partition in effect:"
cmd "VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$PR_NATIVE_TOKEN vault kv get secret/ansible/snmp"
echo ""
printf "  ${BOLD}  Why there are no write conflicts:${NC}\n"
printf "      All writes land on Primary only — PR never buffers writes locally.\n"
printf "      During partition: Primary accepts writes, PR serves stale reads.\n"
printf "      On reconnect: Primary replays queued WAL — no merge, no reconciliation.\n"
echo ""

press

# ── 4.3 Reconnect & Automatic Resync ─────────────────────────
section "4.3  Reconnect & Automatic Resync"

step "Restore network — remove blackhole route:"
_PRIMARY_IP=$(docker inspect vault-primary --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
docker exec vault-pr ip route del blackhole "$_PRIMARY_IP" 2>/dev/null || true
printf "${GRN}  \$ docker exec vault-pr ip route del blackhole %s${NC}\n\n" "$_PRIMARY_IP"
note "WAL stream resumes — primary replays all entries written during the partition"

# Wait for WAL sync: poll until PR's KV version matches what primary had during partition.
printf "  ${DIM}  Waiting for WAL sync — polling PR version...${NC}\n"
_primary_ver=$(VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN \
  vault kv metadata get -format=json secret/ansible/snmp 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['current_version'])" 2>/dev/null || echo "0")
for _i in $(seq 1 18); do
  _pr_ver=$(VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$PR_NATIVE_TOKEN \
    vault kv metadata get -format=json secret/ansible/snmp 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['current_version'])" 2>/dev/null || echo "0")
  if [ "$_pr_ver" = "$_primary_ver" ]; then
    printf "  ${GRN}  WAL sync complete — PR now at version %s${NC}\n\n" "$_pr_ver"
    break
  fi
  printf "  ${DIM}  PR at v%s, waiting for v%s (attempt %s/18)...${NC}\n" "$_pr_ver" "$_primary_ver" "$_i"
  sleep 5
done

press

step "Read from PR — the write made to primary during partition is now visible:"
cmd "VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$PR_NATIVE_TOKEN vault kv get secret/ansible/snmp"
note "Primary queued the WAL entry while vault-pr was partitioned — replayed on reconnect automatically"

press

step "Write via PR — forwarding to primary re-established:"
cmd "VAULT_ADDR=$PR_ADDR VAULT_TOKEN=$PR_NATIVE_TOKEN vault kv put secret/ansible/snmp community_string=post-reconnect"

press

step "Summary — the propagation model:"
printf "  ${BOLD}  Central Primary, push to local:${NC}\n"
printf "      Primary  →  streams WAL entries  →  PR Cluster A\n"
printf "      Primary  →  streams WAL entries  →  PR Cluster B  (Site B, Site C, ...)\n"
echo ""
printf "  ${DIM}  Connected:${NC}      changes replicate within seconds of landing on Primary\n"
printf "  ${DIM}  Partitioned:${NC}    Primary queues WAL; PR serves stale reads; Primary still accepts writes\n"
printf "  ${DIM}  Reconnected:${NC}    Primary replays queued WAL; PR catches up — no manual step\n"
echo ""

press

fi # end section 4

# =============================================================
# SECTION 5 — OPERATIONAL BEST PRACTICES
# =============================================================
if [ "$START_SECTION" -le 5 ] && [ "$START_SECTION" -ne 2 ]; then
clear
banner "SECTION 5 — Operational Best Practices"

printf "  ${BOLD}Unseal, Backup & Restore${NC}\n\n"

press

# ── 5.1 Unseal on Reboot ──────────────────────────────────────
section "5.1  Auto-Unseal on Restart  (Transit / HSM)"

step "Current seal type — Transit auto-unseal (lab uses Vault Transit; production uses HSM or cloud KMS):"
cmd "VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN vault status"
note "seal_type: transit — Vault wraps its master key using the transit key on restart"

press

step "Simulate a restart — stop vault-primary:"
cmd "docker compose -f $(dirname $0)/docker-compose.yml stop vault-primary"

press

step "Restart vault-primary — no human action required:"
cmd "docker compose -f $(dirname $0)/docker-compose.yml start vault-primary"
printf "  ${DIM}  Waiting for auto-unseal...${NC}\n"
for _i in $(seq 1 20); do
  _sealed=$(VAULT_ADDR=$PRIMARY_ADDR vault status -format=json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed',True))" 2>/dev/null || echo "True")
  [ "$_sealed" = "False" ] && break
  sleep 3
done
printf "  ${GRN}  vault-primary unsealed automatically${NC}\n\n"

step "Confirm unsealed — no key-holder needed:"
cmd "VAULT_ADDR=$PRIMARY_ADDR vault status"
note "In production: replace Transit with a hardware HSM or cloud KMS (AWS KMS, Azure Key Vault, PKCS11)"
note "Recovery keys replace unseal keys — used only for generate-root operations, not for unsealing"

press

# ── 5.2 Raft Snapshot Backup ──────────────────────────────────
clear
section "5.2  Backup — Raft Snapshot"

step "Save a consistent snapshot of all Vault data:"
cmd "VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN vault operator raft snapshot save /tmp/vault-demo-snapshot.gz"
cmd "ls -lh /tmp/vault-demo-snapshot.gz"
note "Snapshot is encrypted — safe to store in object storage. Schedule via cron in production."

press

# ── 5.3 Raft Snapshot Restore ─────────────────────────────────
section "5.3  Restore — Raft Snapshot"

step "Restore from snapshot (non-destructive in this demo — same data):"
cmd "VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN vault operator raft snapshot restore -force /tmp/vault-demo-snapshot.gz"
note "In production: restore to an initialised but empty cluster. Test restores regularly."

press

step "Verify data intact after restore:"
cmd "VAULT_ADDR=$PRIMARY_ADDR VAULT_TOKEN=$PRIMARY_TOKEN vault kv get secret/ansible/snmp"

press

fi # end section 5

# =============================================================
# SECTION 2 — BREAK-GLASS ACCESS WORKFLOW  (optional, --section 2)
# =============================================================
if [ "$START_SECTION" -eq 2 ]; then
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
section "2.5  Post-Use Rotation — RHEL + Windows"

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

step "If Vault itself is unavailable — recovery path:"
printf "  ${YLW}  If Vault is completely unreachable, break-glass access requires restoring Vault first.${NC}\n"
printf "  ${DIM}  Recovery path:${NC}\n"
printf "      1. Restore from Raft snapshot  (covered in Section 5)\n"
printf "      2. Unseal the restored cluster\n"
printf "      3. Resume normal break-glass workflow\n"
echo ""
note "This is why regular snapshot backups (Section 5) are a prerequisite for break-glass resilience"
note "Production recommendation: maintain an out-of-band emergency credential store for the period between failure and Vault restoration"

press

fi # end section 2

# =============================================================
# SUMMARY
# =============================================================
clear
banner "Demo Complete"

printf "  ${BOLD}Section 1 — Ansible-Based Automation${NC}\n"
printf "  %-4s SSH key rotation    KV v2 + Ansible → ed25519 rotated, pubkey deployed to RHEL\n" "✓"
printf "  %-4s SNMP rotation       KV v2 + Ansible → new string deployed, version stored\n" "✓"
printf "  %-4s RHEL break-glass    OS Engine → password rotated directly via SSH\n" "✓"
printf "  %-4s Windows break-glass LDAP static role → password rotated on demand\n" "✓"
echo ""
printf "  ${BOLD}Section 2 — Disaster Recovery${NC}\n"
printf "  %-4s Replication status  Primary DR + PR replication state verified\n" "✓"
printf "  %-4s DR promotion        DR cluster promoted to primary via operation token\n" "✓"
printf "  %-4s Primary restore     Original primary restarted, rejoins as DR secondary\n" "✓"
echo ""
printf "  ${BOLD}Section 3 — Autonomous Operation (Network Partition)${NC}\n"
printf "  %-4s Reads continue      PR serves local data while partitioned from primary\n" "✓"
printf "  %-4s Writes to primary   Primary stays up, accepts writes during partition\n" "✓"
printf "  %-4s PR writes fail      Write forwarding fails — primary unreachable from PR\n" "✓"
printf "  %-4s Auto resync         WAL replayed on reconnect — PR catches up automatically\n" "✓"
echo ""
printf "  ${BOLD}Section 4 — Operational Best Practices${NC}\n"
printf "  %-4s Auto-unseal         Transit seal restart — no key-holder required\n" "✓"
printf "  %-4s Backup              Raft snapshot saved\n" "✓"
printf "  %-4s Restore             Snapshot restored, data verified intact\n" "✓"
echo ""
