# Cluster Hack

Hacky little tool to quickly setup a nomad cluster for testing. Includes support for consul backing. Leans on [incus](https://linuxcontainers.org/incus/) to do the hard work and [direnv](https://direnv.net/) for easy 
setup.

## Usage

Designed to be used within a "workspace" directory. First checkout the repository:

``` sh
$ git checkout https://github.com/chrisroberts/cluster-hack ~/projects/cluster-hack
```

Next, create and go to a new workspace directory:

``` sh
$ mkdir -p ~/workspaces/my-test-cluster 
$ cd ~/workspaces/my-test-cluster
```

Now initialize the directory. The init command will want the path to the nomad project. Really it just wants
a path to a directory that includes `./bin/nomad` (and `./bin/consul` if wanting to use consul):

``` sh
$ ~/projects/cluster-hack/bin/cluster-init ~/projects/nomad
```

This will generate an incus profile and add it if it does not already exist. It will also create a `.envrc`
within the directory. It includes `PATH` adjustments to add the nomad bin directory and the cluster-hack
bin directory. 

Everything is ready to create a cluster:

``` sh
$ cluster-create --servers 3 --clients 3
```

## Custom configuration

Custom configuration can be applied to the nomad instances. 

* `./config/nomad/server/*.hcl` - These files will be added to server instances
* `./config/nomad/client/*.hcl` - These files will be added to client instances

## Commands

* `cluster-init` - Initial command to run in directory
* `cluster-connect` - Connect to a cluster instance
* `cluster-create` - Create a cluster 
* `cluster-destroy` - Destroy a cluster
* `cluster-drain` - Drain nomad client(s)
* `cluster-reconfigure` - Reconfigure nomad process(es)
* `cluster-restart` - Restart nomad process(es)
* `cluster-run` - Execute command on instance(s)
* `cluster-status` - Current status of cluster
* `cluster-stream-logs` - Stream nomad log(s) from cluster

