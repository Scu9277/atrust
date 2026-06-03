#!/bin/bash
# =============================================================================
# Duang 授权工具脚本
# 适用于 aTrust / PlatOS (aTrust_HYBRID) 系统
#
# 脚本和授权包分开放 GitHub，脚本自动检测/下载授权包
# =============================================================================
# 使用方法:
#   bash duang_license_tool.sh --apply         自动下载+还原授权
#   bash duang_license_tool.sh --collect       收集本机信息
#   bash duang_license_tool.sh --pack          打包授权数据（在已授权机器上）
#   bash duang_license_tool.sh --backup        备份当前授权
#   bash duang_license_tool.sh --restore <包>  从本地包还原
# =============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1"; }

# ============================================================
# 配置区 — 改成你自己的 GitHub 仓库地址
# ============================================================
LICENSE_URL="https://github.com/Scu9277/atrust/raw/refs/heads/main/duang-license-package.tar.gz"
# ============================================================

# 本地授权包路径
LOCAL_PACK="/root/duang-license-pack.tar.gz"

ETCDCTL="/usr/local/bin/etcdctl"
LICENSE_DIR="/app/.info/license"
BACKUP_DIR="/root/duang_license_backup"
DAEMON_CONFIG="/app/docker-app/sdp-license-confd/config/config.prod.json"

get_etc_data() {
    ${ETCDCTL} get /config/private/license/local --print-value-only 2>/dev/null || echo ""
}

check_etcd() {
    ${ETCDCTL} get / --prefix --keys-only --limit 1 2>/dev/null || return 1
    return 0
}

get_container_id() {
    docker ps --format '{{.ID}}' --filter name=sdp-console 2>/dev/null | head -1
}

# ============================================================
# 下载授权包
# ============================================================
download_pack() {
    log "本地未找到授权包，从 GitHub 下载..."
    log "下载地址: $LICENSE_URL"

    if command -v curl &>/dev/null; then
        curl -sL -o "$LOCAL_PACK" --connect-timeout 30 "$LICENSE_URL" 2>/dev/null
    elif command -v wget &>/dev/null; then
        wget -q -O "$LOCAL_PACK" "$LICENSE_URL" 2>/dev/null
    else
        err "curl 和 wget 都不可用，无法下载"
        return 1
    fi

    if [ -f "$LOCAL_PACK" ] && [ -s "$LOCAL_PACK" ]; then
        log "下载成功 ($(du -h "$LOCAL_PACK" | cut -f1))"
        return 0
    fi
    err "下载失败，请检查 LICENSE_URL 是否正确"
    return 1
}

# ============================================================
# 备份
# ============================================================
do_backup() {
    log "备份授权数据到 ${BACKUP_DIR} ..."
    mkdir -p "${BACKUP_DIR}"/{license,app-secret,fingerprint,etc_keys,hwconf}
    cp -r "${LICENSE_DIR}/"* "${BACKUP_DIR}/license/" 2>/dev/null || true
    cp -r /app/.info/app-secret/* "${BACKUP_DIR}/app-secret/" 2>/dev/null || true
    cp /app/.info/atrust_deivce_fingerprint.pub /app/.info/atrust_update.pub /app/.info/cloud_upload.pub /app/.info/sslupdate.pub "${BACKUP_DIR}/etc_keys/" 2>/dev/null || true
    cp -r /app/.info/hwconf/* "${BACKUP_DIR}/hwconf/" 2>/dev/null || true
    local d; d=$(get_etc_data)
    [ -n "$d" ] && echo "$d" > "${BACKUP_DIR}/etcd_data.json" && log "etcd 已备份"
    [ -f "$DAEMON_CONFIG" ] && cp "$DAEMON_CONFIG" "${BACKUP_DIR}/config.prod.json"
    log "备份完成"
}

# ============================================================
# 从授权包还原
# ============================================================
do_restore() {
    local pkg="${1:-$LOCAL_PACK}"
    if [ ! -f "$pkg" ]; then
        err "授权包不存在: $pkg"
        return 1
    fi
    if ! check_etcd; then err "etcd 不可用"; return 1; fi

    local rd; rd=$(mktemp -d /tmp/duang_restore_XXXXXX)
    tar xzf "$pkg" -C "$rd"
    local dd="${rd}/duang_license_pack"
    [ ! -d "$dd" ] && dd="$rd"

    do_backup

    # 1. 确保 daemon 运行并完成初始加载
    local cid; cid=$(get_container_id)
    if [ -n "$cid" ]; then
        local cur
        cur=$(docker exec "$cid" supervisorctl status license-confd 2>/dev/null | awk '{print $2}')
        [ "$cur" != "RUNNING" ] && docker exec "$cid" supervisorctl start license-confd 2>/dev/null || true
        log "等待 daemon 就绪..."
        for i in $(seq 1 15); do
            cur=$(docker exec "$cid" supervisorctl status license-confd 2>/dev/null | awk '{print $2}')
            [ "$cur" = "RUNNING" ] && sleep 3 && break
            sleep 1
        done
    fi

    # 2. 改 daemon 检查间隔（防覆写）
    if [ -f "$DAEMON_CONFIG" ]; then
        python3 -c "
import json
c = json.load(open('$DAEMON_CONFIG'))
c['checkLicenseInterval'] = 999999999
json.dump(c, open('$DAEMON_CONFIG','w'), indent=4)
" 2>/dev/null || true
        [ -n "$cid" ] && docker cp "$DAEMON_CONFIG" "${cid}:/home/app/sdp-license-confd/config/config.prod.json" 2>/dev/null || true
    fi

    # 3. 写入 etcd（核心）
    if [ -f "${dd}/etcd_license.json" ]; then
        ${ETCDCTL} put /config/private/license/local "$(cat ${dd}/etcd_license.json)" 2>/dev/null
        log "etcd 已从授权包恢复"
    else
        warn "授权包中缺少 etcd_license.json"
        rm -rf "$rd"; return 1
    fi

    # 4. daemon 配置
    if [ -f "${dd}/config.prod.json" ]; then
        cp "${dd}/config.prod.json" "$DAEMON_CONFIG" 2>/dev/null || true
        [ -n "$cid" ] && docker cp "$DAEMON_CONFIG" "${cid}:/home/app/sdp-license-confd/config/config.prod.json" 2>/dev/null || true
    fi

    rm -rf "$rd"
    return 0
}

# ============================================================
# 验证
# ============================================================
verify_license() {
    local d; d=$(get_etc_data)
    [ -z "$d" ] && err "无法读取 etcd" && return 1

    local f; f=$(mktemp /tmp/duang_verify_XXXXXX.json)
    echo "$d" > "$f"
    python3 - "$f" << 'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
l = d.get("license", {})
print("\n" + "=" * 60)
print("  授权验证结果")
print("=" * 60)
print(f"  授权类型: {l.get('licenseType')}")
print(f"  客户名称: {l.get('customerName')}")
print(f"  授权状态: {l.get('status')}")
print(f"  序列号: {l.get('sn')}")
print(f"  existInLic: {l.get('base',{}).get('existInLic')}")
print(f"  users: {l.get('base',{}).get('users')}")
print()
ALL = ["base","uem","emm","virtualNet","appWrap","omniscient","skyInspect","ipsec","updateSoft","kylinOS","distributedCluster"]
ok = True
for m in ALL:
    mod = l.get(m)
    if not mod: print(f"  {m:20s} [MISSING]"); ok = False; continue
    ek = m + "ExpireTime" if m != "base" else "baseExpireTime"
    uk = m + "IsUnlimited" if m != "base" else "baseIsUnlimited"
    st = "OK" if (mod.get(ek) == 7258118400 and mod.get(uk) == True) else "BUG!"
    if st == "BUG!": ok = False
    lt = mod.get("parts",[{}])[0].get("licType","") if mod.get("parts") else ""
    print(f"  {m:20s} expire={mod.get(ek)} unlimited={mod.get(uk)} licType={lt} [{st}]")
M = d.get("module", {})
if M:
    print()
    for mn in sorted(M):
        f2 = M[mn][list(M[mn].keys())[0]]
        st = "OK" if f2.get("status") == "activated" else "BUG!"
        if st == "BUG!": ok = False
        print(f"  {mn:20s} status={f2.get('status')} [{st}]")
print(f"\n  Result: {'All OK' if ok else 'HAS BUGS'}")
print("=" * 60)
sys.exit(0 if ok else 1)
PYEOF
    local rc=$?; rm -f "$f"
    return $rc
}

# ============================================================
# 打包（在已授权机器上执行一次即可）
# ============================================================
do_pack() {
    log "打包当前机器授权数据..."
    local pd="/tmp/duang_license_pack"
    rm -rf "$pd"; mkdir -p "$pd"/{license,app-secret,fingerprint}

    do_backup 2>/dev/null || true

    # .lic 文件（原样，不修改）
    [ -f "${BACKUP_DIR}/license/sf_license.lic" ] && cp "${BACKUP_DIR}/license/sf_license.lic" "$pd/license/" || \
    [ -f "${LICENSE_DIR}/sf_license.lic" ] && cp "${LICENSE_DIR}/sf_license.lic" "$pd/license/"

    echo '{"sn": ""}' > "$pd/license/sf_license_conf.json"
    echo "aTrust_HYBRID" > "$pd/license/product_name"
    echo "1.0.0" > "$pd/license/sflicense_version"

    local pub="/app/.info/atrust_deivce_fingerprint.pub"
    [ -f "$pub" ] && cp "$pub" "$pd/fingerprint/"
    cp /app/.info/app-secret/* "$pd/app-secret/" 2>/dev/null || true

    # 生成 etcd 授权模板
    build_etcd_license "$pd/etcd_license.json"
    build_daemon_config "$pd/config.prod.json"

    tar czf "$LOCAL_PACK" -C /tmp "$(basename $pd)" 2>/dev/null
    log "授权包已创建: $LOCAL_PACK"
    log "请把这个文件上传到你的 GitHub 仓库:"
    log "  $LOCAL_PACK"
    log "然后把仓库地址填入脚本的 LICENSE_URL 变量"
}

build_etcd_license() {
    python3 - "$1" << 'PYEOF' 2>/dev/null || true
import sys, json, time
out = sys.argv[1]
y, mu = 7258118400, 999999
lt, cn, sn = "至尊", "Duang私有版", "DUANG-PRIVATE-CLOUD-999999"
parts = [{"status":"activated","issueTime":0,"expireTime":y,"usedDays":0,"totalDays":0,"leftDays":0,"isUnlimited":True,"users":mu,"licType":lt}]
data = {
    "license": {
        "id": "403C91D9", "licno": "A5130602CB587A37751B",
        "licenseType": lt, "customerName": cn, "status": "activated", "sn": sn,
        "name": "aTrust_HYBRID", "version": "aTrust2.5.16",
        "base": {"baseExpireTime": y, "baseIsUnlimited": True, "parts": parts,
            "unavailableSteps": None, "users": mu, "version": "3",
            "gatewayModel": "aTrust-1000-V1050M", "connections": 200000,
            "trafficLevel": "", "existInLic": True},
        "uem": {"uemExpireTime": y, "uemIsUnlimited": True, "parts": parts, "users": mu, "version": "1", "neverExpireUsers": mu, "existInLic": True},
        "emm": {"emmExpireTime": y, "emmIsUnlimited": True, "parts": parts, "users": mu, "version": "1", "existInLic": True},
        "omniscient": {"omniscientExpireTime": y, "omniscientIsUnlimited": True, "parts": parts, "existInLic": True},
        "skyInspect": {"skyInspectExpireTime": y, "skyInspectIsUnlimited": True, "parts": parts, "existInLic": True},
        "virtualNet": {"virtualNetExpireTime": y, "virtualNetIsUnlimited": True, "parts": parts, "existInLic": True},
        "kylinOS": {"kylinOSExpireTime": y, "kylinOSIsUnlimited": True, "status": "activated", "existInLic": True},
        "updateSoft": {"updateSoftExpireTime": y, "updateSoftIsUnlimited": True, "status": "activated", "parts": parts, "existInLic": True},
        "distributedCluster": {"distributedClusterExpireTime": y, "distributedClusterIsUnlimited": True, "parts": parts, "existInLic": True, "status": "activated"},
        "appWrap": {"appWrapExpireTime": y, "appWrapIsUnlimited": True, "parts": parts, "existInLic": True},
        "ipsec": {"ipsecExpireTime": y, "ipsecIsUnlimited": True, "status": "activated", "parts": parts, "existInLic": True}
    },
    "module": {},
    "devUsedUpdateTime": int(time.time()), "devDeadlineUpdateTime": 0, "devDeadline": 99999,
    "licenseVersion": "v6", "updateTime": int(time.time()),
    "isMixedLicense": 0, "mixLic": None,
    "gwidChange": {"changed": False, "oldId": "", "newId": "", "changeTime": ""},
    "forceUpdate": False
}
for m in ["base","uem","emm","virtualNet","appWrap","omniscient","skyInspect","ipsec","updateSoft","kylinOS"]:
    data["module"][m] = {m: {"name": m, "status": "activated", "issueTime": int(time.time()),
        "expireTime": y, "usedDays": 0, "totalDays": 99999, "isUnlimited": True,
        "parts": [{"status":"activated","issueTime":int(time.time()),"expireTime":y,
            "usedDays":0,"totalDays":0,"leftDays":0,"isUnlimited":True,"users":mu,"licType":lt}]}}
json.dump(data, open(out, "w"), indent=2, ensure_ascii=False)
PYEOF
    log "etcd 授权 JSON 已构建: $1"
}

build_daemon_config() {
    cat > "$1" << 'DAEMONEOF'
{
    "address": "127.0.0.1:50037",
    "licenseApiPrefix": "http://127.0.0.1:50018/api",
    "appServerConfigPath": "/app/.server.json",
    "checkLicenseInterval": 999999999,
    "licenseModuleConfig": {
        "base": { "versionKey": "version", "features": { "base": { "expirable": true, "properties": { "users": { "alias": "availableUsers", "countable": true }, "totalUsers": { "rawInfoKey": "users", "countable": true } } } } },
        "uem": { "versionKey": "version", "allowSkip": true, "features": { "uem": { "expirable": true, "properties": { "users": { "countable": true } } } } },
        "emm": { "versionKey": "version", "allowSkip": true, "features": { "emm": { "expirable": true, "properties": { "users": { "countable": true } } } } },
        "virtualNet": { "allowSkip": false, "features": { "virtualNet": { "properties": { "virtualNetExpireTime": {}, "virtualNetIsUnlimited": {} } } } },
        "appWrap": { "allowSkip": true, "features": { "appWrap": { "properties": { "appWrapExpireTime": {}, "appWrapIsUnlimited": {} } } } },
        "updateSoft": { "allowSkip": true, "features": { "updateSoft": { "expirable": true } } }
    },
    "licenseExpireTimeFeatures": {
        "aTrust_HYBRID": { "base": ["base"], "updateSoft": ["updateSoft"], "uem": ["uem"], "emm": ["emm"], "virtualNet": ["virtualNet"], "kylinOS": ["kylinOS"], "ipsec": ["ipsec"], "appWrap": ["appWrap"] },
        "aTrust_SDPC": { "base": ["base"], "updateSoft": ["updateSoft"], "uem": ["uem"], "emm": ["emm"], "skyInspect": ["skyInspect"], "omniscient": ["omniscient"], "virtualNet": ["virtualNet"], "kylinOS": ["kylinOS"], "appWrap": ["appWrap"] },
        "aTrust_GATEWAY": { "base": ["base"], "updateSoft": ["updateSoft"], "ipsec": ["ipsec"], "kylinOS": ["kylinOS"] },
        "aTrust_VPN": { "base": ["base"], "ipsec": ["ipsec"], "updateSoft": ["updateSoft"] },
        "aTrust_Manager": { "base": ["base"], "updateSoft": ["updateSoft"], "skyInspect": ["skyInspect"], "omniscient": ["omniscient"] },
        "aTrust_Intergrated": { "base": ["base"], "updateSoft": ["updateSoft"] },
        "aTrust_Proxy": { "base": ["base"], "updateSoft": ["updateSoft"] }
    }
}
DAEMONEOF
    log "daemon 配置已构建: $1"
}

# ============================================================
# 信息收集
# ============================================================
collect_info() {
    echo ""
    echo "============================================================"
    echo "  aTrust 系统信息收集"
    echo "============================================================"
    echo ""
    local HN; HN=$(hostname)
    local MAC; MAC=$(ip link show eth0 2>/dev/null | grep ether | awk '{print $2}' || echo "N/A")
    local HWID; HWID=$(cat /app/.info/hwconf/sangfor-hwid 2>/dev/null || echo "N/A")
    local PR; PR=$(cat "${LICENSE_DIR}/product_name" 2>/dev/null || echo "N/A")
    local UUID; UUID=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo "N/A")
    local d; d=$(get_etc_data)
    local did=""; local licno=""
    [ -n "$d" ] && did=$(echo "$d" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("license",{}).get("id",""))' 2>/dev/null) && licno=$(echo "$d" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("license",{}).get("licno",""))' 2>/dev/null)
    [ -z "$did" ] && did="N/A"; [ -z "$licno" ] && licno="N/A"
    echo "  主机名:     $HN"
    echo "  MAC(eth0):  $MAC"
    echo "  产品型号:   $PR"
    echo "  HWID:       $HWID"
    echo "  DeviceID:   $did"
    echo "  授权号:     $licno"
    echo "  UUID:       $UUID"
    echo "============================================================"
    echo ""
}

usage() {
    echo "使用方法:"
    echo "  bash $0 --apply         下载授权包+还原授权"
    echo "  bash $0 --collect       收集本机信息"
    echo "  bash $0 --backup        备份当前授权"
    echo "  bash $0 --pack          打包授权（在已授权机器上运行）"
    echo "  bash $0 --restore <包>  从本地包还原"
    exit 0
}

case "${1:-}" in
    --apply)
        if ! check_etcd; then err "etcd 不可用"; exit 1; fi
        collect_info
        # 检查授权包是否存在，不存在则下载
        if [ ! -f "$LOCAL_PACK" ]; then
            download_pack || exit 1
        else
            log "本地授权包已存在: $LOCAL_PACK"
        fi
        do_restore "$LOCAL_PACK" || exit 1
        verify_license
        log "授权应用成功！请刷新 web 管理页面"
        # 清理：删除授权包和脚本自身
        log "清理临时文件..."
        rm -f "$LOCAL_PACK"
        log "脚本自删除..."
        rm -f "$0"
        ;;
    --collect)
        collect_info
        ;;
    --backup)
        do_backup
        ;;
    --pack)
        do_pack
        ;;
    --restore)
        [ -z "${2:-}" ] && usage
        if ! check_etcd; then err "etcd 不可用"; exit 1; fi
        do_restore "$2" || exit 1
        verify_license
        log "还原完成！"
        ;;
    *)
        usage
        ;;
esac
