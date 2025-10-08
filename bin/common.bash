#!/usr/bin/env bash
DIR_SHA="$(pwd | sha256sum)"
export DIR_SHA="${DIR_SHA:0:6}"
export CLUSTER_CACHER_INSTANCE="nomad-cluster-cacher"
export CLUSTER_INSTANCE_PREFIX="nomad-cluster-${DIR_SHA}-"
export CLUSTER_NETWORK="cluster-${DIR_SHA}"
export CLUSTER_NETWORK_IMPAIRMENTS=("slow" "very-slow" "lossy" "very-lossy" "slow-lossy" "very-slow-lossy")
export ENVRC_HEADER="### cluster header ###"
export PROFILE_NAME="cluster-hack"
export SCRIPT_NAME="$(basename "${0}")"
export CLUSTER_DATA_DIR="$(pwd)/.cluster-hack"
export INFO_DIR="${CLUSTER_DATA_DIR}/info"
export CLUSTER_VOLUME_POOL="default"
csource="${BASH_SOURCE[0]}"
while [ -h "${csource}" ] ; do csource="$(readlink "${csource}")"; done
bin_dir="$( cd -P "$( dirname "${csource}" )/" && pwd )" || exit 1
root_dir="$( cd -P "$( dirname "${bin_dir}" )/" && pwd )" || exit 1
export CLUSTER_ROOT="${root_dir}"

TEXT_CLEAR='\e[0m'
TEXT_BOLD='\e[1m'
TEXT_RED='\e[31m'
TEXT_GREEN='\e[32m'
TEXT_YELLOW='\e[33m'
TEXT_CYAN='\e[36m'
TEXT_BLUE='\e[34m'
TEXT_PURPLE='\e[35m'
TEXT_BROWN='\e[33m'
TEXT_GRAY='\e[37m'
TEXT_LIGHT_RED='\e[1;31m'
TEXT_LIGHT_GREEN='\e[1;32m'
TEXT_LIGHT_BLUE='\e[1;34m'
TEXT_LIGHT_PURPLE='\e[1;35m'
TEXT_LIGHT_CYAN='\e[1;36m'

HELPER_SCRIPTS=("config-scrub" "sed-helper" "stream-log")

# If in debug mode, print executed commands
if [ -n "${CLUSTER_DEBUG}" ]; then
    set -x
    export CLUSTER_DEBUG_OUTPUT="1"
fi

# Create an isolated network for the cluster
function create-cluster-network() {
    if is-cluster-network-enabled; then
        failure "Cannot create cluster network, already exists (%s)" "${CLUSTER_NETWORK}"
    fi

    incus network create "${CLUSTER_NETWORK}" > /dev/null ||
        failure "Failed to create cluster isolated network - %s" "${CLUSTER_NETWORK}"
    success "Created cluster isolated network - %s" "${CLUSTER_NETWORK}"
}

# Destroy isolated network for the cluster
function destroy-cluster-network() {
    if ! is-cluster-network-enabled; then
        return 0
    fi

    incus network delete "${CLUSTER_NETWORK}" > /dev/null ||
        failure "Failed to delete cluster isolated network - %s" "${CLUSTER_NETWORK}"
    success "Destroyed cluster isolated network - %s" "${CLUSTER_NETWORK}"
}

# Create a new cluster instance
#
# $1 - Name of instance
# $2 - "raw" (optional, will not configure instance)
function create-cluster-instance() {
    local name="${1?Name for instance required}"
    local raw="${2}"
    if [ -n "${raw}" ] && [ "${raw}" != "raw" ]; then
        failure "Unknown argument provided for instance creation - %s" "${raw}"
    fi

    if [ -z "${raw}" ] && [[ "${name}" != "${CLUSTER_INSTANCE_PREFIX}"* ]]; then
        name="${CLUSTER_INSTANCE_PREFIX}${name}"
    fi

    info "Launching cluster instance %s..." "${name}"

    if ! output="$(incus launch "${LAUNCH_ARGS[@]}" "${name}" 2>&1)"; then
        if [[ "${output}" == *"agent:config disk"* ]]; then
            detail "attaching agent config disk"
            incus config device add "${name}" agent disk source=agent:config > /dev/null ||
                failure "Error encountered adding agent disk during instance launch of %s" "${name}"
            incus start "${name}" > /dev/null ||
                failure "Error encountered launching cluster instance %s" "${name}"
            wait-for-instance "${name}" || exit

            detail "restarting instance to initialize agent"
            incus restart "${name}" > /dev/null ||
                failure "Error encountered restarting cluster instance %s" "${name}"
            wait-for-instance "${name}" || exit
        else
            failure "Error encountered launching cluster instance %s\n\nReason: %s" "${name}" "${output}"
        fi
    fi

    wait-for-instance "${name}" || exit

    if [ -z "${raw}" ]; then
        # The helper scripts will fail to execute from the /cluster
        # directory on vms, so just drop them directly in the instance
        incus exec "${name}" -- mkdir /helpers ||
            failure "Failed to create helpers directory on %s" "${name}"

        for helper in "${HELPER_SCRIPTS[@]}"; do
            incus exec "${name}" -- cp "/cluster/helpers/${helper}" "/helpers/${helper}" ||
                failure "Failed to copy %s to %s" "${helper}" "${name}"
        done

        install-bins "${name}"

        if is-cacher-enabled; then
            cacher-enable "${name}"
        fi

        if is-cluster-network-enabled; then
            use-network "${name}" "${CLUSTER_NETWORK}"
        fi
    fi

    run-hook "create-cluster-instance" "post" "${name}" || exit

    success "Launched new cluster instance %s" "${name}"
}

# Launch the global apt cacher
function launch-cluster-cacher-instance() {
    # Check first if the instance exists
    if is-cacher-enabled; then
        return
    fi

    info "Launching global cluster apt cacher..."
    create-cluster-instance "${CLUSTER_CACHER_INSTANCE}" "raw" || exit
    incus exec --env "DEBIAN_FRONTEND=noninteractive" "${CLUSTER_CACHER_INSTANCE}" -- apt-get install -yq apt-cacher-ng ||
        failure "Could not install apt-cacher-ng package on %s" "${CLUSTER_CACHER_INSTANCE}"

    # Force a check to clear the cached value
    is-cacher-enabled "force"

    success "Launched new global cluster apt cacher %s" "${CLUSTER_CACHER_INSTANCE}"
}

# Fully launch a nomad server instance
#
# $1 - Name of instance
# $2 - Expected count of servers
function launch-nomad-server-instance() {
    local name="${1?Name for server is required}"
    local count="${2?Count of servers required}"

    create-cluster-instance "${name}" || exit
    configure-nomad-server "${name}" "${count}" || exit
    if is-consul-enabled; then
        consul-enable "${name}" || exit
    else
        server-nomad-discovery "${name}" || exit
    fi
    start-service "${name}" "nomad"

    run-hook "launch-nomad-server-instance" "post" "${name}" || exit
}

# Fully launch a nomad client instance
#
# $1 - Name of instance
function launch-nomad-client-instance() {
    local name="${1?Name for client is required}"
    if [[ "${name}" != "${CLUSTER_INSTANCE_PREFIX}"* ]]; then
        name="${CLUSTER_INSTANCE_PREFIX}${name}"
    fi

    create-cluster-instance "${name}" || exit
    configure-nomad-client "${name}" || exit
    if is-consul-enabled; then
        consul-enable "${name}" || exit
    else
        client-nomad-discovery "${name}" || exit
    fi

    start-service "${name}" "nomad-client" || exit

    run-hook "launch-nomad-client-instance" "post" "${name}" || exit
}

# Fully launch a consul instance
#
# $1 - Name of instance
# $2 - Count of servers
function launch-consul-server-instance() {
    local name="${1?Name of server required}"
    local count="${2?Count of servers required}"

    create-cluster-instance "${name}" || exit
    configure-consul-server "${name}" "${count}" || exit

    run-hook "launch-consul-server-instance" "post" "${name}" || exit
}

# Fully launch a vault instance
#
# $1 - Name of instance
function launch-vault-server-instance() {
    local name="${1?Name of server required}"

    create-cluster-instance "${name}" || exit
    configure-vault-server "${name}" || exit

    run-hook "launch-vault-server-instance" "post" "${name}" || exit
}

# Configure an instance for nomad server
#
# $1 - Name of instance
# $2 - Number of server instances
function configure-nomad-server() {
    local name="${1?Name of server required}"
    local instance addr
    instance="$(name-to-instance "${name}")" || exit
    addr="$(get-instance-address "${instance}" "noverify")"
    local count="${2?Count of servers required}"

    run-hook "configure-nomad-server" "pre" "${instance}" || exit

    info "Adding base server nomad configuration (%s)..." "${instance}"
    incus exec "${instance}" -- mkdir -p /etc/nomad/config.d ||
        failure "Could not create nomad config directory on %s" "${instance}"
    incus exec "${instance}" -- /helpers/sed-helper "s/%ADDR%/${addr}/" \
        /cluster/config/nomad/config.hcl /etc/nomad/config.d/00-config.hcl ||
        failure "Could not install base nomad configuration on %s" "${instance}"
    incus exec "${instance}" -- /helpers/sed-helper "s/%NUM_SERVERS%/${count}/" \
        /cluster/config/nomad/server/config.hcl /etc/nomad/config.d/01-server.hcl ||
        failure "Could not modify nomad server configuration %s" "${instance}"

    if is-nomad-acl-enabled; then
        incus exec "${instance}" -- cp /cluster/config/nomad/acl.hcl /etc/nomad/config.d/01-acl.hcl ||
            failure "Could not install nomad acl configuration on %s" "${instance}"
    fi

    if is-vault-enabled ; then
        incus exec "${instance}" -- cp /cluster/config/nomad/server/vault.hcl /etc/nomad/config.d/01-vault.hcl ||
            failure "Could not install nomad vault configuration on %s" "${instance}"
    fi

    apply-user-configs "${instance}" "nomad" "server" || exit

    info "Installing nomad systemd unit file into %s" "${instance}"
    incus exec "${instance}" -- /helpers/sed-helper "s/%NOMAD_NAME%/nomad/" \
        /cluster/services/nomad.service /etc/systemd/system/nomad.service ||
        failure "Could not install nomad.service unit file into %s" "${instance}"

    run-hook "configure-nomad-server" "post" "${instance}" || exit

    success "Base server nomad configuration applied to %s" "${instance}"
}

# Configure an instance for consul server and start the service
#
# $1 - Name of instance
# $2 - Count of servers
function configure-consul-server() {
    local name="${1?Name of server required}"
    local count="${2?Count of servers required}"

    local addr local_addr
    if [[ "${name}" != "${CLUSTER_INSTANCE_PREFIX}"* ]]; then
        name="${CLUSTER_INSTANCE_PREFIX}${name}"
    fi

    # Don't set address on initial server when
    # creating the cluster
    if [[ "${name}" != *"consul0" ]]; then
        addr="$(consul-address "${name}")" || exit
    fi
    local_addr="$(get-instance-address "${name}" "noverify")"

    run-hook "configure-consul-server" "pre" "${instance}" || exit

    info "Adding base server consul configuration (%s)..." "${name}"
    gossip_key="$(consul-gossip-key)" || exit

    incus exec "${name}" -- mkdir -p /etc/consul/config.d ||
        failure "Could not create consul configuration directory on %s" "${name}"
    incus exec "${name}" -- /helpers/sed-helper "s/%NUM%/${count}/" \
        /cluster/config/consul/server/config.hcl /etc/consul/config.d/00-server.hcl ||
        failure "Could not install consul server configuration on %s" "${name}"
    incus exec "${name}" -- /helpers/sed-helper "s|%GOSSIP_KEY%|${gossip_key}|" \
        /cluster/config/consul/config.hcl /tmp/consul-gossip.hcl ||
        failure "Could not modify consul configuration on %s" "${name}"
    incus exec "${name}" -- /helpers/sed-helper "s/%LOCAL_ADDR%/${local_addr}/g" \
        /tmp/consul-gossip.hcl /tmp/consul.hcl ||
        failure "Could not modify consul local address configuration on %s" "${name}"
    incus exec "${name}" -- /helpers/sed-helper "s/%ADDR%/${addr}/" \
        /tmp/consul.hcl /etc/consul/config.d/01-consul.hcl ||
        failure "Could not modify consul join configuration on %s" "${name}"

    apply-user-configs "${instance}" "consul" "server" || exit

    info "Installing consul systemd unit file into %s" "${name}"
    incus exec "${name}" -- cp /cluster/services/consul.service /etc/systemd/system/consul.service ||
        failure "Could not install consul.service unit file into %s" "${name}"

    # Disable DNS on instance (consul will provide)
    incus exec "${name}" -- systemctl stop systemd-resolved > /dev/null 2>&1 ||
        failure "Unable to stop resolved on - %s" "${name}"
    incus exec "${name}" -- systemctl disable systemd-resolved > /dev/null 2>&1 ||
        failure "Unable to disabled resolved on - %s" "${name}"

    start-service "${name}" "consul" || exit

    run-hook "configure-consul-server" "post" "${instance}" || exit
}

# Configure an instance for vault server
#
# $1 - Name of instance
function configure-vault-server() {
    local name="${1?Name of server required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit

    run-hook "configure-vault-server" "pre" "${instance}" || exit

    info "Configuring vault server instance - %s" "${instance}"
    incus exec "${instance}" -- mkdir -p /opt/vault/data ||
        failure "Could not create data directory on %s" "${instance}"
    incus exec "${instance}" -- mkdir -p /opt/vault/tls ||
        failure "Could not create TLS directory on %s" "${instance}"
    incus exec "${instance}" -- mkdir -p /opt/vault/operator ||
        failure "Could not create operator directory on %s" "${instance}"
    incus exec "${instance}" -- mkdir -p /etc/vault/config.d ||
        failure "Could not create vault config directory on %s" "${instance}"

    # Copy in tls files unless it's the initial vault
    # instance since it will be initialized directly
    if [[ "${instance}" != *"vault0" ]]; then
        local dir vault addr
        vault="$(get-instance-of "vault")" || exit
        dir="$(mktemp -d)" || failure "Could not create temporary operator directory"

        incus file pull --recursive "${vault}/opt/vault/operator/" "${dir}" ||
            failure "Could not fetch operator files from %s" "${vault}"
        pushd "${dir}/operator" > /dev/null || failure "Could not move to %s" "${dir}"
        incus file push --recursive "." "${instance}/opt/vault/operator" ||
            failure "Could not add operator files to %s" "${instance}"
        popd > /dev/null || failure "Could not move back to original directory"
        rm -rf "${dir}"
        dir="$(mktemp -d)" || failure "Could not create temporary TLS directory"
        incus file pull --recursive "${vault}/opt/vault/tls/" "${dir}" ||
            failure "Could not fetch TLS files from %s" "${vault}"
        pushd "${dir}/tls" > /dev/null || failure "Could not move to %s" "${dir}"
        incus file push --recursive "." "${instance}/opt/vault/tls" ||
            failure "Could not add TLS files to %s" "${instance}"
        popd > /dev/null || failure "Could not move back to original directory"
        rm -rf "${dir}"

        incus exec "${instance}" -- chown -R root:root /opt/vault ||
            failure "Could not update vault directory ownership on %s" "${instance}"

        addr="$(get-instance-address "${vault}")" || exit
        incus exec "${instance}" -- /helpers/sed-helper "s/%ADDR%/${addr}/" \
            /cluster/config/vault/storage-join.hcl /etc/vault/config.d/10-storage-join.hcl ||
            failure "Could not add join configuration on %s" "${instance}"
    fi

    local addr
    addr="$(get-instance-address "${instance}" "noverify")" || exit
    incus exec "${instance}" -- /helpers/sed-helper "s/%ADDR%/${addr}/g" \
        /cluster/config/vault/config.hcl /etc/vault/config.d/00-config.hcl ||
        failure "Could not add base vault configuration on %s" "${instance}"
    incus exec "${instance}" -- /helpers/sed-helper "s/%NODE_ID%/${instance}/" \
        /cluster/config/vault/storage.hcl /etc/vault/config.d/01-storage.hcl ||
        failure "Could not add vault storage configuration on %s" "${instance}"

    apply-user-configs "${instance}" "vault" || exit

    if is-consul-enabled; then
        consul-enable "${instance}" || exit
    fi

    info "Installing vault systemd unit file into %s" "${instance}"
    incus exec "${instance}" -- cp /cluster/services/vault.service /etc/systemd/system/vault.service ||
        failure "Could not install vault.service unit file into %s" "${instance}"

    start-service "${instance}" "vault" || exit

    run-hook "configure-vault-server" "post" "${instance}" || exit
}

# Configure an instance for nomad client
#
# $1 - Name of instance
function configure-nomad-client() {
    local name="${1?Name of client required}"
    local instance addr
    instance="$(name-to-instance "${name}")" || exit
    addr="$(get-instance-address "${instance}" "noverify")" || exit

    run-hook "configure-nomad-client" "pre" "${instance}" || exit

    info "Configuring nomad client on - %s..." "${instance}"
    incus exec "${instance}" -- mkdir -p /etc/nomad/config.d ||
        failure "Could not create nomad config directory on %s" "${instance}"
    incus exec "${instance}" -- /helpers/sed-helper "s/%ADDR%/${addr}/" \
        /cluster/config/nomad/config.hcl /etc/nomad/config.d/00-config.hcl ||
        failure "Could not install base nomad configuration on %s" "${instance}"
    incus exec "${instance}" -- cp /cluster/config/nomad/client/config.hcl /etc/nomad/config.d/01-client.hcl ||
        failure "Could not install client nomad configuration on %s" "${instance}"
    if is-nomad-acl-enabled; then
        incus exec "${instance}" -- cp /cluster/config/nomad/acl.hcl /etc/nomad/config.d/01-acl.hcl ||
            failure "Could not install nomad acl configuration on %s" "${instance}"
    fi

    apply-user-configs "${instance}" "nomad" "client" || exit

    if is-vault-enabled ; then
        local addr="vault.service.consul"
        if ! is-consul-enabled; then
            local addr
            srv="$(get-instance-of "vault")" || exit
            addr="$(get-instance-address "${srv}")" || exit
        fi

        detail "Enabling vault integration on %s" "${instance}"
        incus exec "${instance}" -- /helpers/sed-helper "s/%ADDR%/${addr}/" \
            /cluster/config/nomad/client/vault.hcl /etc/nomad/config.d/01-vault.hcl ||
            failure "Could not install nomad vault configuration on %s" "${instance}"
    fi

    if is-nomad-cni-enabled; then
        install-cni-plugins "${instance}" || exit
    fi

    incus exec "${instance}" -- /helpers/sed-helper "s/%NOMAD_NAME%/nomad-client/" \
        /cluster/services/nomad.service /etc/systemd/system/nomad-client.service ||
        failure "Could not install nomad-client.service unit file into %s" "${instance}"

    success "Base client nomad configuration applied to %s" "${instance}"

    run-hook "configure-nomad-client" "post" "${instance}" || exit
}

# Initializes consul. Performs ACL bootstrap and
# any other initial setup tasks
#
# $1 - Name of the consul instance
function init-consul() {
    local name="${1?Name of consul instance required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit

    run-hook "init-consul" "pre" "${instance}" || exit

    info "Initializing consul..."
    local addr
    addr="$(get-instance-address "${instance}")" || exit
    export CONSUL_HTTP_ADDR="${addr}:8500"
    unset CONSUL_HTTP_TOKEN # NOTE: this might be set with old value via direnv

    local result secret_id count
    for (( count=0; count<10; count++ )); do
        if result="$(consul acl bootstrap -format=json)"; then
            break
        else
            result=""
        fi
        sleep 0.5
    done
    if [ -z "${result}" ]; then
        failure "Failed to execute consul ACL bootstrap on %s" "${instance}"
    fi
    debug "consul acl bootstrap result: %s" "${result}"
    secret_id="$(jq -r '.SecretID' <<< "${result}")"
    if [ -z "${secret_id}" ]; then
        failure "Failed to extract secret ID from consul ACL bootstrap on %s" "${instance}"
    fi
    store-value "consul-root-token" "${secret_id}" || exit

    export CONSUL_HTTP_TOKEN="${secret_id}"
    detail "consul ACL system bootstrapped"

    local policy_path="/tmp/.${DIR_SHA}-default-instances.hcl"
    sed "s/%ID%/${DIR_SHA}/" "${CLUSTER_ROOT}/extras/consul/policies/default-instances.hcl" > "${policy_path}" ||
        failure "Could not update consul ACL instances policy"
    consul acl policy create -name default-instances \
        -rules "@${policy_path}" > /dev/null ||
        failure "Could not create default consul ACL policy for instances"
    rm -f "${policy_path}"
    result="$(consul acl token create -description "Static default-instances" -format json -policy-name "default-instances")" ||
        failure "Failed to create a consul ACL token for instances"
    debug "consul acl policy instances create result: %s" "${result}"
    secret_id="$(jq -r '.SecretID' <<< "${result}")"
    if [ -z "${secret_id}" ] || [ "${secret_id}" == "null" ]; then
        failure "Failed to extract secret ID from consul ACL policy for instances"
    fi
    store-value "consul-instance-token" "${secret_id}" || exit

    local list
    readarray -t list < <(get-instances "consul")
    for instance in "${list[@]}"; do
        update-consul-token "${instance}" || exit
    done

    detail "consul ACL policy for instances created"

    run-hook "init-consul" "post" "${instance}" || exit
}

# Initializes nomad. This bootstraps
# the ACL system and any other initial
# setup tasks
#
# $1 - Name of the client instance
function init-nomad() {
    local name="${1?Name of client required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit

    run-hook "init-nomad" "pre" "${instance}" || exit

    info "Initializing nomad..."
    if is-nomad-acl-enabled; then
        local addr
        addr="$(get-instance-address "${instance}")" || exit
        unset NOMAD_TOKEN # NOTE: this might be set with old value via direnv
        export NOMAD_ADDR="http://${addr}:4646"

        local result secret_id
        result="$(nomad acl bootstrap -json)" ||
            failure "Failed to execute nomad ACL bootstrap on %s" "${instance}"
        debug "nomad acl bootstrap result: %s" "${result}"
        secret_id="$(jq -r '.SecretID' <<< "${result}")"
        if [ -z "${secret_id}" ] || [ "${secret_id}" == "null" ]; then
            failure "Failed to extract secret ID from nomad ACL bootstrap on %s" "${instance}"
        fi
        store-value "nomad-root-token" "${secret_id}" || exit

        export NOMAD_TOKEN="${secret_id}"

        detail "ACL system bootstrapped"

        nomad acl policy apply -description "anonymous policy" anonymous "${root_dir}/extras/nomad/policies/anonymous.hcl" > /dev/null ||
            failure "Could not apply anonymous ACL policy to nomad"

        detail "Anonymous ACL policy applied"

        if is-vault-enabled ; then
            local vaddr
            vaddr="$(vault-address)" || exit
            secret_id="$(get-value "vault-root-token")" || exit
            export VAULT_ADDR="https://${vaddr}:8200"
            export VAULT_TOKEN="${secret_id}"
            export VAULT_SKIP_VERIFY="true"

            detail "Enabling workload identity integration with vault"
            sed "s/%ADDR%/${addr}/" \
                "${root_dir}/extras/nomad/vault-workload-identities/vault-auth-method-jwt-nomad.json" > "/tmp/${DIR_SHA}-vault-auth.json" ||
                failure "Could not configure vault auth method file"

            vault auth enable -path "jwt-nomad" "jwt" > /dev/null ||
                failure "Could not enable vault jwt"
            vault write auth/jwt-nomad/config "@/tmp/${DIR_SHA}-vault-auth.json" > /dev/null ||
                failure "Could not write vault auth method"
            vault write auth/jwt-nomad/role/nomad-workloads \
                "@/${root_dir}/extras/nomad/vault-workload-identities/vault-role-nomad-workloads.json" > /dev/null ||
                failure "Could not write vault role for workloads"
            local accessor
            accessor="$(vault auth list -format=json | jq -r '.["jwt-nomad/"].accessor')"
            if [ -z "${accessor}" ]; then
                failure "Unable to extract accessor for jwt-nomad/ from vault"
            fi

            sed "s/%ACCESSOR%/${accessor}/" \
                "${root_dir}/extras/nomad/vault-workload-identities/vault-policy-nomad-workloads.hcl" > "/tmp/${DIR_SHA}-policy.hcl" ||
                failure "Could not configure vault policy document"
            vault policy write "nomad-workloads" "/tmp/${DIR_SHA}-policy.hcl" > /dev/null ||
                failure "Could not write vault policy for nomad"

            rm -f "/tmp/${DIR_SHA}"*

            detail "Enabling the vault nomad secret engine"
            vault secrets enable nomad > /dev/null ||
                failure "Could not enable vault nomad secret engine"
            vault write nomad/config/lease ttl=500 max_ttl=1000 > /dev/null ||
                failure "Could not configure vault nomad secret engine leases"
            local nomad_addr="${addr}"
            if is-consul-enabled; then
                nomad_addr="nomad.service.consul"
            fi
            vault write nomad/config/access address="http://${nomad_addr}:4646" token="${secret_id}" > /dev/null ||
                failure "Could not write nomad connection info to vault secret engine"
        fi

        if is-consul-enabled; then
            detail "Enabling workload identity integration with consul"
            # NOTE: This will setup the auth, acl binding rule, acl policy,
            # and acl role (for the default namespace)
            nomad setup consul -y -jwks-url "http://${addr}:4646/.well-known/jwks.json" > /dev/null ||
                failure "Failed to setup nomad workload integration with consul"
        fi
    fi

    success "Initialization of nomad complete"

    run-hook "init-nomad" "post" "${instance}" || exit
}

# Initializes the vault server. Runs the operator init
# storing the unseal key and root token. Then unseals
# the vault.
#
# $1 - Name of the instance
function init-vault-server() {
    local name="${1?Name of server required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit

    run-hook "init-vault-server" "pre" "${instance}" || exit

    info "Initializing vault server..."
    local addr
    addr="$(get-instance-address "${instance}")" || exit
    export VAULT_SKIP_VERIFY="true"
    export VAULT_ADDR="https://${addr}:8200"
    local available attempts
    for ((attempts=0; attempts < 10; attempts++)); do
        if incus exec "${instance}" -- nc -z -w1 "${addr}" "8200" > /dev/null 2>&1; then
            available="1"
            break
        fi
        sleep 0.1
    done

    if [ -z "${available}" ]; then
        failure "Vault instance is not currently listening on %s" "${instance}"
    fi

    result="$(vault operator init -format=json -key-shares=1 -key-threshold=1)" ||
        failure "Failed to run vault initialization on %s" "${instance}"
    debug "vault operator init result: %s" "${result}"
    root_token="$(jq -r '.root_token' <<< "${result}")" ||
        failure "Unable to extract root token on %s" "${instance}"
    unseal_key="$(jq -r '.unseal_keys_hex[]' <<< "${result}")" ||
        failure "Unable to extract unseal key on %s" "${instance}"

    store-value "vault-root-token" "${root_token}" || exit
    store-value "vault-unseal-key" "${unseal_key}" || exit
    export VAULT_TOKEN="${root_token}"

    vault operator unseal "${unseal_key}" > /dev/null ||
        failure "Failed to unseal vault on %s" "${instance}"

    # Wait for vault to be ready
    local result
    for (( i=0; i < 10; i++ )); do
        result="$(vault status -format json)"
        if [ "$(jq -r '.sealed' <<< "${result}")" == "false" ] && [ "$(jq -r '.ha_mode' <<< "${result}")" == "active" ]; then
            break
        fi
        sleep 0.5
    done

    detail "Enabling vault kv secret engine"
    vault secrets enable -version "2" "kv" > /dev/null ||
        failure "Could not enable the vault kv secret engine"

    if is-consul-enabled; then
        detail "Enabling vault consul secret engine"
        vault secrets enable consul > /dev/null ||
            failure "Could not enable the vault consul secret engine"
        export CONSUL_HTTP_ADDR="${addr}:8500"
        CONSUL_HTTP_TOKEN="$(get-value "consul-root-token")" || exit
        export CONSUL_HTTP_TOKEN

        result="$(consul acl token create -policy-name "global-management" -format json)" ||
            failure "Could not create consul token for vault integration"
        debug "consul acl token create for global-management result: %s" "${result}"
        local token
        token="$(jq -r '.SecretID' <<< "${result}")"
        if [ -z "${token}" ] || [ "${token}" == "null" ]; then
            failure "Could not extract consul token for vault integration"
        fi
        vault write consul/config/access address="127.0.0.1:8500" token="${token}" > /dev/null ||
            failure "Could not write consul access information for vault integration"
        vault write consul/roles/default-instances policies=default-instances > /dev/null ||
            failure "Could not create vault role for consul default-instances policy"

        # Update the consul token with a generated token
        local agent_token
        agent_token="$(consul-instance-token)" || exit
        incus exec "${instance}" -- /helpers/sed-helper "s/%TOKEN%/${agent_token}/" /cluster/config/vault/consul.hcl /etc/vault/config.d/01-consul.hcl ||
            failure "Could not install vault consul configuration on %s" "${instance}"

        # Reload vault to pick up new token
        incus exec "${instance}" -- systemctl reload vault > /dev/null ||
            failure "Could not reload the vault server process on - %s" "${instance}"

        update-consul-token "${instance}" || exit
    fi

    success "Vault server initialized and ready"

    run-hook "init-vault-server" "post" "${instance}" || exit
}

# Initialize the vault server instance. Currently
# this means generating the TLS cert/key. Only needs
# to be run on the initial vault instance.
#
# $1 - Name of instance
function vault-preinit() {
    local name="${1?Name of server required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit

    run-hook "vault-preinit" "pre" "${instance}" || exit

    info "Initializing instance for vault..."
    incus exec --env "DEBIAN_FRONTEND=noninteractive" "${instance}" -- apt-get update > /dev/null ||
        failure "Could not update apt on %s" "${instance}"
    incus exec --env "DEBIAN_FRONTEND=noninteractive" "${instance}" -- apt-get install -qy openssl > /dev/null ||
        failure "Could not install openssl on %s" "${instance}"
    incus exec "${instance}" -- mkdir -p /opt/vault/tls ||
        failure "Could not create TLS directory on %s" "${instance}"
    incus exec "${instance}" -- openssl req -out /opt/vault/tls/vault.crt \
        -new -keyout /opt/vault/tls/vault.key -newkey rsa:4096 -nodes \
        -sha256 -x509 -subj "/O=HashiCorp/CN=Vault" -days 365 > /dev/null 2>&1 ||
        failure "Failed to generate vault TLS key/cert files on %s" "${instance}"
    success "Vault instance initialization complete"

    run-hook "vault-preinit" "post" "${instance}" || exit
}

# Generate and store consul encryption key. This
# should only be done on the initial server instance.
function consul-preinit() {
    local instance key
    instance="$(get-instance-of "consul")" || exit

    run-hook "consul-preinit" "pre" "${instance}" || exit

    key="$(incus exec "${instance}" -- /nomad/bin/consul keygen)" ||
        failure "Unable to generate nomad gossip key"
    store-value "consul-gossip-key" "${key}" || exit

    success "Consul initialized for use"

    run-hook "consul-preinit" "post" "${instance}" || exit
}

# Update the consul agent token on an instance
#
# $1 - Name of instance
function update-consul-token() {
    local name="${1?Name of instance required}"
    local instance agent_token
    instance="$(name-to-instance "${name}")" || exit
    agent_token="$(consul-instance-token)" || exit

    incus exec "${instance}" -- /helpers/sed-helper "s/%TOKEN%/${agent_token}/" /cluster/config/consul/client/config.hcl /etc/consul/config.d/01-agent.hcl ||
        failure "Could not install consul agent configuration on %s" "${instance}"
    incus exec "${instance}" -- systemctl reload consul > /dev/null ||
        failure "Could not reload consul service on - %s" "${instance}"
}

# Configure nomad server with nomad based discovery
#
# $1 - Name of instance
function server-nomad-discovery() {
    local name="${1?Name of server required}"
    local instance srv
    instance="$(name-to-instance "${name}")" || exit
    srv="$(get-instance-of "server" "${instance}" )" || exit
    local addr
    addr="$(get-instance-address "${srv}")" || exit

    info "Enabling nomad server discovery on %s" "${instance}"

    incus exec "${instance}" -- /helpers/sed-helper "s/%ADDR%/${addr}/" \
        /cluster/config/nomad/server/server_join.hcl /etc/nomad/config.d/01-join.hcl ||
        failure "Could not install nomad discovery configuration into %s" "${instance}"

    success "Enabled nomad server discovery on %s" "${instance}"
}

# Configure client for nomad based discovery
#
# $1 - Name of instance
function client-nomad-discovery() {
    local name="${1?Name of server required}"
    local instance srv
    instance="$(name-to-instance "${name}")" || exit
    srv="$(get-instance-of "server")" || exit
    local addr
    addr="$(get-instance-address "${srv}")" || exit

    incus exec "${instance}" -- /helpers/sed-helper "s/%ADDR%/${addr}/" \
        /cluster/config/nomad/client/server_join.hcl /etc/nomad/config.d/01-join.hcl ||
        failure "Could not install nomad discovery configuration into %s" "${instance}"

    success "Enabled nomad server discovery on %s" "${instance}"
}

# Enable consul client on instance.
#
# $1 - Name of instance
function consul-enable() {
    local name="${1?Name of instance required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit
    local addr local_addr
    addr="$(consul-address "${instance}" "noverify")" || exit
    local_addr="$(get-instance-address "${instance}")" || exit
    local gossip_key
    gossip_key="$(consul-gossip-key)" || exit

    detail "enabling consul on %s" "${instance}"

    # Install and configure a consul client
    incus exec "${instance}" -- mkdir -p /etc/consul/config.d ||
        failure "Could not create consul agent configuration directory on %s" "${instance}"
    incus exec "${instance}" -- /helpers/sed-helper "s|%GOSSIP_KEY%|${gossip_key}|" /cluster/config/consul/config.hcl /tmp/consul-gossip.hcl ||
        failure "Could not modify consul configuration on %s" "${instance}"
    incus exec "${instance}" -- /helpers/sed-helper "s/%LOCAL_ADDR%/${local_addr}/g" \
        /tmp/consul-gossip.hcl /tmp/consul.hcl ||
        failure "Could not modify consul local address configuration on %s" "${instance}"
    incus exec "${instance}" -- /helpers/sed-helper "s/%ADDR%/${addr}/" /tmp/consul.hcl /etc/consul/config.d/01-consul.hcl ||
        failure "Could not modify consul join configuration on %s" "${instance}"
    apply-user-configs "${instance}" "consul" "client" || exit

    # Add consul configuration to nomad
    if [[ "${instance}" == *"client"* ]] || [[ "${instance}" == *"server"* ]]; then
        # Install the cni plugins
        if [[ "${instance}" == *"client"* ]]; then
            install-cni-plugins "${instance}" || exit
        fi

        local agent_token
        agent_token="$(consul-instance-token)" || exit
        incus exec "${instance}" -- /helpers/sed-helper "s/%TOKEN%/${agent_token}/" /cluster/config/nomad/consul.hcl /etc/nomad/config.d/01-consul.hcl ||
            failure "Could not install nomad consul configuration on %s" "${instance}"
    fi

    local agent_token
    # Add consul configuration to vault
    if [[ "${instance}" == *"vault"* ]]; then
        agent_token="$(consul-instance-token "static")" || exit
        incus exec "${instance}" -- /helpers/sed-helper "s/%TOKEN%/${agent_token}/" /cluster/config/vault/consul.hcl /etc/vault/config.d/01-consul.hcl ||
            failure "Could not install vault consul configuration on %s" "${instance}"
    else
        agent_token="$(consul-instance-token)" || exit
    fi
    incus exec "${instance}" -- /helpers/sed-helper "s/%TOKEN%/${agent_token}/" /cluster/config/consul/client/config.hcl /etc/consul/config.d/01-agent.hcl ||
        failure "Could not install consul agent configuration on %s" "${instance}"

    incus exec "${instance}" -- cp /cluster/services/consul.service /etc/systemd/system/consul.service ||
        failure "Could not install consul.service unit file into %s" "${instance}"

    # Disable DNS on instance (consul will provide)
    incus exec "${instance}" -- systemctl stop systemd-resolved > /dev/null 2>&1 ||
        failure "Unable to stop resolved on - %s" "${instance}"
    incus exec "${instance}" -- systemctl disable systemd-resolved > /dev/null 2>&1 ||
        failure "Unable to disabled resolved on - %s" "${instance}"

    start-service "${instance}" "consul"
}

# Enable apt cacher on instance
#
# $1 - Name of instance
function cacher-enable() {
    local name="${1?Name of instance required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit
    local addr
    addr="$(cacher-address)" || exit

    detail "enabling apt cacher on %s" "${instance}"
    local output
    if ! output="$(incus exec "${instance}" -- sh -c "echo 'Acquire::http { Proxy \"http://${addr}:3142\"; }' > /etc/apt/apt.conf.d/99proxy" 2>&1)"; then
        warn "Could not enable apt cacher on %s" "${instance}"
        warn "Reason: %s" "${output}"
    fi
}

# Pause an instance
#
# $1 - Name of instance
function pause-instance() {
    local name="${1?Name of instance is required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit

    local status
    status="$(status-instance "${instance}")" || exit

    if [ "${status}" != "running" ]; then
        failure "Cannot pause %s in current state (%s)" "${instance}" "${status}"
    fi

    run-hook "pause-instance" "pre" "${instance}" || exit

    info "Pausing instance %s" "${instance}"
    incus pause "${instance}" ||
        failure "Unable to pause %s" "${instance}"

    run-hook "pause-instance" "post" "${instance}" || exit
}

# Resume an instance
#
# $1 - Name of instance
function resume-instance() {
    local name="${1?Name of instance is required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit

    local status
    status="$(status-instance "${instance}")" || exit

    if [ "${status}" != "frozen" ]; then
        failure "Cannot resume %s in current state (%s)" "${instance}" "${status}"
    fi

    run-hook "resume-instance" "pre" "${instance}" || exit

    info "Resuming instance %s" "${instance}"
    incus resume "${instance}" ||
        failure "Unable to pause %s" "${instance}"
    success "Instance has been resumed %s" "${instance}"

    run-hook "resume-instance" "post" "${instance}" || exit
}

# Delete an instance
#
# $1 - Name of instance
function delete-instance() {
    local name="${1?Name is required}"
    local raw="${2}"
    if [ -n "${raw}" ] && [ "${raw}" != "raw" ]; then
        failure "Unknown argument provided for instance deletion - %s" "${raw}"
    fi

    local instance="${name}"
    if [ -z "${raw}" ]; then
        instance="$(name-to-instance "${name}")" || exit
    fi

    run-hook "delete-instance" "pre" "${instance}" || exit

    info "Destroying nomad cluster instance %s" "${instance}"
    incus delete "${instance}" --force ||
        failure "Unable to delete instance %s" "${instance}"

    delete-instance-volumes "${instance}" || exit

    success "Nomad cluster instance destroyed %s" "${instance}"

    run-hook "delete-instance" "post" "${instance}" || exit
}

# Delete any custom volumes that were built and attached
# to the instance (based on naming)
#
# $1 - Name of instance (full name required)
function delete-instance-volumes() {
    local name="${1?Name is required}"
    local volumes vol deletes list

    volumes="$(incus storage volume list "${CLUSTER_VOLUME_POOL}" --format json)" ||
        failure "Failed to list storage volumes within %s pool" "${CLUSTER_VOLUME_POOL}"

    query="$(printf '.[] | select(.name | startswith("%s")) | select(.content_type == "block") | .name' "${name}")"
    deletes="$(jq -r "${query}" <<< "${volumes}")"
    if [ -n "${deletes}" ]; then
        readarray -t list <<< "${deletes}"
        for vol in "${list[@]}"; do
            detail "deleting block volume - %s" "${vol}"
            incus storage volume delete "${CLUSTER_VOLUME_POOL}" "${vol}" > /dev/null 2>&1 ||
                failure "Failed to delete volume %s from pool %s" "${vol}" "${CLUSTER_VOLUME_POOL}"
        done
    fi
}

# Connect to an instance
#
# $1 - Name of instance
function connect-instance() {
    local name="${1?Name is required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit

    run-hook "connect-instance" "pre" "${instance}" || exit

    info "Connecting to %s..." "${instance}"
    incus exec "${instance}" bash

    run-hook "connect-instance" "post" "${instance}" || exit
}

# Stream nomad logs from instance
#
# $1 - Name of instance
# $2 - Optional service name
function stream-logs() {
    local name="${1?Name is required}"
    local instance status
    instance="$(name-to-instance "${name}")" || exit
    local service_name="${2}"

    status="$(status-instance "${instance}")" || exit

    # If the instance is not currently running, nothing to do
    if [ "${status}" != "running" ]; then
        return
    fi

    if [ -z "${service_name}" ]; then
        case "${instance}" in
            *"server"*) service_name="nomad" ;;
            *"client"*) service_name="nomad-client" ;;
            *"consul"*) service_name="consul" ;;
            *"vault"*) service_name="vault" ;;
        esac
    fi

    incus exec "${instance}" -- /helpers/stream-log "${service_name}" &
}

# Restart nomad process. If client, will check
# after restart and mark node as eligible if
# ineligible after restart.
#
# $@ - Names of instances
function restart-nomad() {
    local name nid instance
    local names=()
    local nids=()

    # Grab all the node ids up front. This prevents
    # issues if we restart the client that we are
    # configured to use.
    for name in "${@}"; do
        instance="$(name-to-instance "${name}")" || exit
        names+=("${instance}")
        # Only lookup node ids for clients
        if [[ "${instance}" == *"client"* ]]; then
            # If the lookup fails, just continue. The error will
            # be printed so the issue is known, but the service
            # restart will still be executed
            nids+=("$(name-to-node "${instance}")") || continue
        fi

        run-hook "restart-nomad" "pre" "${instance}" || exit
    done

    # Install bins in case they have changed
    local pids=()
    for instance in "${names[@]}"; do
        install-bins "${instance}" &
        pids+=("${!}")
    done

    local pid
    for pid in "${pids[@]}"; do
        wait "${pid}" || exit
    done

    # Trigger restarts
    local service_name
    local pids=()
    for (( i=0; i < "${#names[@]}"; i++ )); do
        instance="${names[$i]}"
        info "Restarting nomad on %s" "${instance}"
        if [[ "${instance}" == *"client"* ]]; then
            service_name="nomad-client"
        else
            service_name="nomad"
        fi
        incus exec "${instance}" -- systemctl restart "${service_name}" &
        pids+=("${!}")
    done

    # Wait for restarts to complete
    local pid
    for (( i=0; i < "${#names[@]}"; i++ )); do
        instance="${names[$i]}"
        pid="${pids[$i]}"
        wait "${pid}" ||
            failure "Unexpected error encountered during nomad restart on %s" "${instance}"
        success "Nomad restarted %s" "${instance}"
    done

    # Check for any clients marked as ineligible
    # and update them to eligible
    local eligibility
    for (( i=0; i < "${#names[@]}"; i++ )); do
        instance="${names[$i]}"
        if [[ "${instance}" != *"client"* ]]; then
            run-hook "restart-nomad" "post" "${instance}" || exit

            continue
        fi

        nid="${nids[$i]}"
        if [ -z "${nid}" ]; then
            run-hook "restart-nomad" "post" "${instance}" || exit

            continue
        fi

        while [ "${eligibility}" == "" ]; do
            eligibility="$(nomad node status -json "${nid}" | jq -r '.SchedulingEligibility')"
            sleep 0.1
        done
        if [ "${eligibility}" == "ineligible" ]; then
            info "Marking nomad client %s (%s) as eligible..." "${instance}" "${nid}"

            nomad node eligibility -enable "${nid}" > /dev/null ||
                failure "Unable to mark node %s as eligible" "${nid}"
        fi

        run-hook "restart-nomad" "post" "${instance}" || exit
    done
}

# Reconfigure nomad on an instance
#
# $1 - Name of instance
function reconfigure-nomad() {
    local name="${1?Name is required}"
    local instance service_name
    instance="$(name-to-instance "${name}")" || exit

    run-hook "reconfigure-nomad" "pre" "${instance}" || exit

    info "Reconfiguring nomad on %s" "${instance}"

    # Start with deleting any existing custom configs
    incus exec "${instance}" -- /helpers/config-scrub "nomad" ||
        failure "Unable to remove existing nomad configuration on %s" "${instance}"

    if [[ "${instance}" == *"client"* ]]; then
        apply-user-configs "${instance}" "nomad" "client" || exit
        service_name="nomad-client"
    else
        apply-user-configs "${instance}" "nomad" "server" || exit
        service_name="nomad"
    fi

    # Reinstall bins in case they have changed
    install-bins "${name}" || exit
    incus exec "${instance}" -- systemctl reload "${service_name}" ||
        failure "Unexpected error during nomad reload"

    success "Reconfigured nomad on %s" "${instance}"

    run-hook "reconfigure-nomad" "post" "${instance}" || exit
}

# Run a command on an instance
#
# $1 - Name of instance
# $@ - Comand to run
function run-command() {
    local name="${1?Name is required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit
    local i=$(( ${#} - 1 ))
    local cmd=("${@:2:$i}")

    info "Executing on %s - '%s'" "${instance}" "${cmd[*]}"
    incus exec "${instance}" -- "${cmd[@]}"
}

# Download (and cache) the latest version of the CNI
# plugins for the host architecture and install the
# plugins into instance
#
# $1 - Name of instance
function install-cni-plugins() {
    local name="${1?Name of instance required}"
    local instance arch
    instance="$(name-to-instance "${name}")" || exit
    arch="$([ "$(uname -m)" == "x86_64" ] && printf "amd64" || printf "arm64")"
    local cache_path="/tmp/cluster-cni-plugins-cache.tgz"
    local consul_cache_path="/tmp/cluster-consul-cni-cache.zip"

    install-package "${instance}" "tar" "zip" || exit

    # NOTE: Use file locking to provide a simple mutex
    # so only files are only downloaded once
    {
        flock 100
        detail "Installing CNI plugins on - %s" "${instance}"
        if [ ! -f "${cache_path}" ]; then
            local download_url pattern tmp
            tmp="$(mktemp)" || failure "Could not create temporary file"
            pattern="$(printf '.assets[] | select(.name | contains("linux")) | select(.name | contains("%s")) | select(.name | endswith("tgz")) | .browser_download_url' "${arch}")"
            download_url="$(curl -Sslf https://api.github.com/repos/containernetworking/plugins/releases/latest | jq -r "${pattern}")"
            detail "Downloading from: %s" "${download_url}"
            if [ -z "${download_url}" ]; then
                failure "Could not locate CNI plugins download URL"
            fi
            curl -SsLf -o "${tmp}" "${download_url}" ||
                failure "Unable to download CNI plugins from - %s" "${download_url}"
            mv "${tmp}" "${cache_path}" ||
                failure "Could not write CNI plugin download cache on - %s" "${instance}"
        fi

        if [ ! -f "${consul_cache_path}" ]; then
            local download_url pattern tmp
            tmp="$(mktemp)" || failure "Could not create temporary file"
            pattern="$(printf '.builds[] | select(.url | contains("linux")) | select(.url | contains("%s")) | select(.url | endswith(".zip")) | .url' "${arch}")"
            download_url="$(curl -Sslf https://api.releases.hashicorp.com/v1/releases/consul-cni/latest | jq -r "${pattern}")"
            if [ -z "${download_url}" ]; then
                failure "Could not locate consul CNI plugins download URL"
            fi
            curl -SsLf -o "${tmp}" "${download_url}" ||
                failure "Unable to download consul CNI plugins from - %s" "${download_url}"
            mv "${tmp}" "${consul_cache_path}" ||
                failure "Could not write nomad consul CNI plugin download cache on - %s" "${instance}"
        fi
    } 100>/tmp/.cluster-cni-download-lock

    incus file push "${cache_path}" "${instance}/tmp/cni-plugins.tgz" > /dev/null ||
        failure "Could not upload CNI plugins to instance - %s" "${instance}"
    incus exec "${instance}" -- mkdir -p /opt/cni/bin ||
        failure "Could not create CNI bin directory"
    incus exec "${instance}" -- tar --one-top-level=/opt/cni/bin -xzf /tmp/cni-plugins.tgz > /dev/null ||
        failure "Could not unpack CNI plugins to bin directory"
    incus file push "${consul_cache_path}" "${instance}/tmp/consul-plugin.zip" > /dev/null ||
        failure "Could not upload nomad consul CNI plugin to instance - %s" "${instance}"
    incus exec "${instance}" -- unzip /tmp/consul-plugin.zip -d /opt/cni/bin > /dev/null ||
        failure "Could not unpack nomad consul CNI plugin on instance -%s" "${instance}"

    # Check that bridge module is available, load if not
    if ! grep "bridge " /proc/modules > /dev/null; then
        warn "Bridge kernel module not found, loading on - %s" "${instance}"
        incus exec "${instance}" -- modprobe bridge ||
            failure "Could not load bridge kernel module on - %s" "${instance}"
    fi
}

function install-package() {
    local name="${1?Instance name is required}"
    local i=$(( ${#} - 1 ))
    local pkgs=("${@:2:$i}")
    local instance
    instance="$(name-to-instance "${name}")" || exit

    # NOTE: Wrap this and send to bash since 'command' gets picked up as a keyword
    if incus exec "${instance}" -- bash -c "command -v apt-get > /dev/null 2>&1"; then
        incus exec --env "DEBIAN_FRONTEND=noninteractive" "${instance}" -- apt-get install -yq "${pkgs[@]}" > /dev/null 2>&1 ||
            failure "Failed to install packages via apt: %s" "${pkgs[*]}"
    else
        incus exec "${instance}" -- dnf install -yq "${pkgs[@]}" > /dev/null 2>&1 ||
            failure "Failed to install packages via dnf: %s" "${pkgs[*]}"
    fi
}

# Gets a consul token for instances. This
# will be the static consul token if vault
# is not enabled or a generated consul token
# if vault is enabled
#
# $1 - Force using static consul token
function consul-instance-token() {
    local force_consul_token="${1}"
    if [ -z "${force_consul_token}" ] && is-vault-enabled; then
        local result token
        result="$(vault read -format json consul/creds/default-instances)"
        token="$(jq -r '.data.token' <<< "${result}")"
        if [ -z "${token}" ] || [ "${token}" == "null" ]; then
            failure "Could not generate consul default instance token from vault\n%s" "${result}"
        fi
        printf "%s" "${token}"
    else
        get-value "consul-instance-token"
    fi
}

# Get the consul gossip key. This will always be
# stored on the initial server instance.
function consul-gossip-key() {
    get-value "consul-gossip-key"
}

# Get the address for vault
function vault-address() {
    local instance addr
    instance="$(get-instance-of "vault")" || exit
    addr="$(get-instance-address "${instance}")" || exit

    printf "%s" "${addr}"
}

# Get the address of the consul server. This is always
# just the first created consul server.
#
# $1 - Name of instance to exclude (optional)
function consul-address() {
    local address instance
    instance="$(get-instance-of "consul" "${1}")" || exit
    address="$(get-instance-address "${instance}")" || exit
    printf "%s" "${address}"
}

# Get the address of the global apt cacher
function cacher-address() {
    local address
    address="$(incus list "${CLUSTER_CACHER_INSTANCE}" --format json | jq -r '.[].state.network.[] | select(.type == "broadcast") | .addresses[] | select(.family == "inet") | .address')" ||
        failure "Could not get address for global cluster cacher"
    printf "%s" "${address}"
}

# Check if the cluster isolated network is enabled (exists)
function is-cluster-network-enabled() {
    incus network info "${CLUSTER_NETWORK}" > /dev/null 2>&1
}

# Check if the global apt cacher exists
#
# $1 - Force check if set
function is-cacher-enabled() {
    if [ -n "${__MEMO_CACHER_ENABLED}" ] && [ -n "${1}" ]; then
        return "${__MEMO_CACHER_ENABLED}"
    fi

    if incus info "${CLUSTER_CACHER_INSTANCE}" > /dev/null 2>&1; then
        __MEMO_CACHER_ENABLED="0"
        return 0
    fi

    __MEMO_CACHER_ENABLED="1"
    return 1
}

# Checks if vault is enabled
#
# $1 - Force check if set
function is-vault-enabled() {
    if [ -n "${__MEMO_VAULT_ENABLED}" ] && [ -n "${1}" ]; then
        return "${__MEMO_VAULT_ENABLED}"
    fi

    if [ -z "$(get-instances "vault")" ]; then
        __MEMO_VAULT_ENABLED="1"
        return 1
    fi

    __MEMO_VAULT_ENABLED="0"
    return 0
}

# Checks if consul is enabled in the cluster
#
# $1 - Force check if set
function is-consul-enabled() {
    if [ -n "${__MEMO_CONSUL_ENABLED}" ] && [ -n "${1}" ]; then
        return "${__MEMO_CONSUL_ENABLED}"
    fi

    if [ -z "$(get-instances "consul")" ]; then
        __MEMO_CONSUL_ENABLED="1"
        return 1
    fi

    __MEMO_CONSUL_ENABLED="0"
    return 0
}

# Check if nomad acls are enabled in the cluster
#
# $1 - Force check if set
function is-nomad-acl-enabled() {
    if [ -n "${__MEMO_ACL_ENABLED}" ] && [ -n "${1}" ]; then
        return "${__MEMO_ACL_ENABLED}"
    fi

    local val
    val="$(get-value "nomad-acls")"
    if [ "${val}" == "enabled" ]; then
        __MEMO_ACL_ENABLED="0"
        return 0
    fi

    __MEMO_ACL_ENABLED="1"
    return 1
}

# Check is cni plugin installation is enabled in cluster
#
# $1 - Force check if set
function is-nomad-cni-enabled() {
    if [ -n "${__MEMO_CNI_ENABLED}" ] && [ -n "${1}" ]; then
        return "${__MEMO_CNI_ENABLED}"
    fi

    local val
    val="$(get-value "nomad-cni")"
    if [ "${val}" == "enabled" ]; then
        __MEMO_CNI_ENABLED="0"
        return 0
    fi

    __MEMO_CNI_ENABLED="1"
    return 1
}

# Get status of an instance
#
# $1 - Name of instance
function status-instance() {
    local name="${1?Name is required}"
    instance="$(name-to-instance "${name}")" || exit

    local info
    info="$(incus list "${instance}" --format json)" ||
        failure "Could not get info for %s" "${instance}"
    info="$(jq -r '.[].status' <<< "${info}")" ||
        failure "Could not process info for %s" "${instance}"
    if [ -z "${info}" ]; then
        failre "Could not get status for instance %s" "${instance}"
    fi

    info="$(awk '{print tolower($0)}' <<< "${info}")" ||
        failure "Could not format status for instance %s" "${instance}"

    printf "%s" "${info}"
}

# Retuns formatted status of instance
#
# $1 - Name of instance
function get-instance-display-status() {
    local name="${1?name of instance required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit
    case "$(status-instance "${instance}")" in
        "running") printf "%brunning%b" "${TEXT_GREEN}" "${TEXT_CLEAR}" ;;
        "stopped") printf "%bstopped%b" "${TEXT_RED}" "${TEXT_CLEAR}" ;;
        "frozen") printf "%bpaused%b" "${TEXT_YELLOW}" "${TEXT_CLEAR}" ;;
        *) printf "unknown" ;;
    esac
}

# Apply user defined configurations for service
#
# $1 - Name of instance
# $2 - Service name (nomad, consul, vault)
# $3 - Service type (client, server)
function apply-user-configs() {
    local name="${1?Name of instance required}"
    local service="${2?Name of service required}"
    local type="${3}"
    local local_path="./cluster/config/${service}"

    files=("${local_path}"/*.hcl)
    if [ ! -f "${files[0]}" ]; then
        files=()
    fi
    if [ -n "${type}" ]; then
        typed_files=("${local_path}/${type}"/*.hcl)
        if [ -f "${typed_files[0]}" ]; then
            files+=("${typed_files[@]}")
        fi
    fi
    if [ "${#files[@]}" -lt "1" ]; then
        return
    fi

    info "Installing custom %s configuration files on %s..." "${service}" "${instance}"
    local cfg
    for cfg in "${files[@]}"; do
        slim_name="$(basename "${cfg}")"
        detail "adding config file - %s to %s" "${cfg}" "${instance}"
        incus file push "${cfg}" "${instance}/etc/${service}/config.d/99-${slim_name}" > /dev/null ||
            failure "Error pushing %s configuration file (%s) into %s" "${service}" "${slim_name}" "${instance}"
    done
}

# Enable and start service on instance
#
# $1 - Name of instance
# $2 - Name of service
function start-service() {
    local name="${1?Name of instance is required}"
    local service="${2?Name of service is required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit

    info "Starting service %s on %s..." "${service}" "${instance}"
    if ! incus exec "${instance}" -- systemctl unmask "${service}"; then
        warn "Retrying service unmasking..."
        sleep 0.1
        incus exec "${instance}" -- systemctl unmask "${service}" > /dev/null 2>&1 ||
        failure "Unable to unmask systemd service %s on %s" "${service}" "${instance}"
    fi
    incus exec "${instance}" -- systemctl enable --now "${service}" > /dev/null 2>&1 ||
        failure "Unable to start systemd service %s on %s" "${service}" "${instance}"

    success "Service %s has been started on %s" "${service}" "${instance}"
}

# Install files from the nomad bin directory
# into the instance
#
# NOTE: If the instance is a VM the files will
# be copied since executable files cannot be
# called directly on the shared mount. If the
# instance is a container, the files will just
# be linked (which is much faster).
#
# $1 - Name of instance
function install-bins() {
    local name="${1?Name of server required}"
    local instance link
    instance="$(name-to-instance "${name}")" || exit
    if is-instance-container "${instance}"; then
        link="link"
    fi

    run-hook "install-bins" "pre" "${instance}" || exit

    detail "installing binaries on %s" "${instance}"

    # scrub the directory before populating
    incus exec "${instance}" -- rm -rf "/cluster-bins" ||
        failure "Cannot remove /cluster-bins directory"
    # install all the binaries
    install-dir "${instance}" "/nomad/bin" "/cluster-bins" "${link}"

    run-hook "install-bins" "post" "${instance}" || exit
}

# Helper function to install files from source
# directory to destination directory. If link
# is set files will be symlinked instead of
# copied.
#
# $1 - Name of instance
# $2 - Source directory
# $3 - Destination directory
# $4 - Use symlinks instead of copy
function install-dir() {
    local instance="${1?Name of instance required}"
    local src="${2?Source directory required}"
    local dst="${3?Destination directory required}"
    local link="${4}"

    local listing bin
    mapfile -t listing <<< "$(incus exec "${instance}" -- ls "${src}")"
    incus exec "${instance}" -- mkdir -p "${dst}" ||
        failure "Could not create directory - %s" "${dst}"
    for bin in "${listing[@]}"; do
        if incus exec "${instance}" -- test -d "${src}/${bin}"; then
            install-dir "${instance}" "${src}/${bin}" "${dst}/${bin}" "${link}" ||
                failure "Could not install directory %s" "${src}/${bin}"
        else
            if [ -n "${link}" ]; then
                incus exec "${instance}" -- ln -s "${src}/${bin}" "${dst}/${bin}" ||
                    failure "Could not link %s to %s" "${src}/${bin}" "${dst}/${bin}"
            else
                incus exec "${instance}" -- cp "${src}/${bin}" "${dst}/${bin}" ||
                    failure "Could not copy %s to %s" "${src}/${bin}" "${dst}/${bin}"
                if [ "${bin}" == "vault" ]; then
                    incus exec "${instance}" -- setcap cap_ipc_lock=+ep "${dst}/${bin}" ||
                        warn "Could not adjust capabilities on vault binary"
                fi
            fi
        fi
    done
}

# Check if instance is a container
#
# $1 - Full name of instance
function is-instance-container() {
    local instance="${1?Name of instance is required}"

    if [ "$(incus list "${instance}" --format json | jq -r '.[].type')" == "container" ]; then
        return 0
    fi

    return 1
}

# Get an instance name for the given
# type. Will be the first availble type
# in the list.
#
# $1 - Type of instance (server, client, consul)
# $2 - Name of instance to exclude (optional)
function get-instance-of() {
    local type="${1?type of instance is required}"
    local excluded="${2}"
    local instances instance
    readarray -t instances < <(get-instances "${type}")
    if [ -z "${excluded}" ]; then
        instance="${instances[0]}"
    else
        local i
        for i in "${instances[@]}"; do
            if [ "${i}" != "${excluded}" ]; then
                instance="${i}"
                break
            fi
        done
    fi

    if [ -z "${instance}" ]; then
        failure "could not locate instance of type - %s" "${type}"
    fi
    printf "%s" "${instance}"
}

# Get incus instance names for nomad
#
# $1 - instance type server/client/consul (optional)
function get-instances() {
    local type info instances
    type="${1}"
    info="$(incus list --format json)" || exit
    instances="$(jq -r '.[] | select(.name | contains("'"${CLUSTER_INSTANCE_PREFIX}${type}"'")) | .name' <<< "${info}")"
    printf "%s" "${instances}"
}

# Get nomad node names
function get-nodes() {
    local info nodes
    info="$(nomad node status -json)" ||
        failure "Unable to list nomad nodes"
    nodes="$(jq -r '.[].ID' <<< "${info}")"
    printf "%s" "${nodes}"
}

# Get address for named instance
#
# $1 - instance name
function get-instance-address() {
    local name="${1?Name is required}"
    local instance
    instance="$(name-to-instance "${name}" "novalidate")" || exit

    local result address network retried
    network="$(cluster-network)" || exit

    # The address might not have made it to the leases list if the
    # instance was just created. If retrying, force a wait to allow
    # the information to be made available.
    while [ -z "${retried}" ]; do
        if [ -n "${result}" ]; then
            retried="1"
            sleep 1
        fi
        result="$(incus network list-leases "${network}" --format json)" ||
            failure "Could not list network leases for address lookup on %s" "${instance}"
        address="$(jq -r '.[] | select(.hostname == "'"${instance}"'") | select(.address | contains(".")) | .address' <<< "${result}")"
    done
    if [ -z "${address}" ]; then
        failure "Could not determine address for instance %s" "${instance}"
    fi
    debug "instance=%s network=%s address=%s" "${instance}" "${network}" "${address}"
    printf "%s" "${address}"
}

# Name of the default network applied to instances
# in the cluster. This is the network name set
# within the cluster-hack profile.
function default-network() {
    local result
    # Use profile default network
    result="$(incus profile list --format json)" ||
        failure "Could not list incus profiles"
    jq -r '.[] | select(.name == "cluster-hack").devices[] | select(.network).network' <<< "${result}"
}

# Name of the default network for the cluster. This
# will be the custom network if enabled, or the incus
# bridge if not.
function cluster-network() {
    local result names net
    result="$(incus network list --format json)" ||
        failure "Could not list incus networks"
    readarray -t names < <(jq -r '.[] | select(.managed).name' <<< "${result}")
    # Check first for custom network
    for net in "${names[@]}"; do
        if [ "${net}" == "${CLUSTER_NETWORK}" ]; then
            printf "%s" "${net}"
            return 0
        fi
    done

    default-network
}

# Attaches the named network to the instance,
# configures the network, and restricts traffic
# on the default network.
#
# $1 - Name of instance
# $2 - Name of network
function use-network() {
    local name="${1?Name is required}"
    local network="${2?Network is required}"
    local result default_dev dev
    instance="$(name-to-instance "${name}")" || exit

    info "Configuring instance for isolated cluster network - %s" "${instance}"
    # Start with attaching the network
    incus network attach "${network}" "${instance}" > /dev/null ||
        failure "Unable to attach network '%s' to - %s" "${instance}"
    # Determine the device
    result="$(incus list --format json)" ||
        failure "Failed to get instance list for network use on %s" "${instance}"
    default_dev="$(jq -r '.[] | select(.name == "'"${instance}"'").state.network | map_values(select(.addresses != []) | select(.addresses[].scope != "local")) | keys[]' <<< "${result}")"
    if [ -z "${default_dev}" ]; then
        failure "Could not determine default network device name for %s" "${instance}"
    fi
    dev="$(jq -r '.[] | select(.name == "'"${instance}"'").state.network | map_values(select(.addresses == [])) | keys[]' <<< "${result}")"
    if [ -z "${dev}" ]; then
        failure "Could not determine network device name for %s" "${instance}"
    fi
    # Configure the device on the instance
    incus exec "${instance}" -- /helpers/sed-helper "s/%DEVICE_NAME%/${dev}/" \
        /cluster/extras/networking/netplan.yaml /etc/netplan/99-cluster-hack.yaml ||
        failure "Could not add network configuration on %s" "${instance}"
    incus exec "${instance}" -- chmod 0600 /etc/netplan/99-cluster-hack.yaml ||
        failure "Could not adjust network file permissions on %s" "${instance}"
    # Generate the network configuration
    incus exec "${instance}" -- netplan generate > /dev/null ||
        failure "Failed to generate network configuration on %s" "${instance}"
    # Apply the new network configuration
    incus exec "${instance}" -- netplan apply > /dev/null ||
        failure "Failed to apply network configuration on %s" "${instance}"
    # Install iptables
    incus exec --env "DEBIAN_FRONTEND=noninteractive" "${instance}" -- apt-get install -yq iptables > /dev/null ||
        failure "Failed to install iptables"

    local instance_addr
    instance_addr="$(get-instance-address "${instance}" "noverify")" || exit

    # If the cacher instance is available, allow
    # traffic to the cacher instance only.
    if is-cacher-enabled; then
        detail "Allow access to global apt cacher for %s" "${instance}"
        local addr
        addr="$(cacher-address)" || exit
        incus exec "${instance}" -- iptables -A INPUT -s "${addr}/32" -j ACCEPT ||
            failure "Could not allow cacher access on %s" "${instance}"
        incus exec "${instance}" -- iptables -A OUTPUT -d "${addr}/32" -j ACCEPT ||
            failure "Could not allow cacher access on %s" "${instance}"
        incus exec "${instance}" -- iptables -A FORWARD -d "${addr}/32" -j ACCEPT ||
            failure "Could not allow cacher access on %s" "${instance}"
    fi

    detail "Restrict traffic on default network for %s" "${instance}"
    # Now restrict the default network.
    incus exec "${instance}" -- iptables -A INPUT -i "${default_dev}" -s "${instance_addr}/8" -j REJECT ||
        failure "Could not restrict default network ingress traffic on %s" "${instance}"
    incus exec "${instance}" -- iptables -A OUTPUT -d "${instance_addr}/24" -j ACCEPT ||
        failure "Could not enable isolated network egress traffic on %s" "${instance}"
    incus exec "${instance}" -- iptables -A OUTPUT -d "${instance_addr}/8" -j REJECT ||
        failure "Could not restrict egress traffic on %s" "${instance}"
    incus exec "${instance}" -- iptables -A FORWARD -d "${instance_addr}/24" -j ACCEPT ||
        failure "Could not enable isolated network forward traffic on %s" "${instance}"
    incus exec "${instance}" -- iptables -A FORWARD -d "${instance_addr}/8" -j REJECT ||
        failure "Could not restrict forward traffic on %s" "${instance}"

    # Remove the default route using the default device
    local info
    info="$(incus exec "${instance}" -- ip route | head -n 1 | awk '{print $1, $2, $3}')"
    incus exec "${instance}" -- sh -c "ip route del ${info}" ||
        failure "Could not delete default route for %s on %s" "${default_dev}" "${instance}"

    success "Instance fully configured for isolated cluster network - %s" "${instance}"
}

# Networks attached to the instance
#
# $1 - Name of instance
function get-instance-networks() {
    local name="${1?Name is required}"
    local instance names
    instance="$(name-to-instance "${name}")" || exit
    readarray -t names < <(incus network list --format json | jq -r '.[] | select(.used_by[] | contains("'"${instance}"'")).name') ||
        failure "Failed to read network list for instance - %s" "${instance}"
    printf "%s\n" "${names[@]}"
}

# Get address for nomad node ID
#
# $1 - node ID
function get-node-address() {
    local node_id="${1?Nomad node ID required}"
    local address
    # TODO: this needs to be fixed to remove static device name
    address="$(nomad node status -json "${node_id}" | jq -r '.NodeResources.Networks[] | select(.Device == \"eth0\") | .IP')"
    if [ -z "${address}" ]; then
        failure "Could not determine address for node %s" "${node_id}"
    fi
    printf "%s" "${address}"
}

# Resolve instance name from given name. Given name
# can be full instance name, instance name without
# prefix (for example: client0), or nomad node id
#
# $1 - Name of instance or node
# $2 - Skip validation (optional)
function name-to-instance() {
    local name="${1?Name is required}"
    if [ -n "${2}" ] && [[ "${name}" == "${CLUSTER_INSTANCE_PREFIX}"* ]]; then
        printf "%s" "${name}"
        return
    fi

    local instance_names instance
    readarray -t instance_names < <(get-instances)
    for instance in "${instance_names[@]}"; do
        if [ "${instance}" == "${name}" ] || [ "${instance}" == "${CLUSTER_INSTANCE_PREFIX}${name}" ]; then
            printf "%s" "${instance}"
            return
        fi
    done

    local nodes node n
    readarray -t nodes < <(get-nodes)
    for n in "${nodes[@]}"; do
        if [[ "${n}" == "${name}"* ]]; then
            node="${n}"
            break
        fi
    done

    if [ -z "${node}" ]; then
        failure "Could not locate an instance for name - %s" "${name}"
    fi

    instance="$(nomad node status -json "${node}" | jq -r '.Name')"
    if [ -n "${instance}" ]; then
        printf "%s" "${instance}"
        return
    fi

    failure "Could not locate an instance for name - %s" "${name}"
}

# Resolve nomad id from name given. Given name
# can be nomad node id (full or partial), full
# instance name, or instance name without
# prefix (for example: client0)
#
# $1 - Name of instance or node
function name-to-node() {
    local name="${1?Name is required}"
    local nodes node
    readarray -t nodes < <(get-nodes)
    for node in "${nodes[@]}"; do
        if [[ "${node}" == "${name}"* ]]; then
            printf "%s" "${node}"
            return
        fi
    done

    local instance_names instance i
    readarray -t instance_names < <(get-instances)
    for i in "${instance_names[@]}"; do
        if [ "${i}" == "${name}" ] || [ "${i}" == "${CLUSTER_INSTANCE_PREFIX}${name}" ]; then
            instance="${i}"
        fi
    done

    if [ -z "${instance}" ]; then
        failure "Could not locate a node for name - %s" "${name}"
    fi

    local node
    node="$(nomad node status -json | jq -r '.[] | select(.Name == "'"${instance}"'") | .ID')"
    if [ -n "${node}" ]; then
        printf "%s" "${node}"
        return
    fi

    failure "Could not locate a node for name - %s" "${name}"
}

# Execute named hook scripts
#
# $1 - Name of hook
# $2 - Type of hook (pre or post)
# $3 - Name of instance
#
# NOTE: full instance name required
function run-hook() {
    local hook="${1?Name of hook required}"
    local type="${2?Type of hook required}"
    local instance="${3?Name of instance required}"
    local instance_type="container"
    if ! is-instance-container "${instance}"; then
        instance_type="vm"
    fi

    local hook_dir="./cluster/hooks/${hook}/${type}"

    debug "running %s %s hook - %s on %s" "${type}" "${hook}" "${hook_dir}" "${instance}"

    export CLUSTER_COMMONS="${csource}"

    # Two types of scripts available:
    #   * local - run on host
    #   * remote - run on instance
    local files=("${hook_dir}/local/"*)
    local file display_name
    if [ -f "${files[0]}" ]; then
        info "Running local %s-%s hooks on %s" "${type}" "${hook}" "${instance}"
        for file in "${files[@]}"; do
            display_name="$(basename "${file}")"
            if [ ! -f "${file}" ] || [ ! -e "${file}" ]; then
                warn "skipping non-executable hook - %s on %s" "${display_name}" "${instance}"
                continue
            fi
            detail "executing - %s on %s" "${display_name}" "${instance}"
            "${file}" "${instance}" "${instance_type}" ||
                failure "Execution of local %s-%s hook failed on %s - %s" "${type}" "${hook}" "${file}" "${instance}"
        done
    fi

    files=("${hook_dir}/remote/"*)
    if [ -f "${files[0]}" ]; then
        info "Running remote %s-%s hooks" "${type}" "${hook}"
        for file in "${files[@]}"; do
            display_name="$(basename "${file}")"
            if [ ! -f "${file}" ]; then
                warn "skipping non-file hook - %s" "${display_name}"
                continue
            fi
            detail "executing - %s" "${display_name}"
            local remote="/tmp/$(random-string)"
            incus file push "${file}" "${instance}${remote}" > /dev/null ||
                failure "Could not upload hook file %s on %s" "${display_name}" "${instance}"
            incus exec "${instance}" -- chmod a+x "${remote}" ||
                failure "Could not make hook file '%s' executable on %s" "${display_name}" "${instance}"
            incus exec "${instance}" -- "${remote}" "${instance}" "${instance_type}" ||
                failure "Execution of remote %s-%s hook failed - %s" "${type}" "${hook}" "${display_name}"
            incus exec "${instance}" -- rm -f "${remote}"
        done
    fi
}

# Apply network impairment to instance
#
# $1 - Name of instance
# $2 - Name of impairment
function impair-instance-network() {
    local name="${1?Name of instance is required}"
    local impairment="${2?Name of impairment is required}"
    local instance dev result addr
    instance="$(name-to-instance "${name}")" || exit

    addr="$(get-instance-address "${instance}")" || exit
    result="$(incus list --format json)" ||
        failure "Failed to get instance list for network use on %s" "${instance}"
    dev="$(jq -r '.[] | select(.name == "'"${instance}"'").state.network | map_values(select(.addresses[].address == "'"${addr}"'")) | keys[]' <<< "${result}")"
    if [ -z "${dev}" ]; then
        failure "Could not determine network device name for impairment on %s" "${instance}"
    fi

    info "Applying network impairment '%s' to %s" "${impairment}" "${instance}"
    case "${impairment}" in
        "slow")
            impairment-slow "${instance}" "${dev}" || exit
            ;;
        "very-slow")
            impairment-slow "${instance}" "${dev}" "extra" || exit
            ;;
        "lossy")
            impairment-lossy "${instance}" "${dev}" || exit
            ;;
        "very-lossy")
            impairment-lossy "${instance}" "${dev}" "extra" || exit
            ;;
        "slow-lossy")
            impairment-slow "${instance}" "${dev}" || exit
            impairment-lossy "${instance}" "${dev}" || exit
            ;;
        "very-slow-lossy")
            impairment-slow "${instance}" "${dev}" "extra" || exit
            impairment-lossy "${instance}" "${dev}" "extra" || exit
            ;;
        *)
            failure "Unknown network impairment (%s) requested for %s" "${impairment}" "${instance}"
    esac

    success "Network impairment applied to %s" "${instance}"
}

# Apply lossy network impairment to instance
#
# $1 - Name of instance
# $2 - Name of network device
# $3 - Level of impairment (optional)
function impairment-lossy() {
    local name="${1?Name of instance is required}"
    local dev="${2?Local device name is required}"
    local level="${3}"
    local instance
    instance="$(name-to-instance "${name}" "noverify")" || exit

    local probability="0.05"
    if [ -n "${level}" ]; then
        probability="0.10"
    fi

    detail "applying lossy network impairment on %s" "${instance}"
    incus exec "${instance}" -- iptables -A input -i "${dev}" -m statistic --mode random --probability "${probability}" -j DROP ||
        failure "Failed to apply input network impairment for lossy on %s" "${instance}"
    incus exec "${instance}" -- iptables -A output -o "${dev}" -m statistic --mode random --probability "${probability}" -j DROP ||
        failure "Failed to apply output network impairment for lossy on %s" "${instance}"

    local prob
    prob="$(printf "%.2f*100\n" "${probability}" | bc -l)"
    detail "impairment of %d% packet loss applied on %s" "${prob}" "${instance}"
}

# Apply slow network impairment to instance
#
# $1 - Name of instance
# $2 - Name of network device
# $3 - Level of impairment (optional)
function impairment-slow() {
    local name="${1?Name of instance is required}"
    local dev="${2?Local device name is required}"
    local level="${3}"
    local instance
    instance="$(name-to-instance "${name}" "noverify")" || exit

    local bandwidth_max="600kbit"
    local bandwidth="500kbit"
    local latency="100ms"
    if [ -n "${level}" ]; then
        bandwidth_max="120kbit"
        bandwidth="100kbit"
        latency="300ms"
    fi

    detail "applying slow network impairment on %s" "${instance}"

    # Install the ifb module on the instance (done from host)
    if is-instance-container "${instance}"; then
        incus config set "${instance}" linux.kernel_modules ifb
    fi

    # Clean before setup (don't care about errors)
    incus exec "${instance}" -- tc qdisc del dev "${dev}" root > /dev/null 2>&1

    # Apply impairment to outgoing packets

    # Create the queueing discipline
    incus exec "${instance}" -- tc qdisc add dev "${dev}" root handle 1: htb default 20 ||
        failure "Failed to create outgoing queueing discipline for %s on %s" "${dev}" "${instance}"
    # Place bandwidth restriction
    incus exec "${instance}" -- tc class add dev "${dev}" parent 1:1 classid 1:20 htb rate "${bandwidth}" ceil "${bandwidth_max}" ||
        failure "Failed to apply outgoing bandwidth restriction for %s on %s" "${dev}" "${instance}"
    # Apply latency
    incus exec "${instance}" -- tc qdisc add dev "${dev}" parent 1:20 netem latency "${latency}" 75ms ||
        failure "Failed to apply outgoing latency for %s on %s" "${dev}" "${instance}"

    # Apply impairment to incoming packets

    # Create a new device to forward incoming packets through
    incus exec "${instance}" -- ip link add ifb0 type ifb ||
        failure "Could not create new IFB device for incoming impairment on %s" "${instance}"
    incus exec "${instance}" -- ip link set ifb0 up ||
        failure "Could not bring new IFB device for incoming impairment up on %s" "${instance}"
    incus exec "${instance}" -- tc qdisc add dev ifb0 root handle 1: htb default 20 ||
        failure "Failed to create queueing discipline for new incoming device on %s" "${instance}"
    incus exec "${instance}" -- tc qdisc add dev "${dev}" handle ffff: ingress ||
        failure "Failed to add ingress queueing discipline for new incoming device on %s" "${instance}"
    incus exec "${instance}" -- tc filter add dev "${dev}" parent ffff: u32 match u32 0 0 action mirred egress redirect dev ifb0 ||
        failure "Failed to create packet filter to new incoming device on %s" "${instance}"

    # Set device name to new device
    dev="ifb0"

    # Place bandwidth restriction
    incus exec "${instance}" -- tc class add dev "${dev}" parent 1:1 classid 1:20 htb rate "${bandwidth}" ceil "${bandwidth_max}" ||
        failure "Failed to apply incoming bandwidth restriction for %s on %s" "${dev}" "${instance}"
    # Apply latency
    incus exec "${instance}" -- tc qdisc add dev "${dev}" parent 1:20 netem latency "${latency}" ||
        failure "Failed to apply incoming latency for %s on %s" "${dev}" "${instance}"

    detail "impairment of %s bandwidth and %s latency applied on %s" "${bandwidth_max}" "${latency}" "${instance}"
}

# Check if provided network impairment name
# is valid
#
# $1 - Name of impairment
function is-network-impairment-valid() {
    local name="${1?Impairment name is required}"
    local check
    for check in "${CLUSTER_NETWORK_IMPAIRMENTS[@]}"; do
        if [ "${check}" == "${name}" ]; then
            return 0
        fi
    done

    return 1
}

# Wait for the instance to respond to commands
#
# $1 - Name of instance
# $2 - Number of iterations (seconds) to wait - default: 60
function wait-for-instance() {
    local name="${1?Name of instance is required}"
    local count="${2}"
    if [ -z "${count}" ]; then
        count=60
    fi
    local instance i
    instance="$(name-to-instance "${name}" "noverify")" || exit

    for ((i=0;i<count;i++)); do
      if incus exec "${instance}" -- ls > /dev/null 2>&1; then
          return
      fi
      sleep 1
    done

    failure "Failed to establish connection to instance %s" "${instance}"
}

# Persist a value to local storage
#
# $1 - Reference key for stored value
# $2 - Value to store
function store-value() {
    local key="${1?Key name is required}"
    local value="${2?Value is required}"

    mkdir -p "${INFO_DIR}" ||
        failure "Cannot create info storage directory"
    local value_path="${INFO_DIR}/${key}"
    printf "%s" "${value}" > "${value_path}"
}

# Retrieve a value from local storage
#
# $1 - Reference key for stored value
function get-value() {
    local key="${1?Key name is required}"
    local value_path="${INFO_DIR}/${key}"
    local value
    if [ ! -f "${value_path}" ]; then
        failure "No value stored for given key - %s" "${key}"
    fi

    value="$(<"${value_path}")"
    printf "%s" "${value}"
}

# Generate a random string value. Length
# will default to 10 characters if no
# length is passed.
#
# $1 - Length of string
function random-string() {
    local length="${1}"
    if [ -z "${length}" ]; then
        length=10
    fi
    local i
    local value=""
    for ((i=0;i<length;i++)); do
        value+="$(printf "%x" $((RANDOM%16)))"
    done

    printf "%s" "${value}"
}

# Write failure message and exit
function failure() {
    local msg_template="${1}"
    local i=$(( ${#} - 1 ))
    local msg_args=("${@:2:$i}")

    printf "%b×%b ${msg_template}\n" "${TEXT_RED}" "${TEXT_CLEAR}" "${msg_args[@]}" >&2

    exit 1
}

# Write error message
function error() {
    local msg_template="${1}"
    local i=$(( ${#} - 1 ))
    local msg_args=("${@:2:$i}")

    printf "%b»%b ${msg_template}\n" "${TEXT_RED}" "${TEXT_CLEAR}" "${msg_args[@]}" >&2
}

# Write success message
function success() {
    local msg_template="${1}"
    local i=$(( ${#} - 1 ))
    local msg_args=("${@:2:$i}")

    printf "%b»%b ${msg_template}\n" "${TEXT_GREEN}" "${TEXT_CLEAR}" "${msg_args[@]}"
}

# Write warning message
function warn() {
    local msg_template="${1}"
    local i=$(( ${#} - 1 ))
    local msg_args=("${@:2:$i}")

    printf "%b»%b ${msg_template}\n" "${TEXT_YELLOW}" "${TEXT_CLEAR}" "${msg_args[@]}"
}

# Write information message
function info() {
    local msg_template="${1}"
    local i=$(( ${#} - 1 ))
    local msg_args=("${@:2:$i}")

    printf "%b›%b ${msg_template}\n" "${TEXT_BOLD}" "${TEXT_CLEAR}" "${msg_args[@]}"
}

# Write detail message
function detail() {
    local msg_template="${1}"
    local i=$(( ${#} - 1 ))
    local msg_args=("${@:2:$i}")

    printf " • ${msg_template}\n" "${msg_args[@]}"
}

# Write debug message
function debug() {
    if [ -z "${CLUSTER_DEBUG_OUTPUT}" ]; then
        return
    fi
    local msg_template="${1}"
    local i=$(( ${#} - 1 ))
    local msg_args=("${@:2:$i}")

    printf "%b·%b %b${msg_template}%b\n" "${TEXT_YELLOW}" "${TEXT_CLEAR}" "${TEXT_CYAN}" "${msg_args[@]}" "${TEXT_CLEAR}" >&2
}

# Check that cluster exists and fail
# if it does not
function cluster-must-exist() {
    if [ -z "$(get-instances)" ]; then
        failure "Cluster does not currently exist"
    fi
}

# Check that does not exist and fail
# if it does
function cluster-must-not-exist() {
    if [ -n "$(get-instances)" ]; then
        failure "Cluster already exists"
    fi
}

# Check that consul is enabled for cluster
# and fail if not
function cluster-must-have-consul() {
    if [ -z "$(get-instances "consul")" ]; then
        failure "Cluster must have consul enabled"
    fi
}

# Check that vault is enabled for cluster
# and fail if not
function cluster-must-have-vault() {
    if [ -z "$(get-instances "vault")" ]; then
        failure "Cluster must have vault enabled"
    fi
}

function cluster-must-have-ceph() {
    if [ -z "$(get-instances "ceph")" ]; then
        failure "Cluster must have ceph enabled"
    fi
}

# Check if the cluster has network isolation
# enabled and fail if not
function cluster-must-have-isolated-network() {
    if ! is-cluster-network-enabled; then
        failure "Cluster must be created with network isolation"
    fi
}

# Returns if consul is usable
function consul-is-usable() {
    if ! command -v consul > /dev/null 2>&1; then
        return 1
    fi

    if ! consul info > /dev/null 2>&1; then
        return 1
    fi
}
