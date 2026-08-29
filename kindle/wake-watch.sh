#!/bin/sh
# 唤醒监听守护: 订阅 Kindle powerd 的唤醒事件, 每次唤醒后立刻同步一次
# 由 sync.sh enable_cron 启动, disable_cron 停止。
# 为什么要这个: Kindle 7 休眠是真挂起, crond 不跑, RTC 闹钟也不生效,
# 唯一可靠的时机就是"设备被唤醒的那一刻"。

PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
LOG=/mnt/us/notice_sync.log
FLAG=/mnt/us/notice_sync/.cron_enabled

# 守护没被启用就直接退出
[ -f "$FLAG" ] || exit 0

echo "$(date '+%F %T') WATCH: 唤醒监听守护已启动" >> "$LOG"

while true; do
    # 阻塞等待"从屏保唤醒"事件 (linkss 的 usb-watchdog 同款机制)
    lipc-wait-event -m -s 0 com.lab126.powerd outOfScreenSaver >/dev/null 2>&1
    [ -f "$FLAG" ] || break          # 被关闭了就退出
    sleep 3                          # 等框架稳定
    /mnt/us/notice_sync/sync.sh sync
done

echo "$(date '+%F %T') WATCH: 唤醒监听守护已停止" >> "$LOG"
exit 0
