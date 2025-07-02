# Cluster Hack

Hacky little tool to quickly setup a nomad cluster for testing. Includes 
support for consul backing. Leans on [incus](https://linuxcontainers.org/incus/) 
to do the hard work and [direnv](https://direnv.net/) for easy 
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

Now initialize the directory. The init command will want the path to the nomad 
project. Really it just wants a path to a directory that includes `./bin/nomad` 
(and `./bin/consul` if wanting to use consul):

``` sh
$ ~/projects/cluster-hack/bin/cluster-init ~/projects/nomad
```

This will generate an incus profile and add it if it does not already exist. It 
will also create a `.envrc` within the directory. It includes `PATH` adjustments 
to add the nomad bin directory and the cluster-hack bin directory. 

Everything is ready to create a cluster:

``` sh
$ cluster create --servers 3 --clients 3
```

or, to include consul:

``` sh
$ cluster create --servers 3 --clients 3 --consul 3
```

A global apt cacher can also be created. If the cacher instance is available
instances will be automatically configured to utilize it. To create the 
cacher instance, include the `--cacher` flag during cluster creation:

``` sh
$ cluster create --servers 3 --clients 3 --cacher
```

## Custom configuration

Custom configuration can be applied to the nomad instances. 

* `./config/consul/server/*.hcl` - Added to consul server instances 
* `./config/consul/client/*.hcl` - Added to consul client instances
* `./config/nomad/server/*.hcl` - Added to nomad server instances
* `./config/nomad/client/*.hcl` - Added to nomad client instances

## Commands

* `cluster` - Proxy command to cluster subcommands
* `cluster-add` - Add instances to existing cluster 
* `cluster-connect` - Connect to instance in cluster 
* `cluster-create` - Create a new cluster 
* `cluster-destroy` - Destroy instance(s) or entire cluster 
* `cluster-drain` - Drain nomad client(s) 
* `cluster-init` - Initialize current directory
* `cluster-pause` - Pause instance(s) or entire cluster
* `cluster-reconfigure` - Reconfigure nomad process(es)
* `cluster-restart` - Restart nomad process(es)
* `cluster-resume` - Resume paused instance(s) or entire cluster 
* `cluster-run` - Run commands on instance(s) or entire cluster 
* `cluster-status` - Status information of cluster 
* `cluster-stream-logs` - Stream nomad (or consul) logs

