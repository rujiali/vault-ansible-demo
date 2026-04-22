storage "raft" {
  path    = "/vault/data"
  node_id = "vault-dr"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr      = "http://vault-dr:8200"
cluster_addr  = "http://vault-dr:8201"
ui            = true
disable_mlock = true

plugin_directory = "/vault/plugins"
