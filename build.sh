# start an amazonlinux image on a cluster
kubectl run tableau-server-builder --rm -it --image amazonlinux:latest -- bin/bash

# Install packages
yum install -y tar docker


# local
 docker run -it --rm -v $PWD:/tableau-server -v /var/run/docker.sock:/var/run/docker.sock amazonlinux:latest
