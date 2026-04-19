# Lab Setup Guide

## Overview

| Component | How | Port / Address |
|---|---|---|
| vault-primary | Docker | localhost:8200 |
| vault-dr | Docker | localhost:8202 |
| vault-pr | Docker | localhost:8204 |
| rhel-target | VMware Fusion | 192.168.x.x (bridged) |
| win-target | VMware Fusion | 192.168.x.x (bridged) |

---

## Part 1 — Prerequisites (Mac host)

### 1.1 Install tools

```bash
brew install vault ansible jq python3
pip3 install hvac pywinrm
ansible-galaxy collection install community.hashi_vault community.windows
```

### 1.2 Vault Enterprise license

You need a Vault Enterprise license string. Set it before starting Docker:

```bash
export VAULT_LICENSE="<your-license-string>"
# Add to ~/.zshrc to persist
```

---

## Part 2 — Vault Clusters (Docker)

### 2.1 Start clusters

```bash
cd vault-ansible-demo/lab
docker compose up -d
```

Verify all three are up:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

### 2.2 Bootstrap (init + unseal + replication)

```bash
./bootstrap.sh
```

This will:
- Init and unseal each cluster with 1 key share
- Enable DR replication (vault-dr as secondary)
- Enable Performance replication (vault-pr as secondary)
- Save credentials to `.vault-creds`

### 2.3 Load credentials

```bash
source .vault-creds
export VAULT_ADDR=$PRIMARY_ADDR
export VAULT_TOKEN=$PRIMARY_TOKEN
```

### 2.4 Verify

```bash
# Check replication status
vault read sys/replication/status

# Access UIs
open http://localhost:8200   # Primary
open http://localhost:8202   # DR
open http://localhost:8204   # PR
```

### 2.5 Reset (start fresh)

```bash
docker compose down -v   # -v removes volumes (wipes all data)
docker compose up -d
./bootstrap.sh
```

---

## Part 3 — RHEL VM (VMware Fusion)

Use **Rocky Linux 9** (free, RHEL-compatible) or RHEL 9 with a developer subscription.

### 3.1 Download

- Rocky Linux 9 minimal ISO: https://rockylinux.org/download
- Or RHEL 9: https://developers.redhat.com (free dev account)

### 3.2 VMware Fusion settings

| Setting | Value |
|---|---|
| RAM | 2 GB |
| Disk | 20 GB |
| Network | Bridged (allows Mac host to reach VM directly) |

### 3.3 Post-install setup

SSH into the VM, then:

```bash
# Enable SSH (usually already on)
sudo systemctl enable --now sshd

# Create test service accounts (simulate batch targets)
sudo useradd -m svc_app1
sudo useradd -m svc_app2
sudo useradd -m svc_app3
sudo passwd svc_app1   # set initial passwords

# Allow Ansible user (use root or create a dedicated user)
sudo useradd -m ansible
sudo usermod -aG wheel ansible
# Set up SSH key auth from Mac host (see 3.4)
```

### 3.4 SSH key auth from Mac

```bash
# On Mac
ssh-keygen -t ed25519 -f ~/.ssh/lab_key -N ""
ssh-copy-id -i ~/.ssh/lab_key.pub ansible@<rhel-vm-ip>

# Test
ssh -i ~/.ssh/lab_key ansible@<rhel-vm-ip> "whoami"
```

### 3.5 Find the VM IP

In VMware Fusion, check VM > Settings > Network or run inside the VM:

```bash
ip addr show | grep "inet "
```

---

## Part 4 — Windows VM (VMware Fusion)

Use **Windows Server 2022 Evaluation** (180-day free trial).

### 4.1 Download

- Windows Server 2022 Evaluation ISO: https://www.microsoft.com/evalcenter/evaluate-windows-server-2022

### 4.2 VMware Fusion settings

| Setting | Value |
|---|---|
| RAM | 4 GB |
| Disk | 40 GB |
| Network | Bridged |

### 4.3 Enable WinRM (inside Windows)

Open PowerShell as Administrator:

```powershell
# Enable WinRM
Enable-PSRemoting -Force
winrm quickconfig -force

# Allow basic auth (for lab only — not production)
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/service '@{AllowUnencrypted="true"}'

# Open firewall
netsh advfirewall firewall add rule name="WinRM HTTP" protocol=TCP dir=in localport=5985 action=allow

# Verify
winrm enumerate winrm/config/listener
```

### 4.4 Create test local accounts

```powershell
# Create test service accounts
$password = ConvertTo-SecureString "InitialPass123!" -AsPlainText -Force
New-LocalUser "svc_app1" -Password $password -FullName "Service App 1" -PasswordNeverExpires
New-LocalUser "svc_app2" -Password $password -FullName "Service App 2" -PasswordNeverExpires
New-LocalUser "svc_app3" -Password $password -FullName "Service App 3" -PasswordNeverExpires
```

### 4.5 Test WinRM from Mac

```bash
# Test connectivity
python3 -c "
import winrm
s = winrm.Session('http://<win-vm-ip>:5985/wsman',
    auth=('Administrator', '<password>'),
    transport='basic')
r = s.run_cmd('whoami')
print(r.std_out.decode())
"
```

---

## Part 5 — Ansible Inventory

Create `vault-ansible-demo/ansible/inventory.yml`:

```yaml
all:
  children:
    rhel_targets:
      hosts:
        rhel-target:
          ansible_host: <rhel-vm-ip>
          ansible_user: ansible
          ansible_ssh_private_key_file: ~/.ssh/lab_key
          ansible_become: yes

    windows_targets:
      hosts:
        win-target:
          ansible_host: <win-vm-ip>
          ansible_user: Administrator
          ansible_password: "<win-admin-password>"
          ansible_connection: winrm
          ansible_winrm_transport: basic
          ansible_winrm_scheme: http
          ansible_port: 5985

  vars:
    vault_addr: "http://localhost:8200"
    vault_auth_method: approle
```

### Test connectivity

```bash
cd vault-ansible-demo/ansible
ansible rhel_targets -m ping -i inventory.yml
ansible windows_targets -m win_ping -i inventory.yml
```

---

## Part 6 — Vault Secrets Engine Setup

After bootstrap, run these once to configure secrets engines for the demo:

```bash
source lab/.vault-creds
export VAULT_ADDR=$PRIMARY_ADDR
export VAULT_TOKEN=$PRIMARY_TOKEN

# KV v2 for SNMP and Windows credentials
vault secrets enable -path=secret kv-v2

# SSH CA for batch cert signing
vault secrets enable -path=ssh ssh
vault write ssh/config/ca generate_signing_key=true

# OS Secrets Engine (for RHEL)
# Requires vault-plugin-secrets-os binary — see demo-guide.md Section 1.3
# vault plugin register ...
# vault secrets enable -path=os vault-plugin-secrets-os

# AppRole auth
vault auth enable approle

# Seed initial SNMP community strings
vault kv put secret/network/snmp \
  community_ro="public_ro_initial" \
  community_rw="public_rw_initial"

# Seed Windows local account credentials
vault kv put secret/windows/svc_app1 username="svc_app1" password="InitialPass123!"
vault kv put secret/windows/svc_app2 username="svc_app2" password="InitialPass123!"
vault kv put secret/windows/svc_app3 username="svc_app3" password="InitialPass123!"
```

---

## Quick Reference

| Task | Command |
|---|---|
| Start lab | `docker compose up -d` |
| Stop lab | `docker compose down` |
| Wipe and restart | `docker compose down -v && docker compose up -d && ./bootstrap.sh` |
| Primary UI | http://localhost:8200 |
| DR UI | http://localhost:8202 |
| PR UI | http://localhost:8204 |
| Load creds | `source lab/.vault-creds` |
| RHEL SSH | `ssh -i ~/.ssh/lab_key ansible@<rhel-ip>` |
