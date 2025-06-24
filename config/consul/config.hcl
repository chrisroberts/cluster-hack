datacenter  = "dc1"
data_dir    = "/opt/consul"
encrypt     = "%GOSSIP_KEY%"
retry_join  = ["%ADDR%"]
bind_addr   = "0.0.0.0"
client_addr = "0.0.0.0"
