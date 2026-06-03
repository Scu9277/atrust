#!/bin/bash
# deploy_aTrust_license.sh
# aTrust License One-Click Deploy Tool
set -e

BUNDLE_URL="https://raw.githubusercontent.com/Scu9277/atrust/refs/heads/main/lic/aTrust_license_bundle_20260604_002445.tar.gz"

if [ "$(id -u)" != "0" ]; then
    echo "Please run as root!"
    exit 1
fi

echo "======================================"
echo "  aTrust License Deploy Tool"
echo "======================================"

BUNDLE="$1"
if [ -z "$BUNDLE" ]; then
    BUNDLE="$BUNDLE_URL"
fi

if echo "$BUNDLE" | grep -q "^https\?://"; then
    echo "Downloading license bundle..."
    wget -q --show-progress "$BUNDLE" -O /tmp/atrust_bundle.tar.gz || exit 1
    BF="/tmp/atrust_bundle.tar.gz"
else
    BF="$BUNDLE"
    [ -f "$BF" ] || { echo "File not found"; exit 1; }
fi

echo "Extracting..."
TMP=`mktemp -d`
tar -xzf "$BF" -C "$TMP"

MID=`cat "$TMP/machine_id.txt" 2>/dev/null`
MAC=`cat "$TMP/mac.txt" 2>/dev/null`
HOST=`cat "$TMP/hostname.txt" 2>/dev/null`

echo "Target: MID=$MID MAC=$MAC HOST=$HOST"

# Step 1: Machine ID
echo "[1/5] Setting Machine ID..."
echo "$MID" > /etc/machine-id
echo "$MID" > /var/lib/dbus/machine-id 2>/dev/null || true

# Step 2: MAC
echo "[2/5] Setting MAC address..."
CM=`cat /sys/class/net/eth0/address 2>/dev/null`
if [ "$CM" != "$MAC" ]; then
    mkdir -p /etc/systemd/network
    cat > /etc/systemd/network/10-eth0.link << EOFLINK
[Match]
MACAddress=$CM
[Link]
MACAddress=$MAC
Name=eth0
EOFLINK
    ip link set dev eth0 down 2>/dev/null || true
    ip link set dev eth0 address "$MAC" 2>/dev/null || true
    ip link set dev eth0 up 2>/dev/null || true
fi

# Step 3: License files
echo "[3/5] Restoring license files..."
if [ -d "$TMP/license" ]; then
    [ -d "/app/.info/license" ] && cp -r /app/.info/license /app/.info/license.bak.`date +%s` 2>/dev/null || true
    mkdir -p /app/.info/license
    cp "$TMP/license/"* /app/.info/license/ 2>/dev/null || true
    chmod -R 755 /app/.info/license 2>/dev/null || true
fi

# Step 4: etcd
echo "[4/5] Restoring etcd data..."
if [ -f "$TMP/etcd_license.json" ] && command -v /usr/local/bin/etcdctl &>/dev/null; then
    /usr/local/bin/etcdctl put /config/private/license/local "`cat $TMP/etcd_license.json`" 2>/dev/null || echo "etcd write failed"
fi

# Step 5: Time
echo "[5/5] Setting time to 2100..."
systemctl stop ntpd chronyd systemd-timesyncd 2>/dev/null || true
systemctl disable ntpd chronyd systemd-timesyncd 2>/dev/null || true
date -s "2100-01-01 00:00:00" 2>/dev/null || date --set="2100-01-01 00:00:00" 2>/dev/null || true
hwclock -w 2>/dev/null || hwclock --systohc 2>/dev/null || true

# Restart service
docker restart sdp-license-confd 2>/dev/null || true

# Cleanup
echo "Cleaning up..."
rm "$TMP/etcd_license.json" 2>/dev/null || true
rm "$TMP/machine_id.txt" 2>/dev/null || true
rm "$TMP/mac.txt" 2>/dev/null || true
rm "$TMP/product_uuid.txt" 2>/dev/null || true
rm "$TMP/hostname.txt" 2>/dev/null || true
rm "$TMP/server.json" 2>/dev/null || true
rm "$TMP/current_epoch.txt" 2>/dev/null || true
rm "$TMP/current_date.txt" 2>/dev/null || true
rm "$TMP/network_interfaces.txt" 2>/dev/null || true
rm "$TMP/license/sf_license.lic" 2>/dev/null || true
rm "$TMP/license/sf_license.lic.original" 2>/dev/null || true
rm "$TMP/license/sflicense_version" 2>/dev/null || true
rm "$TMP/license/sf_license_conf.json" 2>/dev/null || true
rm "$TMP/license/product_name" 2>/dev/null || true
rmdir "$TMP/license" 2>/dev/null || true
rmdir "$TMP" 2>/dev/null || true
rm /tmp/atrust_bundle.tar.gz 2>/dev/null || true
rm "$0" 2>/dev/null || true

echo "Done! Time: `date`"
