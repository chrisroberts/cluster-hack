client {
  enabled   = true
  alloc_dir = "/opt/nomad/alloc"
}

plugin "raw_exec" {
  config {
    enabled = true
  }
}
