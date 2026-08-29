#!/bin/sh
# ============================================================
# Kindle 公告板 · 接收端 (Kindle 7 / linkss)
#
# 职责只有一件事: 拉图 -> 落盘。显示交给 linkss 屏保。
# 生成图片、天气、农历、公告全在云端 (Cloudflare Worker) 做, 这里只是哑终端。
#
# 定时策略:
#   - 云端每 30 分钟 (:28/:58) 生成新图
#   - 拉取时机: 唤醒监听守护 (lipc 订阅 powerd 唤醒事件, 一唤醒就同步)
#               + crond :29/:59 兜底
#   - 有无新内容由云端 ETag 判断 (没变就 SKIP, 不重复下载)
#   - 每次跑完用 RTC 硬件闹钟预约 30 分钟后的下一次唤醒, 自循环
#   - 若本机不支持 RTC 唤醒, 会退回依赖 linkss 的自动唤醒
#
# 命令:
#   sync.sh                同步一次 (内容未变则跳过)
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
LOCK="/mnt/us/notice_sync/.lock"

CRON_LINE="0,30 * * * * /mnt/us/notice_sync/sync.sh"   # 每小时只在 :00 / :30 触发
MIN_PNG=20000        # PNG 最小体积, 用于校验
# ==============================================

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# ---------- 让 linkss 重新加载屏保图片 ----------
# 关键: linkss 只在"开机 / 休眠 / 屏保服务重启"时读取 screensavers 目录。
# 我们覆盖 bg_ss00.png 之后, 必须重启屏保服务, 否则锁屏还是旧的(或默认的)。
refresh_screensaver() {
    LINKSS_DIR="/mnt/us/extensions/linkss"
    if [ -x "$LINKSS_DIR/bin/linkss.sh" ]; then
        # linkss.sh 靠 PWD 推导 hack 名, 必须先 cd 进去
        (cd "$LINKSS_DIR" && ./bin/linkss.sh framework_restart) >/dev/null 2>&1
        log "屏保: 已重载 (linkss)"
    else
        # 兜底: 直接让框架重启
        lipc-set-prop com.lab126.winmgr frameworkRestart 1 >/dev/null 2>&1
        log "屏保: 已重载 (备用)"
    fi
}

FORCE=0
QUIET=0
[ "$1" = "force" ] && FORCE=1
[ "$1" = "quiet" ] && QUIET=1    # 静默换图: 不刷屏、不重启服务(正要锁屏时用)

# ---------- 防并发: 上一轮还没跑完就直接退出 ----------
# 陈旧锁保护: 锁文件超过 10 分钟一律视为残留并清除。
# 否则万一 PID 被系统复用, kill -0 会误判"还在跑", 脚本将永远静默退出。
if [ -f "$LOCK" ]; then
    stale=$(find "$LOCK" -mmin +10 2>/dev/null)
    if [ -z "$stale" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
        exit 0
    fi
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

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
    # 唤醒监听守护 (Kindle 7 休眠是真挂起, crond 不跑, RTC 闹钟也不生效;
    # 只能靠"唤醒事件"触发同步。用 upstart 常驻, 重启自启)
    mntroot rw
    UPSTART_CONF="/etc/upstart/notice_sync_watch.conf"
    if [ "$1" = "enable_cron" ]; then
        cat > "$UPSTART_CONF" << 'UPSTART_EOF'
description "kindle notice board wake watch"
start on started lab126_gui
stop on stopping lab126_gui
exec /mnt/us/notice_sync/wake-watch.sh
respawn
UPSTART_EOF
        start notice_sync_watch 2>/dev/null || initctl start notice_sync_watch 2>/dev/null
        # 兜底: upstart 的 start 调不通时, 直接后台拉起守护
        if ! ps 2>/dev/null | grep -v grep | grep -q "wake-watch.sh"; then
            (setsid /mnt/us/notice_sync/wake-watch.sh >/dev/null 2>&1 &)
        fi
        log "定时: 唤醒监听守护已启动"
    else
        stop notice_sync_watch 2>/dev/null || initctl stop notice_sync_watch 2>/dev/null
        rm -f "$UPSTART_CONF"
        log "定时: 唤醒监听守护已停止"
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
    [ "$1" = "enable_cron" ] &&    exit 0
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
    log "OK: 屏保已更新 ($size bytes)"
    # 静默模式: 只换文件, 不做任何会唤醒屏幕的动作
    # (刷屏和重启屏保服务都会把设备从锁屏状态拉回来, 导致锁不上屏)
    if [ "$QUIET" -eq 1 ]; then
        log "OK: 已静默换图 (不刷屏)"
    else
        FBINK="/mnt/us/linkss/bin/fbink"
        if [ -x "$FBINK" ]; then
            "$FBINK" -g "file=$OUT_PNG" -f >/dev/null 2>&1
            log "显示: 已刷屏 (fbink)"
        else
            eips -f "$OUT_PNG" >/dev/null 2>&1
            log "显示: 已刷屏 (eips)"
        fi
    fi
else
    log "ERROR: 下载失败或文件无效, 保留旧屏保"
fi
rm -f "$TMP"

lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1
# 预约下一次唤醒(保持闹钟有效; 真正生效靠休眠瞬间那次写入)
[ -x /mnt/us/notice_sync/arm-wake.sh ] && /mnt/us/notice_sync/arm-wake.sh
exit 0
