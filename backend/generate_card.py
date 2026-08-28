#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
墨水屏公告板图片生成器 (800x600, 黑白高对比度)

数据源:
  - Open-Meteo 天气 API   (免 key, https://open-meteo.com)
  - cnlunar 农历/节气     (纯 Python 库, 离线计算)
  - timor.tech 节假日 API (免 key, 可选)
  - 大模型每日问候 (可选): 智谱 GLM, GitHub Secrets 里配 GLM_API_KEY

输出: notice.png (800x600)

字体: 需要把思源黑体放到 fonts/ 目录 (workflow 会自动下载):
  fonts/SourceHanSansSC-Regular.otf
  fonts/SourceHanSansSC-Heavy.otf
"""
import os
import json
import urllib.request
from datetime import datetime, timezone, timedelta

from PIL import Image, ImageDraw, ImageFont

try:
    from cnlunar import Lunar
    HAS_LUNAR = True
except ImportError:
    HAS_LUNAR = False

# ==================== 配置 ====================
W, H = 800, 600
OUT = os.environ.get("OUTPUT_PATH", "notice.png")

CITY = os.environ.get("CITY", "菏泽")
LAT = os.environ.get("LAT", "35.24")     # 纬度
LON = os.environ.get("LON", "115.48")    # 经度

TZ = timezone(timedelta(hours=8))  # 东八区

FONT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts")
FONT_REG = os.path.join(FONT_DIR, "SourceHanSansSC-Regular.otf")
FONT_BOLD = os.path.join(FONT_DIR, "SourceHanSansSC-Heavy.otf")
# =============================================

WEEK_CN = ["一", "二", "三", "四", "五", "六", "日"]

# Open-Meteo WMO 天气代码 -> (描述, 图标大字)
WMO = {
    0: ("晴", "晴"), 1: ("晴间多云", "云"), 2: ("多云", "云"), 3: ("阴", "阴"),
    45: ("雾", "雾"), 48: ("雾凇", "雾"),
    51: ("毛毛雨", "雨"), 53: ("毛毛雨", "雨"), 55: ("大毛毛雨", "雨"),
    56: ("冻雨", "雨"), 57: ("冻雨", "雨"),
    61: ("小雨", "雨"), 63: ("中雨", "雨"), 65: ("大雨", "雨"),
    66: ("冻雨", "雨"), 67: ("冻雨", "雨"),
    71: ("小雪", "雪"), 73: ("中雪", "雪"), 75: ("大雪", "雪"), 77: ("雪粒", "雪"),
    80: ("阵雨", "雨"), 81: ("阵雨", "雨"), 82: ("强阵雨", "雨"),
    85: ("阵雪", "雪"), 86: ("阵雪", "雪"),
    95: ("雷阵雨", "雷"), 96: ("雷阵雨", "雷"), 99: ("冰雹雷雨", "雷"),
}

FALLBACK_QUOTES = [
    "一日之计在于晨，先把最重要的事做完",
    "读一页书，胜过刷十分钟手机",
    "天气好的话，出门走走晒晒太阳",
    "多喝热水，按时吃饭，早点睡觉",
    "慢慢来，比较快",
    "今天也要记得给家里打个电话",
    "运动半小时，精神一整天",
    "把烦恼写下来，就没那么重了",
    "学一点新东西，哪怕只是一小步",
    "窗外的世界比屏幕里的更精彩",
    "深呼吸三次，再开始工作",
    "今天圆满收尾，明天轻装上阵",
]


def font(size, bold=False):
    path = FONT_BOLD if (bold and os.path.exists(FONT_BOLD)) else FONT_REG
    if not os.path.exists(path):
        raise SystemExit(
            f"缺少字体文件: {path}\n"
            "请将思源黑体放入 fonts/ 目录, 或确认 workflow 的字体下载步骤已执行"
        )
    return ImageFont.truetype(path, size)


def http_json(url, timeout=15):
    req = urllib.request.Request(url, headers={"User-Agent": "kindle-board/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


# ---------------- 数据获取 ----------------

def get_weather():
    """Open-Meteo 免 key 天气, 返回 dict 或 None"""
    url = (
        f"https://api.open-meteo.com/v1/forecast"
        f"?latitude={LAT}&longitude={LON}"
        f"&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m"
        f"&daily=temperature_2m_max,temperature_2m_min,weather_code"
        f"&forecast_days=1&timezone=Asia%2FShanghai"
    )
    try:
        d = http_json(url)
        cur = d["current"]
        daily = d["daily"]
        code = int(cur["weather_code"])
        desc, icon = WMO.get(code, ("——", "云"))
        return {
            "temp": round(float(cur["temperature_2m"])),
            "rh": int(cur["relative_humidity_2m"]),
            "wind": round(float(cur["wind_speed_10m"])),
            "tmax": round(float(daily["temperature_2m_max"][0])),
            "tmin": round(float(daily["temperature_2m_min"][0])),
            "desc": desc,
            "icon": icon,
        }
    except Exception as e:
        print("weather failed:", e)
        return None


def get_lunar_line(now):
    """农历 + 节气, 如: 农历七月十六 处暑"""
    if not HAS_LUNAR:
        return ""
    try:
        l = Lunar(datetime(now.year, now.month, now.day), godType="8char")
        parts = [f"农历{l.lunarMonthCn}{l.lunarDayCn}"]
        st = getattr(l, "todaySolarTerms", "")
        if st and st != "无":
            parts.append(st)
        return " ".join(parts)
    except Exception as e:
        print("lunar failed:", e)
        return ""


def get_next_holiday(now):
    """下一个法定节假日倒计时, 如: 国庆节还有34天 (失败返回 None)"""
    try:
        d = http_json(
            "https://timor.tech/api/holiday/next/" + now.strftime("%Y-%m-%d"),
            timeout=10,
        )
        h = d.get("holiday") or {}
        name, date = h.get("name"), h.get("date")
        if name and date:
            nd = datetime.strptime(date[:10], "%Y-%m-%d").date()
            days = (nd - now.date()).days
            if days >= 0:
                return f"{name}还有{days}天" if days > 0 else f"今天是{name}"
    except Exception as e:
        print("holiday failed:", e)
    return None


def llm_greeting(now):
    """调用智谱 GLM 生成每日问候, 未配 key 或失败返回 None"""
    key = os.environ.get("GLM_API_KEY", "").strip()
    if not key:
        return None
    try:
        prompt = (
            f"今天是{now:%Y年%m月%d日}星期{WEEK_CN[now.weekday()]}，我在{CITY}。"
            "你是一块家里老人每天都能看到的墨水屏公告板。"
            "请写一句12到24个字的简短问候或当日生活提示：温暖、具体、接地气，"
            "不要鸡汤套话，不要引号、省略号和换行。只输出这一句话本身。"
        )
        body = json.dumps({
            "model": os.environ.get("GLM_MODEL", "glm-4-flash"),
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 100,
            "temperature": 0.9,
        }).encode("utf-8")
        req = urllib.request.Request(
            "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            data=body,
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer " + key,
            },
        )
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.loads(r.read().decode("utf-8"))
        text = (data["choices"][0]["message"]["content"] or "").strip()
        for ch in "\"“”‘’。":
            text = text.replace(ch, "")
        text = text.replace("\n", " ").strip()
        if 0 < len(text) <= 40:
            return text
    except Exception as e:
        print("llm failed:", e)
    return None


# ---------------- 绘制 ----------------

def ctext(d, cx, y, text, f, fill=0):
    """水平居中画字"""
    bb = f.getbbox(text)
    w = bb[2] - bb[0]
    d.text((cx - w / 2 - bb[0], y), text, font=f, fill=fill)
    return bb[3] - bb[1]


def rtext(d, rx, y, text, f, fill=0):
    """右对齐画字"""
    bb = f.getbbox(text)
    d.text((rx - (bb[2] - bb[0]) - bb[0], y), text, font=f, fill=fill)


def wrap(text, f, max_w):
    lines, cur = [], ""
    for ch in text:
        if f.getlength(cur + ch) > max_w and cur:
            lines.append(cur)
            cur = ch
        else:
            cur += ch
    if cur:
        lines.append(cur)
    return lines


def draw_board(now, weather, lunar_line, holiday, quote):
    img = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(img)

    # ---- 顶部黑条: 日期 / 农历节气 ----
    d.rectangle([0, 0, W, 66], fill=0)
    f_head = font(28, bold=True)
    d.text((28, 20), f"{now:%Y年%m月%d日} 星期{WEEK_CN[now.weekday()]}", font=f_head, fill=255)
    if lunar_line:
        rtext(d, W - 28, 20, lunar_line, f_head, fill=255)

    # ---- 大时钟 ----
    f_clock = font(168, bold=True)
    clock = f"{now:%H:%M}"
    bb = f_clock.getbbox(clock)
    cw = bb[2] - bb[0]
    ch = bb[3] - bb[1]
    d.text(((W - cw) / 2 - bb[0], 175 - ch / 2 - bb[1]), clock, font=f_clock, fill=0)

    # ---- 分隔线 ----
    d.line([40, 300, W - 40, 300], fill=0, width=3)

    # ---- 天气区 (y 320~455) ----
    if weather:
        # 左侧图标框
        d.rectangle([40, 318, 195, 452], outline=0, width=5)
        f_icon = font(80, bold=True)
        bb = f_icon.getbbox(weather["icon"])
        d.text(
            (117.5 - (bb[2] - bb[0]) / 2 - bb[0], 385 - (bb[1] + bb[3]) / 2),
            weather["icon"], font=f_icon, fill=0,
        )
        # 中间: 当前温度 + 湿度
        f_temp = font(84, bold=True)
        d.text((225, 322), f'{weather["temp"]}°C', font=f_temp, fill=0)
        f_desc = font(28)
        d.text((228, 418), f'{weather["desc"]}｜湿度{weather["rh"]}%', font=f_desc, fill=0)
        # 右侧: 今日温度区间 / 节假日倒计时 / 风力
        f_range = font(40, bold=True)
        rtext(d, W - 42, 330, f'{weather["tmin"]}~{weather["tmax"]}°', f_range)
        f_hol = font(26)
        if holiday:
            rtext(d, W - 42, 392, holiday, f_hol)
        rtext(d, W - 42, 424, f'风{weather["wind"]}km/h', font(24))
    else:
        f_err = font(36)
        d.text((60, 370), "天气数据获取失败，仅显示时间与问候", font=f_err, fill=0)
        if holiday:
            rtext(d, W - 42, 392, holiday, font(26))

    # ---- 每日一句话卡片 (y 478~560) ----
    d.rectangle([40, 476, W - 40, 562], outline=0, width=3)
    f_q = font(30)
    lines = wrap(quote, f_q, 660)[:2]
    y = 502 if len(lines) == 1 else 490
    for ln in lines:
        ctext(d, W / 2, y, ln, f_q)
        y += 38

    # ---- 页脚 ----
    f_foot = font(20)
    ctext(d, W / 2, 576, f"{CITY} · 自动更新于 {now:%m-%d %H:%M} · 每小时刷新", f_foot)

    img.save(OUT, "PNG")
    print(f"saved: {OUT} ({os.path.getsize(OUT)} bytes)")


def main():
    now = datetime.now(TZ)
    weather = get_weather()
    lunar_line = get_lunar_line(now)
    holiday = get_next_holiday(now)
    quote = llm_greeting(now) or FALLBACK_QUOTES[now.timetuple().tm_yday % len(FALLBACK_QUOTES)]
    print(f"quote: {quote}")
    draw_board(now, weather, lunar_line, holiday, quote)


if __name__ == "__main__":
    main()
