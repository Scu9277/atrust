#!/bin/bash
# collect_aTrust_license.sh
set -e

O="./aTrust_license_bundle_`date +%Y%m%d_%H%M%S`.tar.gz"
T=`mktemp -d`
trap "rm $T/*.txt $T/*.json $T/license/* 2>/dev/null; rmdir $T/license 2>/dev/null; rmdir $T 2>/dev/null" EXIT

echo "Collecting aTrust license data..."

# Device info
cat /etc/machine-id >$T/machine_id.txt 2>/dev/null
cat /sys/class/dmi/id/product_uuid >$T/product_uuid.txt 2>/dev/null
cat /sys/class/net/eth0/address >$T/mac.txt 2>/dev/null
hostname >$T/hostname.txt 2>/dev/null

# Server config
cp /app/.server.json $T/server.json 2>/dev/null || true

# License files
LID="/app/.info/license"
if [ -d "$LID" ]; then
    mkdir $T/license 2>/dev/null || true
    for f in sf_license.lic sf_license.lic.original sflicense_version sf_license_conf.json product_name; do
        [ -f "$LID/$f" ] && cp "$LID/$f" $T/license/
    done
fi

# etcd data
/usr/local/bin/etcdctl get /config/private/license/local --print-value-only >$T/etcd_license.json 2>/dev/null || true

# Timestamp
date +%s >$T/current_epoch.txt
date >$T/current_date.txt

# Package
tar -czf "$O" -C $T .

echo "Done! Bundle created: $O"
echo "Upload to GitHub Release, then run deploy script on target."
echo ""
ls -la "$O"
