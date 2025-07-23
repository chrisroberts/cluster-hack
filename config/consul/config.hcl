datacenter     = "dc1"
data_dir       = "/opt/consul"
encrypt        = "%GOSSIP_KEY%"
retry_join     = ["%ADDR%"]
client_addr    = "0.0.0.0"
log_level      = "DEBUG"
recursors      = ["1.1.1.1", "8.8.8.8"]
bind_addr      = "%LOCAL_ADDR%"
advertise_addr = "%LOCAL_ADDR%"

addresses {
  dns = "0.0.0.0"
}

acl {
  enabled                  = true
  default_policy           = "deny"
  enable_token_persistence = true
}

ports {
  grpc = 8502
  dns  = 53
}
