ui           = true
api_addr     = "http://%ADDR%:8200"
cluster_addr = "http://%ADDR%:8201"
log_level    = "DEBUG"

listener "tcp" {
  address     = "%ADDR%:8200"
  tls_disable = true
  # tls_cert_file = "/opt/vault/tls/vault.crt"
  # tls_key_file  = "/opt/vault/tls/vault.key"
}
