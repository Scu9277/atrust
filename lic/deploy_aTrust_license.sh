#!/bin/bash
# deploy_aTrust_license.sh
set -e

if [ "$(id -u)" != "0" ]; then echo "Need root"; exit 1; fi

BUNDLE="$1"
if [ -z "$BUNDLE" ]; then echo "Usage: $0 <file_or_url>"; exit 1; fi

if echo "$BUNDLE" | grep -q "^https\?://"; then
    wget -q "$BUNDLE" -O /tmp/atrust_bundle.tar.gz
    BUNDLE="/tmp/atrust_bundle.tar.gz"
fi

TMP=`mktemp -d`
tar -xzf "$BUNDLE" -C "$TMP"

MID=`cat "$TMP/machine_id.txt" 2>/dev/null`
MAC=`cat "$TMP/mac.txt" 2>/dev/null`

echo "[1/5] Machine ID..."
echo "$MID" > /etc/machine-id
echo "$MID" > /var/lib/dbus/machine-id 2>/dev/null || true

echo "[2/5] MAC address..."
ip link set dev eth0 down 2>/dev/null || true
ip link set dev eth0 address "$MAC" 2>/dev/null || true
ip link set dev eth0 up 2>/dev/null || true

echo "[3/5] License files..."
if [ -d "$TMP/license" ]; then
    mkdir -p /app/.info/license
    cp "$TMP/license/"* /app/.info/license/ 2>/dev/null || true
    chmod -R 755 /app/.info/license 2>/dev/null || true
fi

echo "[4/5] etcd data..."
if [ -f "$TMP/etcd_license.json" ] && command -v /usr/local/bin/etcdctl &>/dev/null; then
    /usr/local/bin/etcdctl put /config/private/license/local "`cat $TMP/etcd_license.json`" 2>/dev/null || true
fi

echo "[5/5] Setting time to 2100..."
systemctl stop ntpd chronyd systemd-timesyncd 2>/dev/null || true
date -s "2100-01-01 00:00:00" 2>/dev/null || date --set="2100-01-01 00:00:00"
hwclock -w 2>/dev/null || hwclock --systohc 2>/dev/null || true

# Cleanup and self-destruct
rm "$TMP/etcd_license.json" 2>/dev/null || true
rm "$TMP/machine_id.txt" 2>/dev/null || true
rm "$TMP/mac.txt" 2>/dev/null || true
rm "$TMP/product_uuid.txt" 2>/dev/null || true
rm "$TMP/server.json" 2>/dev/null || true
rm /tmp/atrust_bundle.tar.gz 2>/dev/null || true
rm "$0" 2>/dev/null || true

echo "Done! date: `date`"
