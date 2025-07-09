disable_mlock = true

backend "raft" {
  node_id = "%NODE_ID%"
  path    = "/opt/vault/data"
}
