#!/usr/bin/env python3
"""生成分发页需要的 version.json 与软件源 source.json（兼容全能签/ESign 与 AltStore 字段）。"""
import json
import os
import sys
from datetime import datetime, timezone

site, ipa = sys.argv[1], sys.argv[2]
owner = os.environ.get("OWNER", "owner").lower()
repo = os.environ.get("REPO", "PixNovel")
base = f"https://{owner}.github.io/{repo}/"
version = os.environ.get("VERSION", "1.0.0")
build = os.environ.get("BUILD", "0")
size = os.path.getsize(ipa)
now = datetime.now(timezone.utc)
notes = (os.environ.get("COMMIT_MSG") or "").strip().splitlines()
note = notes[0] if notes else "更新"

desc = "Pixiv 第三方小说阅读客户端：热度排序（非会员可用）、排行榜、系列追更、多主题阅读器。"

meta = {
    "name": "PixNovel",
    "version": version,
    "build": build,
    "size": size,
    "date": now.strftime("%Y-%m-%d %H:%M UTC"),
    "commit": os.environ.get("SHA", "")[:7],
    "notes": note,
    "ipa": base + "PixNovel.ipa",
    "source": base + "source.json",
}

app = {
    # 全能签 / ESign 源字段
    "name": "PixNovel",
    "version": f"{version}",
    "type": 0,
    "versionDate": now.strftime("%Y-%m-%d"),
    "versionDescription": note,
    "lock": "0",
    "downloadURL": base + "PixNovel.ipa",
    "isLanZouCloud": "0",
    "iconURL": base + "icon.png",
    "tintColor": "0096FA",
    "size": size,
    # AltStore 源字段
    "bundleIdentifier": "com.pixnovel.reader",
    "developerName": owner,
    "localizedDescription": desc,
    "subtitle": "Pixiv 小说阅读",
    "versions": [{
        "version": version,
        "buildVersion": build,
        "date": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": note,
        "downloadURL": base + "PixNovel.ipa",
        "size": size,
        "minOSVersion": "16.0",
    }],
}

source = {
    "name": "PixNovel 软件源",
    "identifier": f"io.github.{owner}.{repo.lower()}",
    "message": "PixNovel 官方分发源",
    "sourceURL": base + "source.json",
    "sourceicon": base + "icon.png",
    "iconURL": base + "icon.png",
    "website": base,
    "payURL": "",
    "unlockURL": "",
    "apps": [app],
    "news": [],
}

with open(os.path.join(site, "version.json"), "w", encoding="utf-8") as f:
    json.dump(meta, f, ensure_ascii=False, indent=2)
with open(os.path.join(site, "source.json"), "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
print(json.dumps(meta, ensure_ascii=False, indent=2))
