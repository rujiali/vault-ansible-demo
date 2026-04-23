storage "raft" {
  path    = "/vault/data"
  node_id = "vault-primary"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

seal "transit" {
  address    = "http://vault-transit:8200"
  token      = "${VAULT_TRANSIT_SEAL_TOKEN}"
  key_name   = "vault-unseal-key"
  mount_path = "transit/"
}

api_addr         = "http://vault-primary:8200"
cluster_addr     = "http://vault-primary:8201"
ui               = true
disable_mlock    = true
plugin_directory = "/vault/plugins"
