#!/bin/sh
# ============================================================
# Kindle 公告板 · 接收端 (Kindle 7 / linkss)
#
# 职责只有一件事: 拉图 -> 落盘。显示交给 linkss 屏保。
# 生成图片、天气、农历、公告全在云端 (Cloudflare Worker) 做, 这里只是哑终端。
#
# 定时策略:
#   - 云端每 30 分钟生成新图; 这里也每 30 分钟拉一次
#   - crond 只在 :29 / :59 触发 (一天 48 次)
#   - 每次跑完用 RTC 硬件闹钟预约 30 分钟后的下一次唤醒, 自循环
#   - 若本机不支持 RTC 唤醒, 会退回依赖 linkss 的自动唤醒
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

CRON_LINE="29,59 * * * * /mnt/us/notice_sync/sync.sh"   # 每小时只在 :29 / :59 触发
INTERVAL=1500        # 最小间隔 25 分钟, 防止意外重复执行 (正常每 30 分钟一次)
MIN_PNG=20000        # PNG 最小体积, 用于校验
# ==============================================

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# ---------- 预约下一次唤醒 (RTC 硬件闹钟, 到点自动醒) ----------
# 写完脚本退出后设备会休眠, 到时间由硬件闹钟唤醒, crond 随即触发本脚本,
# 形成 :29 -> :59 -> :29 的自循环, 一天只有 48 次唤醒。
arm_next_wake() {
    WAKE_DEV="/sys/class/rtc/rtc0/wakealarm"
    [ -w "$WAKE_DEV" ] || { log "WAKE: 本机不支持 RTC 唤醒, 改为依赖 linkss 自动唤醒"; return 1; }
    now=$(date +%s)
    # 30 分钟后, 并对齐到整分 (落在下一个 :29 或 :59)
    next=$(( now + 1800 - now % 60 ))
    echo 0 > "$WAKE_DEV" 2>/dev/null
    echo "$next" > "$WAKE_DEV" 2>/dev/null
    log "WAKE: 已预约下次唤醒 -> $(date '+%H:%M' -d "@$next" 2>/dev/null) (30 分钟后)"
    return 0
}

FORCE=0
[ "$1" = "force" ] && FORCE=1

# ---------- 防并发: 上一轮还没跑完就直接退出 ----------
if [ -f "$LOCK" ]; then
    kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null && exit 0
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# ---------- 节流: 没到 30 分钟就安静退出 (不开 WiFi, 零耗电) ----------
# 时钟差值为准(绝对时间不准没关系); 顺带防时钟倒退/重置导致永远不再更新
if [ "$FORCE" -eq 0 ] && [ "$1" != "enable_cron" ] && [ "$1" != "disable_cron" ]; then
    now=$(date +%s)
    last=$(cat "$LAST_FILE" 2>/dev/null)
    case "$last" in ""|*[!0-9]*) last=0 ;; esac
    diff=$((now - last))
    [ "$diff" -ge 0 ] && [ "$diff" -lt "$INTERVAL" ] && exit 0
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
    [ "$1" = "enable_cron" ] && arm_next_wake
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
        arm_next_wake
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
arm_next_wake      # 预约下一次, 保证链条不断
exit 0
