backend "raft" {
  retry_join {
    leader_api_addr         = "https://%ADDR%:8200"
    leader_client_cert_file = "/opt/vault/tls/vault.crt"
    leader_client_key_file  = "/opt/vault/tls/vault.key"
  }
}
