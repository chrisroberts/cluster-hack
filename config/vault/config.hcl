ui           = true
api_addr     = "https://%ADDR%:8200"
cluster_addr = "https://%ADDR%:8201"

listener "tcp" {
  address       = "%ADDR%:8200"
  tls_cert_file = "/opt/vault/tls/vault.crt"
  tls_key_file  = "/opt/vault/tls/vault.key"
}
