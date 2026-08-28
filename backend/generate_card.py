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
W, H = 600, 800   # Kindle 7 / 600x800 竖屏 (如换设备, 按屏幕实际像素改这里)
OUT = os.environ.get("OUTPUT_PATH", "notice.png")

CITY = os.environ.get("CITY", "菏泽")
LAT = os.environ.get("LAT", "35.24")     # 纬度
LON = os.environ.get("LON", "115.48")    # 经度

TZ = timezone(timedelta(hours=8))  # 东八区

FONT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts")
FONT_REG = os.path.join(FONT_DIR, "SourceHanSansSC-Regular.otf")
FONT_BOLD = os.path.join(FONT_DIR, "SourceHanSansSC-Heavy.otf")

# 远程公告 (手机端发布, 持久化在仓库根目录 notice_config.env)
NOTICE_TEXT = ""
NOTICE_UNTIL = ""   # 格式: 2026-09-05 18:00 或 2026-09-05, 留空=长期有效
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
    """常规时间看板 (600x800 竖版)"""
    img = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(img)

    # ---- 顶部黑条: 日期 / 农历节气 ----
    d.rectangle([0, 0, W, 62], fill=0)
    f_head = font(26, bold=True)
    d.text((24, 19), f"{now:%m月%d日} 周{WEEK_CN[now.weekday()]}", font=f_head, fill=255)
    if lunar_line:
        rtext(d, W - 24, 21, lunar_line, font(23), fill=255)

    # ---- 大时钟 (y 70~290) ----
    f_clock = font(176, bold=True)
    clock = f"{now:%H:%M}"
    bb = f_clock.getbbox(clock)
    cw = bb[2] - bb[0]
    ch = bb[3] - bb[1]
    d.text(((W - cw) / 2 - bb[0], 182 - ch / 2 - bb[1]), clock, font=f_clock, fill=0)

    # ---- 分隔线 ----
    d.line([40, 300, W - 40, 300], fill=0, width=3)

    # ---- 天气区 (y 320~470) ----
    if weather:
        # 左侧图标框
        d.rectangle([40, 320, 185, 462], outline=0, width=5)
        f_icon = font(74, bold=True)
        bb = f_icon.getbbox(weather["icon"])
        d.text(
            (112.5 - (bb[2] - bb[0]) / 2 - bb[0], 391 - (bb[1] + bb[3]) / 2),
            weather["icon"], font=f_icon, fill=0,
        )
        # 右侧: 温度 + 描述
        f_temp = font(76, bold=True)
        d.text((212, 328), f'{weather["temp"]}°', font=f_temp, fill=0)
        f_desc = font(25)
        d.text((214, 424), f'{weather["desc"]}｜湿度{weather["rh"]}%', font=f_desc, fill=0)
        # 极右列: 温度区间 / 节假日 / 风力
        f_range = font(30, bold=True)
        rtext(d, W - 32, 344, f'{weather["tmin"]}~{weather["tmax"]}°', f_range)
        if holiday:
            rtext(d, W - 32, 400, holiday, font(22))
        rtext(d, W - 32, 430, f'风{weather["wind"]}km/h', font(20))
    else:
        f_err = font(32)
        d.text((60, 380), "天气获取失败，仅显示时间与问候", font=f_err, fill=0)
        if holiday:
            rtext(d, W - 36, 398, holiday, font(23))

    # ---- 每日一句话卡片 (y 500~665, 最多 3 行) ----
    d.rectangle([40, 498, W - 40, 662], outline=0, width=3)
    f_q = font(30)
    lines = wrap(quote, f_q, 470)[:3]
    y = {1: 566, 2: 546, 3: 526}[len(lines)]
    for ln in lines:
        ctext(d, W / 2, y, ln, f_q)
        y += 42

    # ---- 页脚 (贴近底部) ----
    f_foot = font(19)
    ctext(d, W / 2, 766, f"{now:%Y} · {CITY} · 自动更新于 {now:%m-%d %H:%M}", f_foot)

    img.save(OUT, "PNG")
    print(f"saved: {OUT} ({os.path.getsize(OUT)} bytes)")


def parse_until(s):
    """解析下线时间, 支持 2026-09-05 18:00 / 2026-09-05"""
    if not s:
        return None
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=TZ)
        except ValueError:
            pass
    return None


def load_notice_config():
    """读取仓库根目录 notice_config.env (手机发布入口, 持久化公告)"""
    global NOTICE_TEXT, NOTICE_UNTIL
    p = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "notice_config.env",
    )
    if not os.path.exists(p):
        return
    try:
        with open(p, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                if k == "NOTICE_TEXT" and v.strip():
                    NOTICE_TEXT = v.strip()
                elif k == "NOTICE_UNTIL" and v.strip():
                    NOTICE_UNTIL = v.strip()
    except Exception as e:
        print("notice config failed:", e)


def draw_notice_board(now, text, until, weather):
    """远程公告模式 (600x800 竖版): 大字公告 + 底部时间天气条"""
    img = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(img)

    # ---- 顶部黑条: 公告 / 有效期 ----
    d.rectangle([0, 0, W, 62], fill=0)
    f_head = font(28, bold=True)
    d.text((24, 18), "公 告", font=f_head, fill=255)
    tag = f"至 {until:%m-%d %H:%M} 前" if until else "长期有效"
    rtext(d, W - 24, 21, tag, font(23), fill=255)

    # ---- 公告正文 (最多 10 行, 超出截断) ----
    f_body = font(44, bold=True)
    lines = wrap(text, f_body, 520)
    if len(lines) > 10:
        lines = lines[:10]
        lines[-1] = lines[-1][:-1] + "…"
    y = 300 - (len(lines) - 1) * 28  # 垂直居中于 ~110..500
    for ln in lines:
        ctext(d, W / 2, y, ln, f_body)
        y += 56

    # ---- 底部状态条: 时间 + 天气 ----
    d.line([40, 680, W - 40, 680], fill=0, width=3)
    f_clock = font(66, bold=True)
    d.text((56, 712), f"{now:%H:%M}", font=f_clock, fill=0)
    if weather:
        f_w = font(30, bold=True)
        rtext(d, W - 56, 730, f'{weather["desc"]} {weather["temp"]}°', f_w)

    img.save(OUT, "PNG")
    print(f"saved (NOTICE MODE): {OUT} ({os.path.getsize(OUT)} bytes)")


def main():
    now = datetime.now(TZ)
    load_notice_config()
    until = parse_until(NOTICE_UNTIL)

    # 公告激活条件: 有内容 且 (未设下线时间 或 未到期) -> 到期自动切回常规看板
    if NOTICE_TEXT and (until is None or now <= until):
        weather = get_weather()
        print(f"notice active, until: {until or 'forever'}")
        draw_notice_board(now, NOTICE_TEXT, until, weather)
        return

    # 常规时间看板
    weather = get_weather()
    lunar_line = get_lunar_line(now)
    holiday = get_next_holiday(now)
    quote = llm_greeting(now) or FALLBACK_QUOTES[now.timetuple().tm_yday % len(FALLBACK_QUOTES)]
    print(f"quote: {quote}")
    draw_board(now, weather, lunar_line, holiday, quote)


if __name__ == "__main__":
    main()
