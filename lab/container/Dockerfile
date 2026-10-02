# Containerized test NAS for the OpenShift -> NAS IPsec guide:
# an NFSv4 server behind libreswan (IKEv2, transport mode, certificate authentication).
#
# CentOS Stream 10 is the public upstream of RHEL 10, so the packages match lab/rhel/setup-nas.sh.
FROM quay.io/centos/centos:stream10

RUN dnf -y install libreswan nfs-utils nss-tools nftables iproute \
    && dnf clean all

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
