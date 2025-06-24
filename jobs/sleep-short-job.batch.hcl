job "sleep-short-job" {
  type = "batch"

  group "sleeper" {
    count = 5

    restart {
      attempts = 3
      interval = "4m"
      delay    = "15s"
      mode     = "fail"
    }

    reschedule {
      attempts       = 3
      interval       = "5m"
      delay          = "30s"
      delay_function = "exponential"
      max_delay      = "120s"
      unlimited      = false
    }

    ephemeral_disk {
      size = 10
    }

    task "do_sleep" {
      driver = "raw_exec"

      logs {
        disabled      = true
        max_files     = 1
        max_file_size = 1
      }

      config {
        command = "sleep"
        args    = ["1s"]
      }

      resources {
        memory = 10
        cpu    = 5
      }
    }
  }
}
