job "countdash" {

  group "api" {
    count = 3

    network {
      mode = "bridge"
    }

    service {
      name = "count-api"
      port = "9001"

      check {
        type     = "http"
        path     = "/health"
        expose   = true
        interval = "3s"
        timeout  = "1s"

        check_restart {
          limit = 0
        }
      }

      connect {
        sidecar_service {
          proxy {
            transparent_proxy {}
          }
        }
      }
    }

    task "web" {
      driver = "docker"

      config {
        image          = "hashicorpdev/counter-api:v3"
        auth_soft_fail = true
      }
    }
  }

  group "dashboard" {
    count = 3

    network {
      mode = "bridge"

      port "http" {
        static = 9002
        to     = 9002
      }
    }

    service {
      name = "count-dashboard"
      port = "9002"

      check {
        type     = "http"
        path     = "/health"
        expose   = true
        interval = "3s"
        timeout  = "1s"

        check_restart {
          limit = 0
        }
      }

      connect {
        sidecar_service {
          proxy {
            transparent_proxy {}
          }
        }
      }
    }

    task "dashboard" {
      driver = "docker"

      env {
        COUNTING_SERVICE_URL = "http://count-api.virtual.consul"
      }

      config {
        image          = "hashicorpdev/counter-dashboard:v3"
        auth_soft_fail = true
      }
    }
  }
}
