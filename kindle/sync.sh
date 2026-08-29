#!/bin/sh
# ============================================================
# Kindle 公告板 · 接收端 (Kindle 7 / linkss)
#
# 职责只有一件事: 拉图 -> 落盘。显示交给 linkss 屏保。
# 生成图片、天气、农历、公告全在云端 (Cloudflare Worker) 做, 这里只是哑终端。
#
# 定时策略 (关键):
#   - Kindle 休眠时 crond 不执行; linkss 每小时会把设备唤醒一次, 窗口很短
#   - 所以 crond 设成每分钟检查, 由本脚本自己判断是否到了同步时间
#   - 只要设备醒着(哪怕 1 分钟)就能抓住唤醒窗口
#   - 未到时间立刻退出: 不开 WiFi、不写日志, 几乎零耗电
#
# 命令:
#   sync.sh                同步一次 (节流/内容未变则跳过)
#   sync.sh force          强制同步 (忽略节流与 ETag)
#   sync.sh enable_cron    开启自动同步
#   sync.sh disable_cron   关闭自动同步
#
# 日志: /mnt/us/notice_sync.log  (插电脑可直接看)
# ============================================================

PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH

# ==================== 配置 ====================
BASE="https://kindle.nbhub.dpdns.org"   # 云端地址
URL_PNG="$BASE/notice.png"              # 看板图 (600x800 8bit 灰度 PNG)
OUT_PNG="/mnt/us/linkss/screensavers/bg_ss00.png"   # linkss 屏保文件

LOG="/mnt/us/notice_sync.log"
ETAG_FILE="/mnt/us/notice_sync/.etag"
FLAG_CRON="/mnt/us/notice_sync/.cron_enabled"
LAST_FILE="/mnt/us/notice_sync/.last_sync"
LOCK="/mnt/us/notice_sync/.lock"

CRON_LINE="* * * * * /mnt/us/notice_sync/sync.sh"   # 每分钟检查
INTERVAL=3000        # 距上次成功同步多少秒后才再同步 (50 分钟, 略小于 linkss 的 60 分钟唤醒)
MIN_PNG=20000        # PNG 最小体积, 用于校验
# ==============================================

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

FORCE=0
[ "$1" = "force" ] && FORCE=1

# ---------- 防并发: 上一轮还没跑完就直接退出 ----------
if [ -f "$LOCK" ]; then
    kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null && exit 0
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# ---------- 节流: 没到时间就安静退出 ----------
if [ "$FORCE" -eq 0 ] && [ "$1" != "enable_cron" ] && [ "$1" != "disable_cron" ]; then
    now=$(date +%s)
    last=$(cat "$LAST_FILE" 2>/dev/null)
    case "$last" in ""|*[!0-9]*) last=0 ;; esac
    [ $((now - last)) -lt "$INTERVAL" ] && exit 0
fi

# ---------- 定时开关 ----------
if [ "$1" = "enable_cron" ] || [ "$1" = "disable_cron" ]; then
    mntroot rw
    sed -i '\#notice_sync/sync.sh#d' /etc/crontab/root 2>/dev/null
    if [ "$1" = "enable_cron" ]; then
        echo "$CRON_LINE" >> /etc/crontab/root
        touch "$FLAG_CRON"
        log "定时: 已开启 ($CRON_LINE, 节流 ${INTERVAL}s)"
    else
        rm -f "$FLAG_CRON"
        log "定时: 已关闭"
    fi
    mntroot ro
    # 先杀干净所有 crond 再起一个, 否则会出现多个守护导致重复执行
    killall crond 2>/dev/null
    sleep 1
    killall -9 crond 2>/dev/null
    sleep 1
    # -c /etc/crontab 必须指定, 否则 crond 读默认目录, 我们的表不生效
    crond -b -c /etc/crontab 2>/dev/null || /etc/init.d/cron restart 2>/dev/null
    log "定时: crond 已重启"
    exit 0
fi

# ================= 1. 开 WiFi =================
lipc-set-prop com.lab126.cmd wirelessEnable 1 >/dev/null 2>&1
lipc-set-prop -i com.lab126.wifid enableAndConnect >/dev/null 2>&1
gw=""
i=0
while [ $i -lt 20 ]; do
    gw=$(lipc-get-prop com.lab126.wifid gatewayIP 2>/dev/null)
    case "$gw" in [0-9]*) break ;; esac
    cm=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
    case "$cm" in CONNECTED*) gw="connected"; break ;; esac
    ifconfig wlan0 2>/dev/null | grep -q 'inet addr' && { gw="connected"; break; }
    sleep 3
    i=$((i+1))
done
if [ -z "$gw" ]; then
    log "ERROR: WiFi 连接失败 (USB 模式或未保存 WiFi 时属正常)"
    lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1
    exit 1
fi

# ================= 2. 有没有新内容 =================
if [ "$FORCE" -eq 0 ]; then
    etag=$(curl -sI --connect-timeout 8 --max-time 15 "$URL_PNG" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="etag:"{print $2}')
    if [ -n "$etag" ] && [ "$etag" = "$(cat "$ETAG_FILE" 2>/dev/null)" ] && [ -f "$OUT_PNG" ]; then
        log "SKIP: 内容未变"
        date +%s > "$LAST_FILE"
        lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1
        exit 0
    fi
fi

# ================= 3. 下载 =================
TMP="/tmp/board.png"
curl --connect-timeout 10 --max-time 60 -sS -L -o "$TMP" "$URL_PNG" 2>/dev/null \
  || curl -k --connect-timeout 10 --max-time 60 -sS -L -o "$TMP" "$URL_PNG" 2>/dev/null

# ================= 4. 校验并落盘 =================
ok=0
if [ -f "$TMP" ]; then
    size=$(wc -c < "$TMP" | tr -d ' \t')
    head -c 4 "$TMP" | grep -q $'\x89PNG' && [ "$size" -gt "$MIN_PNG" ] && ok=1
fi

if [ "$ok" -eq 1 ]; then
    cp "$TMP" "$OUT_PNG"
    [ -n "$etag" ] && echo "$etag" > "$ETAG_FILE"
    date +%s > "$LAST_FILE"
    log "OK: 屏保已更新 ($size bytes)"
else
    log "ERROR: 下载失败或文件无效, 保留旧屏保"
fi
rm -f "$TMP"

lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1
exit 0
