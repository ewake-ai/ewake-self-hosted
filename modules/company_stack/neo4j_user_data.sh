#!/bin/bash
# Bootstraps a Neo4j 5 Community node on Amazon Linux 2023. Idempotent so a
# reboot re-runs cleanly. Deliberately NOT `set -x` — the initial-password
# block runs a command substitution that would otherwise be echoed into
# /var/log/cloud-init-output.log with the password expanded.
set -euo pipefail

# Install OpenJDK 17 + Neo4j 5 Community (noarch RPM works on arm64), plus
# awscli-2 for the boot-time password fetch below. `neo4j` is pinned to the
# 5.26 LTS line so fresh company stacks don't drift to whatever 5.x is
# current the day they're applied.
rpm --import https://debian.neo4j.com/neotechnology.gpg.key
cat > /etc/yum.repos.d/neo4j.repo <<EOF
[neo4j]
name=Neo4j RPM Repository
baseurl=https://yum.neo4j.com/stable/5
enabled=1
gpgcheck=1
gpgkey=https://debian.neo4j.com/neotechnology.gpg.key
EOF
dnf install -y java-17-amazon-corretto-headless awscli-2 amazon-ssm-agent
dnf install -y 'neo4j-5.26.*'

# SSM Agent is stripped from `-minimal-` AL2023 AMIs; install + enable it so
# operators can `aws ssm start-session` for debugging without opening SSH.
systemctl enable --now amazon-ssm-agent

# Resolve the data volume by its EBS volume ID, not a kernel device name.
# Nitro enumerates it as nvme1n1, nvme2n1, … depending on attach order, so a
# hardcoded name can point at the wrong disk — which is how a hot re-attach on
# a running box led to mkfs formatting an empty volume once. The by-id symlink
# (serial = volume ID without the dash) always targets exactly this volume.
DATA_DEV="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${data_volume_serial}"
until [ -b "$DATA_DEV" ]; do sleep 2; done

# Format only if the volume has no filesystem yet. Guards a re-attached volume
# that already carries a graph from being wiped on a later boot.
if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
  mkfs.xfs -L neo4jdata "$DATA_DEV"
fi

mkdir -p /var/lib/neo4j/data
if ! grep -q "^LABEL=neo4jdata" /etc/fstab; then
  echo "LABEL=neo4jdata /var/lib/neo4j/data xfs defaults,noatime,nofail 0 2" >> /etc/fstab
fi
mountpoint -q /var/lib/neo4j/data || mount /var/lib/neo4j/data

# chown before the initial-password block. mkfs.xfs + mount leaves the mount
# root owned by root, so `runuser -u neo4j -- neo4j-admin dbms
# set-initial-password` would AccessDeniedException on data/dbms/. Doing it
# once here up-front means the neo4j user can create everything it needs
# (auth.ini, then the store dirs when the systemd unit starts). A second
# `chown -R` after would just paper over the failure the first time round.
chown -R neo4j:neo4j /var/lib/neo4j/data

# Bolt binds localhost by default; make it reachable inside the VPC.
sed -i \
  -e 's|^#\?server.default_listen_address=.*|server.default_listen_address=0.0.0.0|' \
  /etc/neo4j/neo4j.conf

# Fetch the initial password from Secrets Manager via the EC2 instance
# profile and hand it straight to neo4j-admin. Two properties matter:
#   1. Running under `runuser -u neo4j` so `data/dbms/auth.ini` lands
#      neo4j-owned on the EBS mount (root-owned auth.ini would block the
#      systemd unit's later writes).
#   2. Command substitution — the password only lives on neo4j-admin's argv,
#      never in a shell variable, never on disk. Combined with `set -x` being
#      off, it never appears in /var/log/cloud-init-output.log.
# `set-initial-password` is a no-op on subsequent boots, so unconditional
# invocation is safe.
runuser -u neo4j -- bash -c \
  "neo4j-admin dbms set-initial-password \"\$(aws secretsmanager get-secret-value \
    --region '${aws_region}' \
    --secret-id '${password_secret_id}' \
    --query SecretString --output text)\"" || true

# Refuse to start neo4j unless the data volume is mounted. `nofail` in fstab
# lets the box boot when the volume is slow, renamed, or absent — but without
# this drop-in neo4j would then start and write the graph to the ROOT disk,
# which has delete_on_termination=true. That data never reaches the EBS volume
# (so it's not in any snapshot) and vanishes silently on the next instance
# replacement. RequiresMountsFor pins neo4j.service to the mount: no mount →
# neo4j stays down and visible (the KG availability probe logs it), never
# writing to the wrong disk.
mkdir -p /etc/systemd/system/neo4j.service.d
cat > /etc/systemd/system/neo4j.service.d/10-require-data-mount.conf <<'EOF'
[Unit]
RequiresMountsFor=/var/lib/neo4j/data
EOF
systemctl daemon-reload

systemctl enable --now neo4j
