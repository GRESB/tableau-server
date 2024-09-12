# tableau-server

Tableau Server is typically installed on (virtual) machines.
However, for those that do not want to manage machines, there is an option to run Tableau Server on containers.
This repository contains the setup that the Engineering team at GRESB created to run Tableau Server on containers,
managed in kubernetes.

The work in this repository is heavily inspired on [another GitHub repository from Tableau](https://github.com/tableau/tableau-server-in-kubernetes),
that provides kube manifests to run Tableau Server.
The main difference between this repository and the [tableau/tableau-server-in-kubernetes](https://github.com/tableau/tableau-server-in-kubernetes)
repository is that we provide [a methodology to build the Tableau Server container image](./linux-install),
including some fixes to the Tableau Server container setup tool itself and 
additional tooling to works around some limitations of running Tableau Server on kubernetes.
We also provide a [Helm chart](./helm-chart) to install Tableau Server on kubernetes.

Furthermore,
the manifests provided the [tableau/tableau-server-in-kubernetes](https://github.com/tableau/tableau-server-in-kubernetes)
repository are not fit for the type of license that GRESB has.
GRESB purchased a core-based license from Tableau,
and that means we can only license a fixed amount of hardware capacity.
That, in turn, means that we can't use dynamic scaling of the pods and, also, that we need
to adapt the topology of the Tableau Server cluster to achieve HA while remaining within the bounds of our license.

Helpful links from Tableau:

- https://help.tableau.com/current/server/en-us/distrib_ha_install_3node.htm
- https://help.tableau.com/current/server-linux/en-us/server-in-container.htm
- https://help.tableau.com/current/server-linux/en-us/server-in-container_image.htm

This work was not possible without the help of the Tableau Server team at Tableau.
To them, we are very grateful.

## Licenses

Licenses can be downloaded from the Tableau Customer Portal.

## Container images

Tableau does not provide Tableau server container images.
What they do provide is a tool to build those images.
Instructions on how to build such an image can be found in the [linux-install README.md](linux-install/README.md) on
this repository.

## Provisioning

When provisioning a Tableau Server cluster,
we need to do a few helm install/upgrade while issuing some commands on the primary node in between.

### First helm release install

The first step is to install Tableau Server on a k8s cluster.
To that end, this repository includes a [helm chart](helm-chart) that installs Tableau Server.
This chart implements the installation of Tableau Server in a cluster mode, that is,
with multiple pods running in parallel.
Tableau Server is a stateful application, and the [helm chart](helm-chart) provisions two StatefulSets:
primary and worker.
The primary StatefulSet provisions the primary node pod, while the worker StatefulSet provisions two worker pods.
Underlying to each pod,
there is a PersistentVolumeClaim that makes sure each pod gets the same underlying volume for their own data.
On the first installation, we need to disable the liveness and readiness probes for the worker pods.
We need to do that because these probes will not respond successfully until the cluster is configured and operational.
That would mean there would only be one worker pod,
since the underlying StatefulSet would not schedule the second until the first is alive and ready.

To install Tableau Server without the pod probes for the workers, we manipulate a helm value `worker.probe.enabled`.

```bash
helm upgrade --install -n tableau tableau-server-helm helm-chart --set worker.probes.enabled=false
```

After the helm installation, there should be three running pods,
where one is the primary node, and the other two are the workers.
The workers will boot up and wait for a bootstrap file that the primary creates in a shared volume
(we use EFS for that volume, but other options are possible, PRs are welcome for adding those).
Once the bootstrap file is available to the workers, they will complete their own installation.

If for any reason the primary pod does not create the bootstrap file automatically,
use the following Tableau Server Management command, on the primary pod, to generate it.
Please keep in mind that if the primary pod does not automatically create the bootstrap file for the workers,
that could be a sing that the primary pod is not well setup.

```bash
tsm topology nodes get-bootstrap-file -f /docker/config/bootstrap/bootstrap.json
```

#### Useful commands to inspect the state of the pods

On bootstrap, Tableau Server on each of the pods will install some components.
The status of that installation can be viewed by inspecting the following log file.

For the primary pod.

```bash
cat /var/opt/tableau/tableau_server/logs/app-install.log 
...

# If all goes well, the last line of the file should say:
# ...  com.tableausoftware.installer.InstallerMain - Finished running all operations
```

For the worker pods.

```bash
cat /var/opt/tableau/tableau_server/logs/app-worker-install.log 
...

# If all goes well, the last line of the file should say:
# ...  com.tableausoftware.installer.WorkerInstallerMain - Finished running all operations
```

Once that first installation step is complete, then supervisord on the container starts Tableau Server.
The logs for that can be viewed by inspecting the following log file.

```bash
cat /var/opt/tableau/tableau_server/supervisord/run-tableau-server.log 
...

# If all goes well, the last lines of the file should say:
#   + delete_files_on_exit
#   + '[' 0 -gt 0 ']'
```

### Configure cluster topology

Once all three pods are running, and the installation is complete, we need to configure the cluster topology.
There are several topologies that can be used.
One common topology is to run all Tableau Server processes in all nodes.
This topology is good when dynamic scaling is necessary,
because then the horizontal pod autoscaler can be configured to schedule more worker nodes when needed.
This topology can't be used with a core-based license because for those types of licenses, the capacity used
(i.e. the number of pods) needs to align with the contracted licenses,
and therefore scaling can't be dynamic unless licenses are purchased upfront.

For core-based licenses,
like the ones GRESB has, Tableau recommends a topology where the primary node runs a minimal set of Tableau Server
processes, while the workers run the full set of Tableau Server processes.
This topology is depicted in the "Node 1" configuration in the [3-node-topology](docs/images/3-node-topology.png)
diagram.
The primary node is configured with the processes that are marked in red on "Node 1",
and the two worker nodes are configured with all the other processes (of "Node 1").
To configure the topology, we need to execute the following commands on the primary node.

```bash
# Start cluster controller on node2 and node 3
tsm topology set-process -n node2 -pr clustercontroller -c 1
tsm topology set-process -n node3 -pr clustercontroller -c 1
tsm pending-changes apply --ignore-warnings --ignore-prompt
tsm stop
tsm pending-changes list
# If there are pending changes:
#   tsm pending-changes discard
# or
#   tsm pending-changes apply
tsm topology deploy-coordination-service -n node1,node2,node3 --ignore-prompt
tsm start


# Add indexer to node2 and node 3
tsm topology set-process -n node2 -pr indexandsearchserver -c 1
tsm topology set-process -n node3 -pr indexandsearchserver -c 1
# Add psql to node 2 before removing it from node1 (later on)
tsm topology set-process -n node2 -pr pgsql -c 1
tsm pending-changes apply --ignore-prompt


# Add node2 processes
node=node2
tsm topology set-process -n "${node}" -pr clientfileservice -c 1
tsm topology set-process -n "${node}" -pr gateway -c 1
tsm topology set-process -n "${node}" -pr vizportal -c 2
tsm topology set-process -n "${node}" -pr vizqlserver -c 2
tsm topology set-process -n "${node}" -pr cacheserver -c 2
tsm topology set-process -n "${node}" -pr backgrounder -c 2
tsm topology set-process -n "${node}" -pr dataserver -c 2 ###
tsm topology set-process -n "${node}" -pr flowprocessor -c 1
tsm topology set-process -n "${node}" -pr flowminerva -c 1
tsm topology set-process -n "${node}" -pr metrics -c 1
tsm topology set-process -n "${node}" -pr activemqserver -c 1
tsm topology set-process -n "${node}" -pr tdsservice -c 1
tsm topology set-process -n "${node}" -pr tdsnativeservice -c 0
tsm topology set-process -n "${node}" -pr contentexploration -c 1
tsm topology set-process -n "${node}" -pr collections -c 1
tsm topology set-process -n "${node}" -pr noninteractive -c 1
tsm topology set-process -n "${node}" -pr filestore -c 1

# Remove node1 processes
tsm topology set-process -n node1 -pr vizportal  -c 0
tsm topology set-process -n node1 -pr vizqlserver -c 0
tsm topology set-process -n node1 -pr cacheserver -c 0
tsm topology set-process -n node1 -pr backgrounder -c 0
tsm topology set-process -n node1 -pr dataserver -c 0
tsm topology set-process -n node1 -pr flowprocessor -c 0
tsm topology set-process -n node1 -pr metrics -c 0
tsm topology set-process -n node1 -pr activemqserver -c 0
tsm topology set-process -n node1 -pr tdsservice -c 0
tsm topology set-process -n node1 -pr tdsnativeservice -c 0
tsm topology set-process -n node1 -pr contentexploration -c 0
tsm topology set-process -n node1 -pr collections -c 0
tsm topology set-process -n node1 -pr noninteractive -c 0
tsm topology set-process -n node1 -pr filestore -c 0
tsm topology set-process -n node1 -pr pgsql -c 0

# Add node3 processes
node=node3
tsm topology set-process -n "${node}" -pr clientfileservice -c 1
tsm topology set-process -n "${node}" -pr gateway -c 1
tsm topology set-process -n "${node}" -pr vizportal -c 2
tsm topology set-process -n "${node}" -pr vizqlserver -c 2
tsm topology set-process -n "${node}" -pr cacheserver -c 2
tsm topology set-process -n "${node}" -pr backgrounder -c 2
tsm topology set-process -n "${node}" -pr dataserver -c 2
tsm topology set-process -n "${node}" -pr flowprocessor -c 1
tsm topology set-process -n "${node}" -pr flowminerva -c 1
tsm topology set-process -n "${node}" -pr metrics -c 1
tsm topology set-process -n "${node}" -pr activemqserver -c 1
tsm topology set-process -n "${node}" -pr tdsservice -c 1
tsm topology set-process -n "${node}" -pr tdsnativeservice -c 0
tsm topology set-process -n "${node}" -pr contentexploration -c 1
tsm topology set-process -n "${node}" -pr collections -c 1
tsm topology set-process -n "${node}" -pr noninteractive -c 1
tsm topology set-process -n "${node}" -pr filestore -c 1

# Apply changes
tsm pending-changes apply --ignore-prompt
```

After the commands are executed,
the primary node will run a Tableau Server job that will configure the topology on the cluster.
This job can take up to approximately one hour.

The topology setup we use is defined in the [post_init_command script](linux-install/customer-files/post_init_command).
That is executed automatically during the installation procedure.

### Enable pod probes for worker nodes

To finalize the installation, we need to enable the pod probes for the worker nodes.
We can do that by updating the helm release.

```bash
helm upgrade --install -n tableau tableau-server-helm helm-chart --set worker.probe.enabled=true
```

### Other

#### Repository access

The Repository process runs Postgres,
and access to that is controlled based on username, password and source of the traffic.
In a cluster setup, the Tableau Server management process will configure each node
that runs the Repository to accept connections from the other nodes in the cluster.
However, it does that using the source IP of the nodes,
and in a kubernetes environment those IPs are not fixed or predictable.
This means that whenever a pod is restarted,
the processes on that node won't be able to reach the Repository in other nodes,
since that node has a new and different IP.

There are other situations in which access to Repository needs to be set up.
For example, when there are maintenance jobs (like backup and restore jobs),
that spin up dynamic components that need to reach other nodes or be reached by other nodes.

The DB access configuration is written to files named `pg_hba.conf`,
a search in the Tableau Server data directory will reveal all the `pg_hba.conf` at that moment
(but remember they can be created dynamically).
```bash
find /var/opt/tableau/tableau_server -type f -iname 'pg_hba.conf'
```

With a combination of crond, supervisord and bash scripting we implemented a script that gets installed in the nodes,
that automatically patches all the `pg_hba.conf` under the data directory of Tableau Server.
That script is executed every minute by `crond`.

If provided with a set of CIDRs, the script will configure DB access from all those CIDRs.
The script copies the rules added by the default configuration of Tableau Server,
which restrict to the initial node pod IPs, but replaces the IPs by the values of the CIDRs.
This way we can allow access from anywhere in our pod subnets.
If no CIDRs are provided, the script will copy the same rules,
but will allow access from `0.0.0.0/0`, basically anywhere.

We highly recommend setting some CIDRs,
and they can be set in file [custom-env](linux-install/customer-files) assigned to `K8S_CIDRS`.
When setting multiple CIDRs, separate them by spaces.

#### Trust between components

Several Tableau Server components run an Apache Thrift server.
These components also establish trust based on IPs.
When IPs change, some components stop communicating with each other.
While this situation has not yet resulted in downtime for us,
because the server keeps serving requests,
the availability is reduced.

The way to re-establish trust is to run a `tsm` command, but that does imply downtime for the duration of the command.

```bash
tsm authentication trusted configure -th "tableau-server-primary-0", "tableau-server-worker-0", "tableau-server-worker-1"
tsm pending-changes apply

# According to the documentation, the command above should be enough.
# However, we have seen that sometimes we also need to do a restart
tsm restart
```

#### Container image upgrade

If we upgrade the container image at once via a `helm upgrade ...` command,
that change is applied to both the primary and worker stateful sets at the same time.
That typically results in downtime.

A better way to do that is to manually update the image on the primary stateful set,
then once the primary node is completely functional, update the worker stateful set.
This way, there will always be a pod read to serve traffic.

The Tableau Server documentation mentions two options for upgrading:
1. build an upgrade image;
2. provision a new Tableau Server and then restore a backup from a previous version.

Building an upgrade image seems to work for single-node topologies.
However, for multi-node topologies,
that method does not work because the cluster running the upgrade image never gets into a fully functioning state.
When using the upgrade image method, once builds a new image for upgrading
and then runs that [image as a job](https://github.com/tableau/tableau-server-in-kubernetes/blob/main/templates/upgrade-job.yml).
The pod in the upgrade job needs to mount the data directory of the primary node,
which means that node needs to be stopped.
Imagine a 3-node cluster where the pods are called

- tableau-server-primary-0
- tableau-server-worker-0
- tableau-server-worker-1

When the primary pod (from the stateful set) is replaced by a pod from the upgrade job,
that pod will never have the same name as `tableau-server-primary-0`.
That is because of the way k8s names pods using a seemingly random string as a suffix.
Since Tableau Server relies on the names of the pods (i.e. the hostnames) for connectivity within the cluster,
the worker nodes will never be able to connect to the upgrade image container,
because they will keep trying to reach it with the original primary node hostname `tableau-server-primary-0`.
And alternative to a job could be to replace the image of the primary node stateful set with the upgrade image.
That way, the hostname would be the same, and the cluster would converge to a fully functional state,
a requirement for the upgrade.

Leaning on the side of immutable infrastructure, the method we use to upgrade Tableau Server is the backup and restore.
To do that, we provision a completely new cluster and then restore a backup for the previous cluster in it.
