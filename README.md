# tableau-server

Everything we need to run Tableau Server on kubernetes

Links:

- https://help.tableau.com/current/server/en-us/distrib_ha_install_3node.htm
- https://help.tableau.com/current/server-linux/en-us/server-in-container.htm
- https://help.tableau.com/current/server-linux/en-us/server-in-container_image.htm

## Licenses

licenses can be downloaded from the Tableau Customer Portal.

## Container images

Tableau does not provide Tableau server cotnaienr images.
What they do provide is a tool to build those imagees.
Instructions on how to build such an image can be found in the [linux-install README.md](linux-install/README.md) on
this repository.

## Provisioning

When provisioning a Tableau Server cluster we need
to do a few helm install/upgrade while issuing some commands on the primary node in between.

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
On the first installation, we need to disable the liveness and readiness probles for the worker pods.
We need to do that because these probes will not respond successfuly until the cluster is configured and operational.
That would mean there would only be one worker pod,
since the underlying StatefulSet would not schedule the second until the first is alive and ready.

To install Tableau Server without the pod probes for the workers, we manipulate a helm value `worker.probe.enabled`.

```bash
helm upgrade --install -n tableau tableau-server-helm helm-chart --set worker.probe.enabled=false
```

After the helm installation, there should be three running pods,
where one is the primary node, and the other two are the workers.
The workers will boot up and wait for a bootstrap file that the primary creates in a shared volume
(we use EFS for that volume, but other options are possible, PRs are welcome for adding those).
Once the boostrap file is available to the workers, they will complete their own installation.

If for any reason the primary pod does not create the bootstrap file automatically,
use the following Tableau Server Management command, on the primary pod, to generate it.
Please keep in mind that if the primary pod does not automatically create the bootstrap file for the workers,
that could be a sing that the primary pod is not well setup.

```bash
tsm topology nodes get-bootstrap-file -f /docker/config/bootstrap/bootstrap.json
```

#### Useful commands to inspect the state of the pods

On boostrap, Tableau Server on each of the pods will install some components.
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
This topology is good when dynamic scaling is needed,
because then the horizontal pod autoscaler can be configured to schedule more worker nodes when needed.
This topology can't be used with a core-based license because for those types of licenses, the capacity used
(ie. the number of pods) needs to align with the contracted licenses,
and therefore scaling can't be dynamic unless licenses are purchased upfront.

For core-based licenses,
like the ones GRESB has, Tableau recommends a topology where the primary node runs a minimal set of Tableau Server
processes, while the workers run the full set of Tableau Server processes.
This topology is depicted in the "Node 1" configuration in the [3-node-topology](docs/images/3-node-topology.png)
diagram.
The primary node, is configured with the processes that are marked in red on "Node 1",
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

### Enable pod probes for worker nodes

NOTE:

- figure out if we can scale down the primary node resources since it doesn't need to run a full set of Tableau Server
  processes.
- figure out how we assign licenses since primary pod isn't running any licenses processes.

To finalise the installation, we need to enable the pod probes for the worker nodes.
We can do that by updating the helm release.

```bash
helm upgrade --install -n tableau tableau-server-helm helm-chart --set worker.probe.enabled=true
```

### Other

DB user access was too restrictive

/var/opt/tableau/tableau_server/data/tabsvc/config/pgsql_0.20233.23.1017.0948/pg_hba.conf

```bash
# Was
#  host    all         datacatdbowner           10.1.101.229/32          md5
#  host    all         tbladminviews           10.1.101.229/32          md5
#  host    all         tblserveradminviews    10.1.101.229/32          md5
#  host    all         datafetcheruser1        10.1.101.229/32          md5
#  host    all         analyseruser1           10.1.101.229/32          md5
#  host    all         nopiireaderuser1        10.1.101.229/32          md5
#  host    all         insightsuser1    10.1.101.229/32          md5
#  host    all         rails           10.1.101.229/32          md5
#  host    all         tblwgadmin     10.1.101.229/32          md5
#  host    all         datacatdbowner           10.1.102.159/32          md5
#  host    all         tbladminviews           10.1.102.159/32          md5
#  host    all         tblserveradminviews    10.1.102.159/32          md5
#  host    all         datafetcheruser1        10.1.102.159/32          md5
#  host    all         analyseruser1           10.1.102.159/32          md5
#  host    all         nopiireaderuser1        10.1.102.159/32          md5
#  host    all         insightsuser1    10.1.102.159/32          md5
#  host    all         rails           10.1.102.159/32          md5
#  host    all         tblwgadmin     10.1.102.159/32          md5
#  host    all         datacatdbowner           10.1.102.133/32          md5
#  host    all         tbladminviews           10.1.102.133/32          md5
#  host    all         tblserveradminviews    10.1.102.133/32          md5
#  host    all         datafetcheruser1        10.1.102.133/32          md5
#  host    all         analyseruser1           10.1.102.133/32          md5
#  host    all         nopiireaderuser1        10.1.102.133/32          md5
#  host    all         insightsuser1    10.1.102.133/32          md5
#  host    all         rails           10.1.102.133/32          md5
#  host    all         tblwgadmin     10.1.102.133/32          md5

# Open
host    all         datacatdbowner           10.1.100.0/22          md5
host    all         tbladminviews           10.1.100.0/22          md5
host    all         tblserveradminviews    10.1.100.0/22          md5
host    all         datafetcheruser1        10.1.100.0/22          md5
host    all         analyseruser1           10.1.100.0/22          md5
host    all         nopiireaderuser1        10.1.100.0/22          md5
host    all         insightsuser1    10.1.100.0/22          md5
host    all         rails           10.1.100.0/22          md5
host    all         tblwgadmin     10.1.100.0/22          md5
host    all         datacatdbowner           10.1.100.0/22          md5
host    all         tbladminviews           10.1.100.0/22          md5
host    all         tblserveradminviews    10.1.100.0/22          md5
host    all         datafetcheruser1        10.1.100.0/22          md5
host    all         analyseruser1           10.1.100.0/22          md5
host    all         nopiireaderuser1        10.1.100.0/22          md5
host    all         insightsuser1    10.1.100.0/22          md5
host    all         rails           10.1.100.0/22          md5
host    all         tblwgadmin     10.1.100.0/22          md5
host    all         datacatdbowner           10.1.100.0/22          md5
host    all         tbladminviews           10.1.100.0/22          md5
host    all         tblserveradminviews    10.1.100.0/22          md5
host    all         datafetcheruser1        10.1.100.0/22          md5
host    all         analyseruser1           10.1.100.0/22          md5
host    all         nopiireaderuser1        10.1.100.0/22          md5
host    all         insightsuser1    10.1.100.0/22          md5
host    all         rails           10.1.100.0/22          md5
host    all         tblwgadmin     10.1.100.0/22          md5
```
