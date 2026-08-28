#!/bin/sh
# ============================================================
# Kindle 墨水屏公告板 · 同步脚本
# 逻辑: 开 WiFi -> 等 IP -> curl 下载图片覆盖屏保 -> 关 WiFi
#
# 安装 (SSH/KUAL 终端里执行):
#   mkdir -p /mnt/us/board
#   # 把本脚本放到 /mnt/us/board/sync.sh
#   chmod +x /mnt/us/board/sync.sh
#
# 手动测试 (下载后立即刷屏预览):
#   /mnt/us/board/sync.sh test
#
# 定时运行见 README/crontab 说明
# ============================================================

PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH

# ==================== 配置区 ====================
# 主链接: GitHub raw 直链 (把 用户名/仓库名 换成你自己的)
# 如果国内网络拉不动, 换用下面的镜像, 三选一:
#   镜像1: https://mirror.ghproxy.com/https://raw.githubusercontent.com/用户名/仓库/main/notice.png
#   镜像2: https://fastly.jsdelivr.net/gh/用户名/仓库@main/notice.png
URL="https://raw.githubusercontent.com/你的用户名/你的仓库/main/notice.png"

# 输出路径: 改成你 linkss 屏保目录里的实际文件名
# (注意: 用「固定文件名 + 覆盖」而不是每次新名字, linkss 才会一直展示最新这张)
OUT="/mnt/us/linkss/screensavers/00_board.png"

LOG="/mnt/us/board/sync.log"

# 可选: 放一份新版 CA 证书包 (cacert.pem 改名为 ca-bundle.crt)
# 下载地址: https://curl.se/ca/cacert.pem  -> 传到 Kindle /mnt/us/board/
# 留空则退回用 -k 跳过证书校验
CA="/mnt/us/board/ca-bundle.crt"

# 1 = 每次下载成功后立即刷屏 (公告板推荐开, 会短暂白屏刷新一次)
# 0 = 只覆盖文件, 等下次进入屏保时自然生效 (适合白天还在看书的场景)
FLASH_ON_UPDATE=1
# ================================================

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

TEST=0
[ "$1" = "test" ] && TEST=1

# ---------- 1. 开 WiFi 并等待拿到 IP ----------
lipc-set-prop -i com.lab126.wifid enableAndConnect >/dev/null 2>&1

gw=""
i=0
while [ $i -lt 15 ]; do
    gw=$(lipc-get-prop com.lab126.wifid gatewayIP 2>/dev/null)
    case "$gw" in
        [0-9]*) break ;;   # 拿到网关 IP 即认为连接成功
    esac
    sleep 2
    i=$((i+1))
done

if ! echo "$gw" | grep -q '^[0-9]'; then
    log "ERROR: WiFi 连接失败, 放弃本次同步"
    lipc-set-prop com.lab126.wifid enable 0 >/dev/null 2>&1
    exit 1
fi
log "WiFi OK (gateway=$gw)"

# ---------- 2. 下载 ----------
# 先按正规证书校验下载; 若本机 CA 太旧导致失败, 且提供了 CA 包则用 CA 包,
# 最后兜底 -k 跳过校验 (公告板场景可接受)
CURL_BASE="--connect-timeout 10 --max-time 60 -sS -L -o ${OUT}.tmp"
curl $CURL_BASE "$URL" 2>/dev/null
if [ $? -ne 0 ]; then
    if [ -n "$CA" ] && [ -f "$CA" ]; then
        log "retry with cacert"
        curl $CURL_BASE --cacert "$CA" "$URL" 2>/dev/null
    fi
fi
if [ $? -ne 0 ]; then
    log "retry with -k (insecure)"
    curl -k $CURL_BASE "$URL" 2>/dev/null
fi

# ---------- 3. 校验并覆盖 ----------
ok=0
if [ -f "${OUT}.tmp" ]; then
    size=$(wc -c < "${OUT}.tmp" | tr -d ' \t')
    # PNG 魔数校验 + 大小校验(正常 800x600 图至少几十 KB)
    head -c 4 "${OUT}.tmp" | grep -q $'\x89PNG' && [ "$size" -gt 20000 ] && ok=1
fi

if [ "$ok" -eq 1 ]; then
    mv "${OUT}.tmp" "$OUT"
    log "OK: 更新成功 (${size} bytes)"
    if [ "$TEST" -eq 1 ] || [ "$FLASH_ON_UPDATE" -eq 1 ]; then
        eips -f "$OUT" >/dev/null 2>&1   # 立即刷屏显示
    fi
else
    log "ERROR: 下载失败或文件无效, 保留旧屏保"
    rm -f "${OUT}.tmp"
fi

# ---------- 4. 关 WiFi 省电 ----------
lipc-set-prop com.lab126.wifid enable 0 >/dev/null 2>&1
log "WiFi off"
exit 0
