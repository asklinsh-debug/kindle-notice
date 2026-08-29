#!/bin/sh
# 预约下一次唤醒 (RTC 硬件闹钟)
#
# 关键点: Kindle 的电源守护(powerd)在设备休眠时会自己写一个 wakealarm,
# 把之前写的覆盖掉。所以必须在"设备即将休眠"的那一刻(goingToScreenSaver)
# 才写, 闹钟才能生效。这就是 kindle 社区定时唤醒的标准做法。
#
# 唤醒时刻: 每个小时的 :00 和 :30 (绝对时刻, 不漂移)

WAKE_DEV="/sys/class/rtc/rtc0/wakealarm"
LOG="/mnt/us/notice_sync.log"

[ -w "$WAKE_DEV" ] || {
    echo "$(date '+%F %T') WAKE: 本机不支持 RTC 唤醒" >> "$LOG"
    exit 1
}

now=$(date +%s)
m=$(( now / 60 ))                 # 自 epoch 起的分钟数
moh=$(( m % 60 ))                 # 当前小时的第几分钟
base=$(( m - moh ))               # 当前整点

if [ "$moh" -lt 30 ]; then
    target=$(( base + 30 ))       # 本小时 :30
else
    target=$(( base + 60 ))       # 下一小时 :00
fi
next=$(( target * 60 ))

echo 0 > "$WAKE_DEV" 2>/dev/null
echo "$next" > "$WAKE_DEV" 2>/dev/null

# 校验: 读回来看看有没有写进去
got=$(cat "$WAKE_DEV" 2>/dev/null)
echo "$(date '+%F %T') WAKE: 预约唤醒 -> $(date '+%H:%M' -d "@$next" 2>/dev/null) (闹钟值=$got)" >> "$LOG"
exit 0
