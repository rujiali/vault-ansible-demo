storage "raft" {
  path    = "/vault/data"
  node_id = "vault-primary"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr         = "http://vault-primary:8200"
cluster_addr     = "http://vault-primary:8201"
ui               = true
disable_mlock    = true
plugin_directory = "/vault/plugins"
