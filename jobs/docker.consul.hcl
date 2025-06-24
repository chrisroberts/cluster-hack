job "docker-service" {
  type = "service"

  migrate {
    max_parallel     = 1
    health_check     = "checks"
    min_healthy_time = "15s"
    healthy_deadline = "5m"
  }

  group "docker-group" {
    count = 2

    network {
      port "http" {}
    }

    task "docker-task" {
      driver = "docker"

      logs {
        disabled      = true
        max_files     = 1
        max_file_size = 1
      }

      config {
        image = "hashicorp/http-echo:1.0.0"
        args  = ["-text", "ok", "-listen", ":${NOMAD_PORT_http}"]
        ports = ["http"]
      }

      resources {
        memory = 10
        cpu    = 5
      }

      service {
        name = "test-job"
        port = "http"
        check {
          name     = "http-ok"
          type     = "http"
          path     = "/"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
