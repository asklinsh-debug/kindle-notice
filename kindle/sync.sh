#!/bin/sh
# ============================================================
# Kindle 公告板 · 接收端 (Kindle 7 / linkss)
#
# 职责只有三件事: 拉图 -> 落盘 -> 显示
# 生成图片、天气、农历、公告这些全在云端 (Cloudflare Worker) 做,
# 这里只是一个"哑终端"。
#
# 两种显示模式:
#   [常亮模式] 屏幕永不休眠, eips -g 直接把看板刷在唤醒的屏幕上 (默认关闭)
#   [屏保模式] 写到 linkss 屏保目录, 锁屏时显示 (安静, 不打扰阅读)
#
# 命令:
#   sync.sh                同步一次 (内容没变则跳过)
#   sync.sh force          强制同步并刷屏
#   sync.sh enable_cron    开启每 15 分钟自动同步
#   sync.sh disable_cron   关闭自动同步
#   sync.sh enable_always_on   开启常亮显示
#   sync.sh disable_always_on  关闭常亮显示
#
# 日志: /mnt/us/notice_sync.log  (插电脑可直接看)
# ============================================================

PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH

# ==================== 配置 ====================
BASE="https://kindle.nbhub.dpdns.org"   # 云端地址
URL_PNG="$BASE/notice.png"              # 屏保用 (linkss)
URL_G8="$BASE/notice.g8"                # 常亮用 (eips -g 原始灰度 600x800)

OUT_PNG="/mnt/us/linkss/screensavers/bg_ss00.png"  # linkss 屏保文件
OUT_G8="/mnt/us/notice_sync/board.g8"             # 常亮显示的灰度数据

LOG="/mnt/us/notice_sync.log"
ETAG_FILE="/mnt/us/notice_sync/.etag"
FLAG_CRON="/mnt/us/notice_sync/.cron_enabled"
FLAG_ON="/mnt/us/notice_sync/.always_on"
CRON_LINE="*/15 * * * * /mnt/us/notice_sync/sync.sh"
KEEPALIVE="/mnt/us/notice_sync/keepalive.sh"

W=600
H=800
G8_SIZE=$((W * H))   # 480000 字节
# ==============================================

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

FORCE=0
[ "$1" = "force" ] && FORCE=1

# ---------- 常亮模式开关 ----------
if [ "$1" = "enable_always_on" ] || [ "$1" = "disable_always_on" ]; then
    if [ "$1" = "enable_always_on" ]; then
        touch "$FLAG_ON"
        "$KEEPALIVE" start
        log "常亮: 已开启 (屏幕保持显示看板)"
        exec "$0" force          # 立刻刷一次, 让看板出现在唤醒的屏幕上
    else
        rm -f "$FLAG_ON"
        "$KEEPALIVE" stop
        lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1
        log "常亮: 已关闭 (恢复锁屏屏保显示)"
        exit 0
    fi
fi

# ---------- 定时开关 ----------
if [ "$1" = "enable_cron" ] || [ "$1" = "disable_cron" ]; then
    mntroot rw
    sed -i '\#notice_sync/sync.sh#d' /etc/crontab/root 2>/dev/null
    if [ "$1" = "enable_cron" ]; then
        echo "$CRON_LINE" >> /etc/crontab/root
        touch "$FLAG_CRON"
        log "定时: 已开启 ($CRON_LINE)"
    else
        rm -f "$FLAG_CRON"
        log "定时: 已关闭"
    fi
    mntroot ro
    # 重启 crond; 必须 -c /etc/crontab, 否则它读默认目录, 我们的表不生效
    /etc/init.d/cron restart 2>/dev/null || {
        killall crond 2>/dev/null
        sleep 1
        crond -b -c /etc/crontab 2>/dev/null
    }
    [ "$1" = "enable_cron" ] && exec "$0" sync
    exit 0
fi

# ---------- 常亮状态恢复 (每次运行都重新拉起, 重启后也能自愈) ----------
if [ -f "$FLAG_ON" ]; then
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1
    "$KEEPALIVE" start
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
    log "ERROR: WiFi 连接失败 (USB 模式下或未保存 WiFi 时属正常)"
    lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1
    exit 1
fi

# ================= 2. 有没有新内容 =================
if [ "$FORCE" -eq 0 ]; then
    etag=$(curl -sI --connect-timeout 8 --max-time 15 "$URL_PNG" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="etag:"{print $2}')
    if [ -n "$etag" ] && [ "$etag" = "$(cat "$ETAG_FILE" 2>/dev/null)" ] && [ -f "$OUT_G8" ]; then
        log "SKIP: 内容未变"
        lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1
        exit 0
    fi
fi

# ================= 3. 下载 =================
TMP_G8="/tmp/board.g8"
TMP_PNG="/tmp/board.png"
curl --connect-timeout 10 --max-time 60 -sS -L -o "$TMP_G8" "$URL_G8" 2>/dev/null || curl -k --connect-timeout 10 --max-time 60 -sS -L -o "$TMP_G8" "$URL_G8" 2>/dev/null
curl --connect-timeout 10 --max-time 60 -sS -L -o "$TMP_PNG" "$URL_PNG" 2>/dev/null || curl -k --connect-timeout 10 --max-time 60 -sS -L -o "$TMP_PNG" "$URL_PNG" 2>/dev/null

# ================= 4. 校验并落盘 =================
size_g8=$(wc -c < "$TMP_G8" 2>/dev/null | tr -d ' \t')
ok_png=0
[ -f "$TMP_PNG" ] && head -c 4 "$TMP_PNG" | grep -q $'\x89PNG' && ok_png=1

if [ "$size_g8" != "$G8_SIZE" ] && [ "$ok_png" -eq 0 ]; then
    log "ERROR: 下载失败 (g8=$size_g8 png=$ok_png)"
    rm -f "$TMP_G8" "$TMP_PNG"
    lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1
    exit 1
fi

if [ "$size_g8" = "$G8_SIZE" ]; then
    cp "$TMP_G8" "$OUT_G8"
    log "OK: 灰度数据已更新 ($size_g8 bytes)"
fi
if [ "$ok_png" -eq 1 ]; then
    cp "$TMP_PNG" "$OUT_PNG"
    log "OK: 屏保图已更新 ($(wc -c < "$TMP_PNG" | tr -d ' \t') bytes)"
fi
[ -n "$etag" ] && echo "$etag" > "$ETAG_FILE"
rm -f "$TMP_G8" "$TMP_PNG"

# ================= 5. 显示 =================
# 常亮模式: 直接刷到唤醒的屏幕; 屏保模式: 不动, 锁屏时由 linkss 显示
if [ -f "$FLAG_ON" ] && [ -f "$OUT_G8" ]; then
    eips -c >/dev/null 2>&1
    eips -g "$OUT_G8" >/dev/null 2>&1
    log "显示: 已刷屏 (常亮模式)"
fi

lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1
exit 0
