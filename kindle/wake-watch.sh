#!/bin/sh
# 唤醒/休眠监听守护:
#   1) 设备被唤醒(outOfScreenSaver)   -> 立刻同步一次
#   2) 设备即将休眠(goingToScreenSaver) -> 在那一刻预约 :00/:30 的 RTC 闹钟
#      (必须在这时写, 否则会被系统的电源守护覆盖掉)
# 由 sync.sh enable_cron 启动, disable_cron 停止。

PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
LOG=/mnt/us/notice_sync.log
FLAG=/mnt/us/notice_sync/.cron_enabled
ARM="/mnt/us/notice_sync/arm-wake.sh"

# 守护没被启用就直接退出
[ -f "$FLAG" ] || exit 0

# 只留一个实例: 已有在跑的就退出
PIDFILE="/mnt/us/notice_sync/.watch.pid"
if [ -f "$PIDFILE" ]; then
    kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null && exit 0
    rm -f "$PIDFILE"
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

echo "$(date '+%F %T') WATCH: 监听守护已启动" >> "$LOG"

# --- 分支1: 监听"即将休眠", 在休眠瞬间预约闹钟 ---
(
    while true; do
        lipc-wait-event -m -s 0 com.lab126.powerd goingToScreenSaver >/dev/null 2>&1
        [ -f "$FLAG" ] || break
        # 稍等一下, 让电源守护先写完它自己的闹钟, 我们再覆盖
        sleep 2
        [ -x "$ARM" ] && "$ARM"
    done
) &

# --- 分支2: 监听"被唤醒", 立刻同步 ---
while true; do
    lipc-wait-event -m -s 0 com.lab126.powerd outOfScreenSaver >/dev/null 2>&1
    [ -f "$FLAG" ] || break
    sleep 3
    /mnt/us/notice_sync/sync.sh sync
done

echo "$(date '+%F %T') WATCH: 监听守护已停止" >> "$LOG"
exit 0
