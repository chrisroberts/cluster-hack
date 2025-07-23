path "kv/data/{{identity.entity.aliases.%ACCESSOR%.metadata.nomad_namespace}}/{{identity.entity.aliases.%ACCESSOR%.metadata.nomad_job_id}}/*" {
  capabilities = ["read"]
}

path "kv/data/{{identity.entity.aliases.%ACCESSOR%.metadata.nomad_namespace}}/{{identity.entity.aliases.%ACCESSOR%.metadata.nomad_job_id}}" {
  capabilities = ["read"]
}

path "kv/metadata/{{identity.entity.aliases.%ACCESSOR%.metadata.nomad_namespace}}/*" {
  capabilities = ["list"]
}

path "kv/metadata/*" {
  capabilities = ["list"]
}
