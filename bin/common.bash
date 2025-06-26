#!/usr/bin/env bash
DIR_SHA="$(pwd | sha256sum)"
export DIR_SHA="${DIR_SHA:0:6}"
export NOMAD_INSTANCE_PREFIX="nomad-cluster-${DIR_SHA}-"
export ENVRC_HEADER="### cluster header ###"
export PROFILE_NAME="cluster-hack"
export SCRIPT_NAME="$(basename "${0}")"

TEXT_CLEAR='\e[0m'
TEXT_BOLD='\e[1m'
TEXT_RED='\e[31m'
TEXT_GREEN='\e[32m'
TEXT_YELLOW='\e[33m'

HELPER_SCRIPTS=("config-scrub" "sed-helper" "stream-log")

# CRUD

# Create a new cluster instance
#
# $1 - Name of instance
function create-cluster-instance() {
    local name="${1?Name for instance required}"
    if [[ "${name}" != "${NOMAD_INSTANCE_PREFIX}"* ]]; then
        name="${NOMAD_INSTANCE_PREFIX}${name}"
    fi

    info "Launching cluster instance %s..." "${name}"
    incus launch "${LAUNCH_ARGS[@]}" "${name}" > /dev/null ||
        failure "Error encountered launching cluster instance %s" "${name}"
    # Wait for the instance to actually be available. This will
    # be instantly for containers, and a slight delay for vms
    while ! incus exec "${name}" /bin/true > /dev/null 2>&1; do
        sleep 0.1
    done
    # The helper scripts will fail to execute from the /cluster
    # directory on vms, so just drop them directly in the instance
    incus exec "${name}" -- mkdir /helpers ||
        failure "Failed to create helpers directory on %s" "${name}"

    for helper in "${HELPER_SCRIPTS[@]}"; do
        incus exec "${name}" -- cp "/cluster/helpers/${helper}" "/helpers/${helper}" ||
        failure "Failed to copy %s to %s" "${helper}" "${name}"
    done

    install-bins "${name}"

    success "Launched new cluster instance %s" "${name}"
}

# Fully launch a nomad server instance
#
# $1 - Name of instance
# $2 - Expected count of servers
# $3 - Consul is enabled
function launch-nomad-server-instance() {
    local name="${1?Name for server is required}"
    local count="${2?Count of servers required}"
    local consul_enabled="${3}"

    create-cluster-instance "${name}" || exit
    configure-nomad-server "${name}" "${count}" || exit
    if [ -n "${consul_enabled}" ]; then
        consul-enable "${name}" || exit
    else
        server-nomad-discovery "${name}" || exit
    fi
    start-service "${name}" "nomad"
}

# Fully launch a nomad client instance
#
# $1 - Name of instance
# $2 - Consul is enabled
function launch-nomad-client-instance() {
    local name="${1?Name for client is required}"
    if [[ "${name}" != "${NOMAD_INSTANCE_PREFIX}"* ]]; then
        name="${NOMAD_INSTANCE_PREFIX}${name}"
    fi
    local consul_enabled="${2}"

    create-cluster-instance "${name}" || exit
    configure-nomad-client "${name}" || exit
    if [ -n "${consul_enabled}" ]; then
        consul-enable "${name}" || exit
    else
        client-nomad-discovery "${name}" || exit
    fi

    start-service "${name}" "nomad-client" || exit
}

# Configure an instance for consul server and start the service
#
# $1 - Name of instance
# $2 - Count of servers
function configure-consul-server() {
    local name="${1?Name of server required}"
    local count="${2?Count of servers required}"

    local addr
    if [[ "${name}" != "${NOMAD_INSTANCE_PREFIX}"* ]]; then
        name="${NOMAD_INSTANCE_PREFIX}${name}"
    fi
    if [[ "${name}" != *"consul0" ]]; then
        addr="$(consul-address)" || exit
    fi

    info "Adding base server consul configuration (%s)..." "${name}"
    gossip_key="$(consul-gossip-key)" || exit

    incus exec "${name}" -- mkdir -p /etc/consul/config.d ||
        failure "Could not create consul configuration directory on %s" "${name}"
    incus exec "${name}" -- /helpers/sed-helper "s/%NUM%/${count}/" /cluster/config/consul/server/config.hcl /etc/consul/config.d/00-server.hcl ||
        failure "Could not install consul server configuration on %s" "${name}"
    incus exec "${name}" -- /helpers/sed-helper "s|%GOSSIP_KEY%|${gossip_key}|" /cluster/config/consul/config.hcl /tmp/consul.hcl ||
        failure "Could not modify consul configuration on %s" "${name}"
    incus exec "${name}" -- /helpers/sed-helper "s/%ADDR%/${addr}/" /tmp/consul.hcl /etc/consul/config.d/01-consul.hcl ||
        failure "Could not modify consul join configuration on %s" "${name}"

    files=(./config/consul/server/*.hcl)
    if [ -f "${files[0]}" ]; then
        info "Installing custom consul server configuration files on %s..." "${name}"
        for cfg in "${files[@]}"; do
            slim_name="$(basename "${cfg}")"
            printf "  • adding config file - %s to %s\n" "${cfg}" "${name}"
            incus file push "${cfg}" "${name}/etc/nomad/config.d/99-${slim_name}" > /dev/null ||
                failure "Error pushing consul server configuration file (%s) into %s" "${slim_name}" "${name}"
        done
    fi

    info "Installing consul systemd unit file into %s" "${name}"
    incus exec "${name}" -- cp /cluster/services/consul.service /etc/systemd/system/consul.service ||
        failure "Could not install consul.service unit file into %s" "${name}"

    start-service "${name}" "consul" || exit
}

# Configure an instance for nomad server
#
# $1 - Name of instance
# $2 - Number of server instances
function configure-nomad-server() {
    local name="${1?Name of server required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit
    local count="${2?Count of servers required}"

    info "Adding base server nomad configuration (%s)..." "${instance}"
    incus exec "${instance}" -- mkdir -p /etc/nomad/config.d ||
        failure "Could not create nomad config directory on %s" "${instance}"
    incus exec "${instance}" -- cp /cluster/config/nomad/config.hcl /etc/nomad/config.d/00-config.hcl ||
        failure "Could not install base nomad configuration on %s" "${instance}"
    incus exec "${instance}" -- /helpers/sed-helper "s/%NUM_SERVERS%/${count}/" /cluster/config/nomad/server/config.hcl /etc/nomad/config.d/01-server.hcl ||
        failure "Could not modify nomad server configuration %s" "${instance}"

    files=(./config/nomad/server/*.hcl)
    if [ -f "${files[0]}" ]; then
        info "Installing custom nomad configuration files on %s..." "${instance}"
        for cfg in "${files[@]}"; do
            slim_name="$(basename "${cfg}")"
            printf "  • adding config file - %s to %s\n" "${cfg}" "${instance}"
            incus file push "${cfg}" "${name}/etc/nomad/config.d/99-${slim_name}" > /dev/null ||
                failure "Error pushing nomad configuration file (%s) into %s" "${slim_name}" "${instance}"
        done
    fi

    info "Installing nomad systemd unit file into %s" "${instance}"
    incus exec "${instance}" -- /helpers/sed-helper "s/%NOMAD_NAME%/nomad/" /cluster/services/nomad.service /etc/systemd/system/nomad.service ||
        failure "Could not install nomad.service unit file into %s" "${instance}"

    success "Base server nomad configuration applied to %s" "${instance}"
}

# Configure an instance for nomad client
#
# $1 - Name of instance
function configure-nomad-client() {
    local name="${1?Name of client required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit

    info "Adding base client nomad configuration (%s)..." "${instance}"
    incus exec "${instance}" -- mkdir -p /etc/nomad/config.d ||
        failure "Could not create nomad config directory on %s" "${instance}"
    incus exec "${instance}" -- cp /cluster/config/nomad/config.hcl /etc/nomad/config.d/00-config.hcl ||
        failure "Could not install base nomad configuration on %s" "${instance}"
    incus exec "${instance}" -- cp /cluster/config/nomad/client/config.hcl /etc/nomad/config.d/01-client.hcl ||
        failure "Could not install client nomad configuration on %s" "${instance}"

    files=(./config/nomad/client/*.hcl)
    if [ -f "${files[0]}" ]; then
        info "Installing custom nomad configuration files on %s..." "${instance}"
        for cfg in "${files[@]}"; do
            slim_name="$(basename "${cfg}")"
            printf "  • adding config file - %s to %s\n" "${cfg}" "${instance}"
            incus file push "${cfg}" "${name}/etc/nomad/config.d/99-${slim_name}" > /dev/null ||
                failure "Error pushing nomad configuration file (%s) into %s" "${slim_name}" "${instance}"
        done
    fi

    info "Installing nomad systemd unit file into %s" "${instance}"
    incus exec "${instance}" -- /helpers/sed-helper "s/%NOMAD_NAME%/nomad-client/" /cluster/services/nomad.service /etc/systemd/system/nomad-client.service ||
        failure "Could not install nomad-client.service unit file into %s" "${instance}"

    success "Base client nomad configuration applied to %s" "${instance}"
}

# Configure nomad server with nomad based discovery
#
# $1 - Name of instance
function server-nomad-discovery() {
    local name="${1?Name of server required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit
    local addr
    addr="$(get-instance-address "server0")" || exit

    incus exec "${instance}" -- /helpers/sed-helper "s/%ADDR%/${addr}/" /cluster/config/nomad/server/server_join.hcl /etc/nomad/config.d/01-join.hcl ||
        failure "Could not install nomad discovery configuration into %s" "${instance}"

    success "Enabled nomad server discovery on %s" "${instance}"
}

# Configure client for nomad based discovery
#
# $1 - Name of instance
function client-nomad-discovery() {
    local name="${1?Name of server required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit
    local addr
    addr="$(get-instance-address "server0")" || exit

    incus exec "${instance}" -- /helpers/sed-helper "s/%ADDR%/${addr}/" /cluster/config/nomad/client/server_join.hcl /etc/nomad/config.d/01-join.hcl ||
        failure "Could not install nomad discovery configuration into %s" "${instance}"

    success "Enabled nomad server discovery on %s" "${instance}"
}

# Generate and store consul encryption key. This
# is always done on the initial server instance.
function consul-init() {
    local instance
    instance="$(name-to-instance "consul0")" || exit

    incus exec "${instance}" -- /nomad/bin/consul keygen > ./.consul-key ||
        failure "Unable to generate nomad gossip key"
    incus file push ./.consul-key "${instance}/.consul-key" ||
        failure "Unable to store nomad gossip key"
    rm -f ./.consul-key

    success "Consul initialized for use"
}

# Get the consul gossip key. This will always be
# stored on the initial server instance.
function consul-gossip-key() {
    instance="$(name-to-instance "consul0")" || exit
    local key
    key="$(incus exec "${instance}" -- cat /.consul-key)" ||
        failure "Unable to read consul gossip key value"

    printf "%s" "${key}"
}

# Get the address of the consul server. This is always
# just the first created consul server.
function consul-address() {
    instance="$(name-to-instance "consul0")" || exit
    local address
    address="$(incus list "${instance}" --format json | jq -r '.[].state.network.eth0.addresses[] | select(.family == "inet") | .address')"
    if [ -z "${address}" ]; then
        failure "Could not determine address for instance %s" "${instance}"
    fi
    printf "%s" "${address}"
}

# Enable consul client on instance.
#
# $1 - Name of instance
function consul-enable() {
    local name="${1?Name of instance required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit
    local addr
    addr="$(consul-address)" || exit
    local gossip_key
    gossip_key="$(consul-gossip-key)" || exit

    info "Enabling consul on %s" "${instance}"
    incus exec "${instance}" -- mkdir -p /etc/consul/config.d ||
        failure "Could not create consul agent configuration directory on %s" "${instance}"
    incus exec "${instance}" -- /helpers/sed-helper "s|%GOSSIP_KEY%|${gossip_key}|" /cluster/config/consul/config.hcl /tmp/consul.hcl ||
        failure "Could not modify consul configuration on %s" "${instance}"
    incus exec "${instance}" -- /helpers/sed-helper "s/%ADDR%/${addr}/" /tmp/consul.hcl /etc/consul/config.d/01-consul.hcl ||
        failure "Could not modify consul join configuration on %s" "${instance}"

    info "Installing consul systemd unit file into %s" "${instance}"
    incus exec "${instance}" -- cp /cluster/services/consul.service /etc/systemd/system/consul.service ||
        failure "Could not install consul.service unit file into %s" "${instance}"
    start-service "${instance}" "consul"
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

# Delete an instance
#
# $1 - Name of instance
function delete-instance() {
    local name="${1?Name is required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit

    info "Destroying nomad cluster instance %s" "${instance}"
    incus stop "${instance}" --force ||
        failure "Unable to stop instance %s" "${instance}"

    success "Nomad cluster instance destroyed %s" "${instance}"
}

# Instance interactions

# Reconfigure nomad on an instance
#
# $1 - Name of instance
function reconfigure-nomad() {
    local name="${1?Name is required}"
    local instance service_name
    instance="$(name-to-instance "${name}")" || exit
    local confs cfg
    if [[ "${instance}" == *"client"* ]]; then
        confs=(./config/nomad/client/*.hcl)
        service_name="nomad-client"
    else
        confs=(./config/nomad/server/*.hcl)
        service_name="nomad"
    fi

    if [ ! -f "${confs[0]}" ]; then
        failure "No custom configuration found to apply - %s" "${instance}"
    fi

    # Reinstall bins in case they have changed
    install-bins "${name}" || exit

    info "Reconfiguring nomad on %s" "${instance}"
    # Start with deleting any existing custom configs
    incus exec "${instance}" -- /helpers/config-scrub ||
        failure "Unable to remove existing nomad configuration on %s" "${instance}"

    # Now copy in custom configs
    local slim_name
    for cfg in "${confs[@]}"; do
        slim_name="$(basename "${cfg}")"
        printf "  • adding config file - %s to %s\n" "${cfg}" "${instance}"
        incus file push "${cfg}" "${instance}/etc/nomad/config.d/99-${slim_name}" > /dev/null ||
            failure "Error pushing nomad configuration file (%s) into %s" "${slim_name}" "${instance}"
    done

    incus exec "${instance}" -- systemctl reload "${service_name}" ||
        failure "Unexpected error during nomad reload"

    success "Reconfigured nomad on %s" "${instance}"
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

# Connec to an instance
#
# $1 - Name of instance
function connect-instance() {
    local name="${1?Name is required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit

    info "Connecting to %s..." "${instance}"
    incus exec "${instance}" bash
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
            nids+=("$(name-to-node "${instance}")") || exit
        fi
    done

    # Install bins in case they have changed
    local pids=()
    for instance in "${names[@]}"; do
        install-bins "${name}" &
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
            continue
        fi

        nid="${nids[$i]}"
        while [ "${eligibility}" == "" ]; do
            eligibility="$(nomad node status -json "${nid}" | jq -r '.SchedulingEligibility')"
            sleep 0.1
        done
        if [ "${eligibility}" == "ineligible" ]; then
            info "Marking nomad client %s (%s) as eligible..." "${instance}" "${nid}"

            nomad node eligibility -enable "${nid}" > /dev/null ||
                failure "Unable to mark node %s as eligible" "${nid}"
        fi
    done
}

# Stream nomad logs from instance
#
# $1 - Name of instance
function stream-logs() {
    local name="${1?Name is required}"
    local instance
    instance="$(name-to-instance "${name}")" || exit
    local instance="${1?Instance name is required}"
    local service_name

    case "${instance}" in
        *"server"*) service_name="nomad" ;;
        *"client"*) service_name="nomad-client" ;;
        *"consul"*) service_name="consul" ;;
    esac

    incus exec "${instance}" -- /helpers/stream-log "${service_name}"
}

# Helpers

# Resolve instance name from given name. Given name
# can be full instance name, instance name without
# prefix (for example: client0), or nomad node id
#
# $1 - Name of instance or node
function name-to-instance() {
    local name="${1?Name is required}"
    local instance_names instance
    readarray -t instance_names < <(get-instances)
    for instance in "${instance_names[@]}"; do
        if [ "${instance}" == "${name}" ] || [ "${instance}" == "${NOMAD_INSTANCE_PREFIX}${name}" ]; then
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
        if [ "${i}" == "${name}" ] || [ "${i}" == "${NOMAD_INSTANCE_PREFIX}${name}" ]; then
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

# Get nomad node names
function get-nodes() {
    local info nodes
    info="$(nomad node status -json)" ||
        failure "Unable to list nomad nodes"
    nodes="$(printf "%s" "${info}" | jq -r ".[].ID")"
    printf "%s" "${nodes}"
}

# Get incus instance names for nomad
#
# $1 - instance type server/client/consul (optional)
function get-instances() {
    local type info instances
    type="${1}"
    info="$(incus list --format json)" || exit
    instances="$(printf "%s" "${info}" | jq -r '.[] | select(.name | contains("'"${NOMAD_INSTANCE_PREFIX}${type}"'")) | .name')"
    printf "%s" "${instances}"
}

# Get address for named instance
#
# $1 - instance name
function get-instance-address() {
    local name="${1?Name is required}"
    local instance
    if [[ "${name}" == "${NOMAD_INSTANCE_PREFIX}"* ]]; then
        instance="${name}"
    else
        instance="$(name-to-instance "${name}")" || exit
    fi

    local address
    address="$(incus list "${instance}" --format json | jq -r '.[].state.network.[] | select(.type == "broadcast") | .addresses[] | select(.family == "inet") | .address')"
    if [ -z "${address}" ]; then
        failure "Could not determine address for instance %s" "${instance}"
    fi
    printf "%s" "${address}"
}

# Install files from the nomad bin directory
# into the instance
#
# $1 - Name of instance
function install-bins() {
    local name="${1?Name of server required}"
    local instance bins bin
    instance="$(name-to-instance "${name}")" || exit

    incus exec "${instance}" -- mkdir -p /cluster-bins ||
        failure "Could not create cluster-bins directory on %s" "${instance}"
    mapfile -t bins <<< "$(incus exec "${instance}" -- ls /nomad/bin)" ||
        failure "Could not read available bins to install on %s" "${instance}"
    for bin in "${bins[@]}"; do
        # need to ensure the path is clear if the bin already
        # exists and is in use
        incus exec "${instance}" -- rm -f "/cluster-bins/${bin}"
        incus exec "${instance}" -- cp "/nomad/bin/${bin}" "/cluster-bins/${bin}" ||
            failure "Could not install %s on %s" "${bin}" "${instance}"
    done
}

# Get address for nomad node ID
#
# $1 - node ID
function get-node-address() {
    local node_id="${1?Nomad node ID required}"
    local address
    address="$(nomad node status -json "${node_id}" | jq -r '.NodeResources.Networks[] | select(.Device == \"eth0\") | .IP')"
    if [ -z "${address}" ]; then
        failure "Could not determine address for node %s" "${node_id}"
    fi
    printf "%s" "${address}"
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
