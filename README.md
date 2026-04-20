# Vault Enterprise — Operational Security Demo

A hands-on lab demonstrating Vault Enterprise credential automation and break-glass access workflows using Ansible, LDAP, and the OS Secrets Engine.

## What This Demo Covers

| Section | Topic |
|---------|-------|
| 1 | Ansible-based automation — SSH key rotation, SNMP rotation, RHEL break-glass (OS Engine), Windows break-glass (LDAP library checkout) |
| 2 | Break-glass access workflow — Control Groups, dual approval, audit trail, post-use rotation |
| 3 | Disaster Recovery — DR activation, PR cluster re-pointing |
| 4 | Autonomous operation — behaviour during primary disconnect |
| 5 | Operational best practices — unseal, backup, restore |

## Lab Topology

```
Mac (Ansible + Vault CLI)
  ├── vault-primary  :8200   (Vault Enterprise 2.0, Raft)
  ├── vault-dr       :8202   (DR secondary)
  ├── vault-pr       :8204   (Performance replication secondary)
  ├── openldap       :389    (simulates Windows AD)
  └── RHEL VM        :22     (VMware Fusion, bridged network)
```

## Prerequisites

- Docker Desktop
- Vault CLI (`brew install vault`)
- `ldap-utils` (`brew install openldap`)
- Vault Enterprise license — **full enterprise**, not PKI-only (must include `governance-policy` module for Control Groups)
- RHEL/Rocky Linux 9 VM in VMware Fusion with:
  - `ansible` user (sudo, SSH key from `~/.ssh/lab_key`, password auth enabled)
  - `breakglass-rhel` local account

## Setup

### 1. Configure license

```bash
cp lab/.env.example lab/.env
# Edit lab/.env and set VAULT_LICENSE=<your-license-string>
```

### 2. Start containers

```bash
cd lab
docker compose up -d
```

### 3. Bootstrap Vault clusters

```bash
./bootstrap.sh
```

Initialises and unseals all three clusters, enables DR and Performance replication. Credentials saved to `lab/.vault-creds`.

### 4. Configure LDAP

```bash
source .vault-creds
./ldap-setup.sh
```

Seeds OpenLDAP with break-glass accounts and configures the Vault LDAP secrets engine library checkout.

### 5. Configure Vault

```bash
./vault-setup.sh
```

Enables secrets engines (KV v2, SSH, OS, LDAP), creates AppRole, userpass accounts, Control Group policies, and registers the RHEL host.

### 6. Run the demo

```bash
./demo.sh
```

## Quick Reference

| Task | Command |
|------|---------|
| Start lab | `docker compose up -d` |
| Stop lab | `docker compose down` |
| Re-unseal after restart | `./bootstrap.sh` |
| Load credentials | `source lab/.vault-creds` |
| Primary UI | http://localhost:8200 |
| DR UI | http://localhost:8202 |
| PR UI | http://localhost:8204 |
| Full reset | `docker compose down && rm -rf data/primary data/dr data/pr && docker compose up -d && ./bootstrap.sh` |

## Credentials (Lab Only)

| Account | Username | Password |
|---------|----------|----------|
| Vault operator | userpass: `operator` | `operator123` |
| Security approver | userpass: `sec-approver` | `approver123` |
| LDAP admin | `cn=admin,dc=corp,dc=example,dc=com` | `admin` |

## License Note

The Vault Enterprise license must **not** include `PKI-only Secrets`. A PKI-only license blocks KV, SSH, Transit, LDAP, and the OS Secrets Engine. Request a full enterprise trial from [portal.cloud.hashicorp.com](https://portal.cloud.hashicorp.com).
