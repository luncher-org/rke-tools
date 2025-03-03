#!/bin/bash

set -x

# Evaluate the iptables mode every time the container starts (fixes OS upgrades changing mode)
if [ "$1" = "kubelet" ] || [ "$1" = "kube-proxy" ]; then
  update-alternatives --set iptables /usr/sbin/iptables-wrapper
fi

# br_netfilter is required for canal and flannel network plugins.
if [ "$1" = "kube-proxy" ] && [ "${RKE_KUBE_PROXY_BR_NETFILTER}" = "true" ]; then
    modprobe br_netfilter || true
fi

# generate Azure cloud provider config if configured
if echo ${@} | grep -q "cloud-provider=azure"; then
  if [ "$1" = "kubelet" ] || [ "$1" = "kube-apiserver" ] || [ "$1" = "kube-controller-manager" ]; then
    source /opt/rke-tools/cloud-provider.sh
    set_azure_config
    # If set_azure_config is called debug needs to be turned back on
    set -x
  fi
fi

# In case of AWS cloud provider being configured, RKE will not set `hostname-override` flag because it needs to match the node/instance name in AWS.
# This will query EC2 metadata and use the value for setting `hostname-override` to match the node/instance name.
# RKE pull request: https://github.com/rancher/rke/pull/2803
if [ "$1" = "kube-proxy" ] || [ "$1" = "kubelet" ]; then
  if echo ${@} | grep -v "hostname-override"; then
    aws_api_token=$(curl -X PUT "http://169.254.169.254/latest/api/token"  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
    hostname=$(curl -H "X-aws-ec2-metadata-token: $aws_api_token" "http://169.254.169.254/latest/meta-data/hostname")
    if [ -z "$hostname" ]; then
        hostname=$(hostname -f)
    fi
    set ${@} --hostname-override=$hostname
  fi
fi

# Prepare kubelet for running inside container
if [ "$1" = "kubelet" ]; then
    CGROUPDRIVER=$(/opt/rke-tools/bin/docker info -f '{{.Info.CgroupDriver}}')
    CGROUPVERSION=$(/opt/rke-tools/bin/docker info -f '{{.Info.CgroupVersion}}')
    DOCKER_ROOT=$(DOCKER_API_VERSION=1.24 /opt/rke-tools/bin/docker info -f '{{.Info.DockerRootDir}}')
    DOCKER_DIRS=$(find -O1 $DOCKER_ROOT -maxdepth 1) # used to exclude mounts that are subdirectories of $DOCKER_ROOT to ensure we don't unmount mounted filesystems on sub directories
    for i in $DOCKER_ROOT /var/lib/docker /run /var/run; do
        for m in $(tac /proc/mounts | awk '{print $2}' | grep ^${i}/); do
            if [ "$m" != "/var/run/nscd" ] && [ "$m" != "/run/nscd" ] && ! echo $DOCKER_DIRS | grep -qF "$m"; then
                umount $m || true
            fi
        done
    done
    mount --rbind /host/dev /dev
    mount -o rw,remount /sys/fs/cgroup 2>/dev/null || true

    # Only applicable to cgroup v1
    if [ "${CGROUPVERSION}" -eq 1 ]; then
      for i in /sys/fs/cgroup/*; do
        if [ -d $i ]; then
          mkdir -p $i/kubepods
        fi
      done

      mkdir -p /sys/fs/cgroup/cpuacct,cpu/
      mount --bind /sys/fs/cgroup/cpu,cpuacct/ /sys/fs/cgroup/cpuacct,cpu/
      mkdir -p /sys/fs/cgroup/net_prio,net_cls/
      mount --bind /sys/fs/cgroup/net_cls,net_prio/ /sys/fs/cgroup/net_prio,net_cls/
    fi

    # If we are running on SElinux host, need to:
    mkdir -p /opt/cni /etc/cni
    chcon -Rt svirt_sandbox_file_t /etc/cni 2>/dev/null || true
    chcon -Rt svirt_sandbox_file_t /opt/cni 2>/dev/null || true

    # Set this to 1 as required by network plugins
    # https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/#network-plugin-requirements
    sysctl -w net.bridge.bridge-nf-call-iptables=1 || true

    # Mount host os-release so kubelet can report the correct OS
    if [ -f /host/usr/lib/os-release ]; then
        ln -sf /host/usr/lib/os-release /usr/lib/os-release
    elif [ -f /host/etc/os-release ]; then
        ln -sf /host/etc/os-release /usr/lib/os-release
    elif [ -f /host/usr/share/ros/os-release ]; then
        ln -sf /host/usr/share/ros/os-release /usr/lib/os-release
    fi

    # Check if no other or additional resolv-conf is passed (default is configured as /etc/resolv.conf)
    if echo "$@" | grep -q -- --resolv-conf=/etc/resolv.conf; then
        # Check if host is running `system-resolved`
        if pgrep -f systemd-resolved > /dev/null; then
            # Check if the resolv.conf with the actual nameservers is present
            if [ -f /run/systemd/resolve/resolv.conf ]; then
                RESOLVCONF="--resolv-conf=/run/systemd/resolve/resolv.conf"
            fi
        fi
    fi

    if [ ! -z "${RKE_KUBELET_DOCKER_CONFIG}" ]
    then
      echo ${RKE_KUBELET_DOCKER_CONFIG} | base64 -d | tee ${RKE_KUBELET_DOCKER_FILE}
    fi

    # separate flow for cri-dockerd to minimize change to the existing way we run kubelet
    if [ "${RKE_KUBELET_CRIDOCKERD}" == "true" ]; then

        # Mount kubelet docker config to /.docker/config.json
        if [ ! -z "${RKE_KUBELET_DOCKER_CONFIG}" ]
        then
          mkdir -p /.docker && touch /.docker/config.json
          mount --bind ${RKE_KUBELET_DOCKER_FILE} /.docker/config.json
        fi

        # Get the value of pause image to start cri-dockerd
        RKE_KUBELET_PAUSEIMAGE=$(echo "$@" | grep -Eo "\-\-pod-infra-container-image+.*" | awk '{print $1}')
        CONTAINER_RUNTIME_ENDPOINT=$(echo "$@" | grep -Eo "\-\-container-runtime-endpoint+.*" | awk '{print $1}' | cut -d "=" -f2)
        if [ "$CONTAINER_RUNTIME_ENDPOINT" == "/var/run/dockershim.sock" ]; then
          # cri-dockerd v0.3.11 requires unix socket or tcp endpoint, update old endpoint passed by rke
          CONTAINER_RUNTIME_ENDPOINT="unix://$CONTAINER_RUNTIME_ENDPOINT"
        fi
        EXTRA_FLAGS=""
        if [ "${RKE_KUBELET_CRIDOCKERD_DUALSTACK}" == "true" ]; then
          EXTRA_FLAGS="--ipv6-dual-stack"
        fi
        if [ -z "${CRIDOCKERD_STREAM_SERVER_ADDRESS}" ]; then
          CRIDOCKERD_STREAM_SERVER_ADDRESS="127.0.0.1"
        fi
        if [ -z "${CRIDOCKERD_STREAM_SERVER_PORT}" ]; then
          CRIDOCKERD_STREAM_SERVER_PORT="10010"
        fi
        
        /opt/rke-tools/bin/cri-dockerd --network-plugin="cni" --cni-conf-dir="/etc/cni/net.d" --cni-bin-dir="/opt/cni/bin" ${RKE_KUBELET_PAUSEIMAGE} --container-runtime-endpoint=$CONTAINER_RUNTIME_ENDPOINT --streaming-bind-addr=${CRIDOCKERD_STREAM_SERVER_ADDRESS}:${CRIDOCKERD_STREAM_SERVER_PORT} ${EXTRA_FLAGS} &

        # wait for cri-dockerd to start as kubelet depends on it
        echo "Sleeping 10 waiting for cri-dockerd to start"
        sleep 10

        # start kubelet
        exec "$@" --cgroup-driver=$CGROUPDRIVER $RESOLVCONF &

        # waiting for either cri-dockerd or kubelet to crash and exit so it can be restarted
        wait -n
        exit $?
    else
        # start kubelet
        exec "$@" --cgroup-driver=$CGROUPDRIVER $RESOLVCONF
    fi
fi

exec "$@"
