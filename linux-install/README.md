# Container images

Tableau Server container images can be built using the tools provided by tableau.
The instructions from Tableau on how to build the container images are under
[this link](https://help.tableau.com/current/server-linux/en-us/server-in-container_setup-tool.htm).

The Tableau Server container images we are building are meant for running it in Kubernetes.
There is a Kubernetes deployment reference implementation
in [this repository](https://github.com/tableau/tableau-server-in-kubernetes).
However, the 3-node deployment proposed in that implementation defines three stateful sets, one per node.
Having three different stateful sets allows for different pod templates,
which in turn enables assigning different license keys, and even different resources, to each node of the cluster.
The implementation we propose via the [helm chart provided in this repository](../helm-chart),
uses two stateful sets: one for the primary node, and another for both worker nodes.
Splitting the primary node from the workers allows us to assign different resources and tolerations to the primary node.
Unlike the [Three-node System topology](https://help.tableau.com/current/server/en-us/distrib_ha_install_3node.htm)
proposed in the Tableau Server HA installation documentation, in the Tableau Server topology we are implementing
the primary node only runs a handful of non-licensed Tableau Server processes,
while the worker nodes run all the other processes that are needed to have a functional Tableau Server.
The topology is displayed in the [3-node-topology.png diagram](../docs/images/3-node-topology.png),
where the primary node only runs the processes highlighted in the red boxes.

[This page](https://help.tableau.com/current/server-linux/en-us/server-in-container_image.htm) explains
how to configure many aspects of image building and image execution.

### Build container images

Download two files from the [Tableau Server releases page](http://tableau.com/support/releases/server/latest)
(the version for both files does not need to be exactly the same, but as close as possible)
into [linux-install](./):

- The tableau server package: `tableau-server-<server-version>.rpm`
- The container setup tool: `tableau-server-container-setup-tool-<container-setup-version>.tar.gz`
- Any drivers that are needed from the [drivers page](https://www.tableau.com/support/drivers).
  Place the downloaded drivers under `linux-install/drivers`.
  To install the drivers, follow the instructions provided by Tableau for each of the drivers you download.
  The installation instructions need to be coded in a script.
  That scrip needs to be copied to `customer-files/setup-script`.
  For JDBC drivers, create a directory structure within `linux-install/drivers`,
  separating each connector driver in it's own directory.
  The `setup-script` script will copy all JDBC drivers to the build environment.
  For other types of drivers,
  please append the required commands to the `setup-script` script for completing the installation.
  There is a [GitHub repository on the Tableau organization](https://github.com/tableau/container_image_builder) that
  contains scripts to download many types of drivers.
  NB: We tested several AWS Athena drivers
  and [this (older) version](https://s3.amazonaws.com/athena-downloads/drivers/JDBC/SimbaAthenaJDBC-2.0.32.1000/AthenaJDBC42.jar)
  seems to be the one that works the best.

At the time of writing, the latest version is 2023.3.2,
however, the latest version of the container setup tool is 2023.3.0.

```bash
server_version=2023.3.2
container_setup_version=2023.3.0
```

Unpack the container setup tool, that will create a new directory under [linux-install](./).
Within the new directory there will be a file called `reg-info.json` that needs to be filled in.
Edit that file with your registration details.

Start the image building process using the script provided in the setup tool package.
While building the image,
we will get an error saying that the machine we are building it in doesn't meet the specs for running tableau.
The message also says to pass a parameter to an underlying build script,
but the script we run doesn't have a way to do that.
Another thing that can happen is that we customise the build environment according
to [the documentation](https://help.tableau.com/current/server-linux/en-us/server-in-container_setup-tool.htm)
(see "Customizing the image").
The documentation says that we can't customise a few environment variables at build-time.
However, the build tool does not support customizing those values,
and the resulting image won't work since at runtime there will a mismatch between the GUIs and UIDs
that are set and the ones that are hardcoded in the build script.

#### Fix the build script for building in an environment that doesn't have production-grade capacity

Before we start the installation we need to edit a script named `install-process-manager`,
and add a `-f` flag to the command `initialize-tsm`.
The script should be under `tableau-server-container-setup-tool-${container_setup_version}/image/docker/`.

### Fix hardcoded environment variables in build script

Edit the `linux-install/tableau-server-container-setup-tool-${container_setup_version}/build-utils` file
and add the needed variables to the `add_args_to_dockerfile` function.
For our needs we are customising the UID and GUIds, so we add 3 new variables to the variables array.

Before:

```bash
  env_array=( [UNPRIVILEGED_USERNAME]=unprivilegedUsername \
              [UNPRIVILEGED_GROUP_NAME]=unprivilegedGroupName \
              [BASE_IMAGE_URL]=baseImageURL )
```

After:

```bash
  env_array=( [UNPRIVILEGED_USERNAME]=unprivilegedUsername \
              [UNPRIVILEGED_GROUP_NAME]=unprivilegedGroupName \
              [BASE_IMAGE_URL]=baseImageURL \
              [PRIVILEGED_TABLEAU_GID]=privilegedTableauGid \
              [UNPRIVILEGED_TABLEAU_GID]=unprivilegedTableauGid \
              [UNPRIVILEGED_TABLEAU_UID]=unprivilegedTableauUid )
```

Then edit the Dockerfile `linux-install/tableau-server-container-setup-tool-${container_setup_version}/image/Dockerfile`
to define the enw build args.

Before:

```dockerfile
ARG eulaAccepted
ARG installerFile
ARG versionString
ARG serviceName
ARG unprivilegedUsername=tableau
ARG unprivilegedGroupName=tableau
```

After:

```dockerfile
ARG eulaAccepted
ARG installerFile
ARG versionString
ARG serviceName
ARG unprivilegedUsername=tableau
ARG unprivilegedGroupName=tableau
ARG privilegedTableauGid=997
ARG unprivilegedTableauGid=998
ARG unprivilegedTableauUid=999
```

Replace the hardcoded values by the variables.

Before

```dockerfile
ENV CONTAINER_ENABLED=1 \
    ...
    PRIVILEGED_TABLEAU_GID=997 \
    UNPRIVILEGED_TABLEAU_GID=998 \
    UNPRIVILEGED_TABLEAU_UID=999 \
    UNPRIVILEGED_USERNAME=${unprivilegedUsername} \
    UNPRIVILEGED_GROUP_NAME=${unprivilegedGroupName} \
    ...
```

After

```dockerfile
ENV CONTAINER_ENABLED=1 \
    ...
    PRIVILEGED_TABLEAU_GID=${privilegedTableauGid} \
    UNPRIVILEGED_TABLEAU_GID=${unprivilegedTableauGid} \
    UNPRIVILEGED_TABLEAU_UID=${unprivilegedTableauUid} \
    UNPRIVILEGED_USERNAME=${unprivilegedUsername} \
    UNPRIVILEGED_GROUP_NAME=${unprivilegedGroupName} \
    ...
```

Finally,
add a `chwon` command to the dockerfile `linux-install/tableau-server-container-setup-tool-${container_setup_version}/image/Dockerfile`.

Before

```dockerfile
RUN ${DOCKER_CONFIG}/install-process-manager
```

After

```dockerfile
RUN ${DOCKER_CONFIG}/install-process-manager \
    && chown -R ${UNPRIVILEGED_USERNAME}:${UNPRIVILEGED_GROUP_NAME} /var/opt/tableau \
    && mkdir -p /var/opt/tableau/tableau_driver \
    && chmod -R 0755 /var/opt/tableau/tableau_driver
```

#### Build image

```bash
cd linux-install

# Copy files to customer-files
cp -f customer-files/* tableau-server-container-setup-tool-${container_setup_version}/customer-files/

# If you are running on a platform different from linux/amd64
# you need to set the platform for docker build to use
export DOCKER_DEFAULT_PLATFORM=linux/amd64

# If you are on linux, skip the following command
# otherwise, run it to start a container with the required cli tools to run the image build script
docker run -it --rm --platform=linux/amd64 \
    -e server_version=${server_version} \
    -e container_setup_version=${container_setup_version} \
    -e DOCKER_DEFAULT_PLATFORM=linux/amd64 \
    -v $PWD:/tableau-server-install \
    -v /var/run/docker.sock:/var/run/docker.sock \
    redhat/ubi8:8.6

# Install docker
yum install -y yum-utils
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin

cd /tableau-server-install/tableau-server-container-setup-tool-${container_setup_version}
./build-image --accepteula -i ../tableau-server-${server_version//./-}.x86_64.rpm -o ghcr.io/gresb/tableau-server:latest -e ../build-environment

# If you are not building on linux and have started a build container
exit

# Push the image we just built, without tagging it with a specific version
# This command requires login to ECR (and can be executed outside the build container started with `docker run`)
docker login ...
docker push ghcr.io/gresb/tableau-server:latest
```
