#!/usr/bin/env python3
"""
每日抓取 Pixiv 小说榜单，积累数据并生成月榜 / 年榜 / 长篇榜。

用法：
  PIXIV_REFRESH_TOKEN=xxx python3 crawl_rankings.py <data_dir> [--days N] [--weeks N]

数据目录结构（rank-data 分支）：
  months/YYYY-MM.json   该月出现在任一榜单中的全部作品（id -> 精简记录，保留最新数据）
  rank/index.json       可用的月份 / 年份
  rank/month/YYYY-MM.json, rank/year/YYYY.json, rank/long.json   App 读取的榜单
"""
import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone

CLIENT_ID = "MOBrBDS8blbauoSck0ZfDbtuzpyT"
CLIENT_SECRET = "lsACyCD94FhDUtGTXi3QzcFE2uU1hqtDaKeqrdwj"
HASH_SECRET = "28c1fdd170a5204386cb1313c7077b34f83e4aaf4aa829ce78c231e05b0bae2c"
API = "https://app-api.pixiv.net"
UA_OAUTH = "PixivAndroidApp/5.0.234 (Android 11; Pixel 5)"
UA_API = "PixivIOSApp/7.19.1 (iOS 17.5; iPhone15,2)"

DAILY_MODES = ["day", "day_r18", "day_male", "day_female", "day_male_r18", "day_female_r18"]
WEEKLY_MODES = ["week", "week_r18", "week_rookie"]
MAX_PAGES = 20
REQUEST_INTERVAL = 1.2  # 秒，避免触发限流

LONG_MIN = 50000


def client_headers():
    t = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00")
    return {"X-Client-Time": t, "X-Client-Hash": hashlib.md5((t + HASH_SECRET).encode()).hexdigest()}


def http(url, data=None, headers=None, retries=4):
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, data=data, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")[:300]
            if e.code == 429 and attempt < retries:
                wait = 15 * (2 ** attempt)
                print(f"  429，等待 {wait}s", flush=True)
                time.sleep(wait)
                continue
            if e.code == 404:
                return None
            raise RuntimeError(f"HTTP {e.code} {url}: {body}")
        except urllib.error.URLError as e:
            if attempt < retries:
                time.sleep(5)
                continue
            raise


class Pixiv:
    def __init__(self, refresh_token):
        self.refresh_token = refresh_token
        self.access_token = None
        self.last = 0.0
        self.auth()

    def auth(self):
        body = urllib.parse.urlencode({
            "client_id": CLIENT_ID, "client_secret": CLIENT_SECRET,
            "grant_type": "refresh_token", "refresh_token": self.refresh_token, "include_policy": "true",
        }).encode()
        h = {"User-Agent": UA_OAUTH, "Content-Type": "application/x-www-form-urlencoded", **client_headers()}
        r = http("https://oauth.secure.pixiv.net/auth/token", body, h)
        self.access_token = r["access_token"]
        print(f"已登录：{r['user']['name']}", flush=True)

    def get(self, url):
        wait = REQUEST_INTERVAL - (time.time() - self.last)
        if wait > 0:
            time.sleep(wait)
        self.last = time.time()
        h = {"User-Agent": UA_API, "App-OS": "ios", "Accept-Language": "zh-hans",
             "Authorization": f"Bearer {self.access_token}", **client_headers()}
        try:
            return http(url, headers=h)
        except RuntimeError as e:
            if "OAuth" in str(e) or "HTTP 401" in str(e):
                self.auth()
                h["Authorization"] = f"Bearer {self.access_token}"
                return http(url, headers=h)
            raise

    def ranking(self, mode, day):
        q = urllib.parse.urlencode({"mode": mode, "filter": "for_ios", "date": day.isoformat()})
        url = f"{API}/v1/novel/ranking?{q}"
        novels, pages = [], 0
        while url and pages < MAX_PAGES:
            r = self.get(url)
            if not r:
                break
            novels += r.get("novels", [])
            url = r.get("next_url")
            pages += 1
        return novels


def slim(n):
    """精简为 App 可直接解码的 Novel 结构"""
    cap = n.get("caption") or ""
    return {
        "id": n["id"],
        "title": n.get("title", ""),
        "caption": cap[:200],
        "x_restrict": n.get("x_restrict", 0),
        "is_original": n.get("is_original", False),
        "image_urls": {"medium": (n.get("image_urls") or {}).get("medium")},
        "create_date": n.get("create_date"),
        "tags": [{"name": t.get("name"), "translated_name": t.get("translated_name")} for t in n.get("tags", [])][:12],
        "page_count": n.get("page_count"),
        "text_length": n.get("text_length", 0),
        "user": {
            "id": n["user"]["id"], "name": n["user"].get("name", ""),
            "profile_image_urls": {"medium": (n["user"].get("profile_image_urls") or {}).get("medium")},
        },
        "series": {"id": n["series"]["id"], "title": n["series"].get("title")} if (n.get("series") or {}).get("id") else None,
        "total_bookmarks": n.get("total_bookmarks", 0),
        "total_view": n.get("total_view", 0),
        "total_comments": n.get("total_comments", 0),
        "novel_ai_type": n.get("novel_ai_type", 0),
    }


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def save_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))


def record(data_dir, day, mode, novels, cache):
    """把一期榜单写入对应月份文件"""
    key = day.strftime("%Y-%m")
    if key not in cache:
        cache[key] = load_json(os.path.join(data_dir, "months", f"{key}.json"), {"novels": {}, "crawled": []})
    month = cache[key]
    for rank, n in enumerate(novels, 1):
        sid = str(n["id"])
        rec = slim(n)
        old = month["novels"].get(sid)
        best = min(rank, old.get("_best_rank", rank)) if old else rank
        modes = sorted(set((old or {}).get("_modes", [])) | {mode})
        rec["_best_rank"], rec["_modes"] = best, modes
        month["novels"][sid] = rec
    tag = f"{day.isoformat()}:{mode}"
    if tag not in month["crawled"]:
        month["crawled"].append(tag)


def crawled(cache, data_dir, day, mode):
    key = day.strftime("%Y-%m")
    if key not in cache:
        cache[key] = load_json(os.path.join(data_dir, "months", f"{key}.json"), {"novels": {}, "crawled": []})
    return f"{day.isoformat()}:{mode}" in cache[key]["crawled"]


def publish(data_dir):
    """根据月份数据生成 App 读取的榜单文件"""
    months_dir = os.path.join(data_dir, "months")
    out = os.path.join(data_dir, "rank")
    months = sorted(f[:-5] for f in os.listdir(months_dir) if f.endswith(".json")) if os.path.isdir(months_dir) else []
    all_novels = {}
    by_year = {}
    for m in months:
        data = load_json(os.path.join(months_dir, f"{m}.json"), {"novels": {}})
        lst = sorted(data["novels"].values(), key=lambda x: -x.get("total_bookmarks", 0))
        save_json(os.path.join(out, "month", f"{m}.json"),
                  {"novels": lst, "next_url": None, "period": m, "days": len({c.split(':')[0] for c in data.get('crawled', [])})})
        y = m[:4]
        for n in lst:
            all_novels[n["id"]] = n
            by_year.setdefault(y, {})[n["id"]] = n
    years = sorted(by_year)
    for y in years:
        lst = sorted(by_year[y].values(), key=lambda x: -x.get("total_bookmarks", 0))[:3000]
        save_json(os.path.join(out, "year", f"{y}.json"), {"novels": lst, "next_url": None, "period": y})
    long_list = sorted((n for n in all_novels.values() if n.get("text_length", 0) >= LONG_MIN),
                       key=lambda x: -x.get("total_bookmarks", 0))[:2000]
    save_json(os.path.join(out, "long.json"), {"novels": long_list, "next_url": None, "min_length": LONG_MIN})
    save_json(os.path.join(out, "index.json"), {
        "months": months, "years": years, "total": len(all_novels),
        "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    print(f"已生成：{len(months)} 个月，{len(years)} 年，共 {len(all_novels)} 篇，长篇 {len(long_list)} 篇")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data_dir")
    ap.add_argument("--days", type=int, default=2, help="抓取最近 N 天的日榜")
    ap.add_argument("--weeks", type=int, default=1, help="抓取最近 N 周的周榜")
    ap.add_argument("--publish-only", action="store_true")
    a = ap.parse_args()

    if not a.publish_only:
        token = os.environ.get("PIXIV_REFRESH_TOKEN", "").strip()
        if not token:
            sys.exit("缺少 PIXIV_REFRESH_TOKEN：请在仓库 Settings → Secrets and variables → Actions 中添加")
        px = Pixiv(token)
        cache = {}
        yesterday = date.today() - timedelta(days=1)
        jobs = [(yesterday - timedelta(days=i), m) for i in range(a.days) for m in DAILY_MODES]
        jobs += [(yesterday - timedelta(days=7 * i), m) for i in range(a.weeks) for m in WEEKLY_MODES]
        today_tag = yesterday
        for day, mode in jobs:
            # 历史期次抓过就跳过；最近一天总是刷新（更新收藏数）
            if day < today_tag and crawled(cache, a.data_dir, day, mode):
                continue
            try:
                novels = px.ranking(mode, day)
            except Exception as e:  # noqa: BLE001
                print(f"  {day} {mode} 失败：{e}", flush=True)
                continue
            print(f"{day} {mode}: {len(novels)} 篇", flush=True)
            record(a.data_dir, day, mode, novels, cache)
            # 及时落盘，避免中途失败丢数据
            key = day.strftime("%Y-%m")
            save_json(os.path.join(a.data_dir, "months", f"{key}.json"), cache[key])
    publish(a.data_dir)


if __name__ == "__main__":
    main()
