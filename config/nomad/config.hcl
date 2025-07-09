datacenter           = "dc1"
bind_addr            = "0.0.0.0"
data_dir             = "/opt/nomad/data"
plugin_dir           = "/opt/nomad/plugins"
disable_update_check = true
leave_on_interrupt   = true
leave_on_terminate   = true
log_level            = "TRACE"
enable_syslog        = false
log_file             = "/var/log/nomad.log"

acl {
  enabled = true
}
