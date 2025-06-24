job "sleep-periodic" {
  type = "batch"

  periodic {
    cron = "* * * * * *"
  }

  group "sleeper" {
    count = 5

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
