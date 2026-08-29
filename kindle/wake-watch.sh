#!/bin/sh
# 唤醒调度守护 (Kindle 定时自动更新的核心)
#
# 原理: Kindle 休眠是真挂起, crond 停止运行。要定时更新, 必须让设备定时醒来。
#       正确做法是用 powerd 的 rtcWakeup 接口(单位: 秒), 在设备"即将挂起"
#       (readyToSuspend)的那一刻预约下次唤醒时间。
#       (之前试的 /sys/class/rtc/rtc0/wakealarm 在这台机器上无效, 是错的接口)
#
# 事件流:
#   readyToSuspend     -> 预约 30 分钟后唤醒 (rtcWakeup 1800)
#   wakeupFromSuspend  -> 被闹钟叫醒, 立刻同步
#   goingToScreenSaver -> 进入屏保, 同步一次并重载 linkss
#
# 参考: KindleCron / kindle-display 项目的做法

PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
LOG="/mnt/us/notice_sync.log"
FLAG="/mnt/us/notice_sync/.cron_enabled"
INTERVAL=1800        # 唤醒间隔(秒): 1800 = 30 分钟 -> 每小时更新两次

# 守护没被启用就直接退出
[ -f "$FLAG" ] || exit 0

# 只留一个实例
PIDFILE="/mnt/us/notice_sync/.watch.pid"
if [ -f "$PIDFILE" ]; then
    kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null && exit 0
    rm -f "$PIDFILE"
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

echo "$(date '+%F %T') WATCH: 调度守护已启动 (间隔 ${INTERVAL}s)" >> "$LOG"

lipc-wait-event -m com.lab126.powerd goingToScreenSaver,wakeupFromSuspend,resuming,readyToSuspend 2>/dev/null | while read event; do
    [ -f "$FLAG" ] || break
    case "$event" in
        readyToSuspend*)
            # 即将挂起: 预约下次唤醒 (这是定时更新的关键一步)
            lipc-set-prop -i com.lab126.powerd rtcWakeup "$INTERVAL" >/dev/null 2>&1
            echo "$(date '+%F %T') WAKE: 预约 ${INTERVAL}s 后唤醒" >> "$LOG"
            ;;
        wakeupFromSuspend*|resuming*)
            # 被闹钟叫醒了: 等 WiFi/框架就绪后立刻同步
            sleep 8
            /mnt/us/notice_sync/sync.sh sync
            ;;
        goingToScreenSaver*)
            # 进入屏保: 同步一次(换图后 linkss 会在下次休眠生效)
            /mnt/us/notice_sync/sync.sh sync
            ;;
    esac
done

echo "$(date '+%F %T') WATCH: 调度守护已停止" >> "$LOG"
exit 0
