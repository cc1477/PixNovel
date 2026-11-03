# PixNovel

Pixiv 第三方 iOS 小说阅读客户端（SwiftUI，iOS 16+），参考 [Pixiv-Shaft](https://github.com/CeuiLiSA/Pixiv-Shaft) 的思路，专注于小说阅读。

## 功能

- **热度排序**
  - 会员：直接使用官方 `popular_desc`，并可在本地二次排序
  - 非会员：三路聚合 → 本地排序
    1. `/v1/search/popular-preview/novel` 官方热门预览
    2. `xxx 10000/5000/1000/500/100users入り` 标签补充高收藏作品
    3. 并发扫描 `date_desc` 多页（最多约 5000 篇），时间范围越小覆盖越完整
  - 排序指标：综合热度（收藏 + 阅读 + 评论加权，带可调时间衰减）、收藏数、阅读数、收藏率（贝叶斯平滑）、日均收藏、评论数、最新、字数
  - 过滤：最低收藏、字数区间、隐藏 AI、仅原创、仅系列、排除标签
  - 排行榜、推荐、作者页、收藏夹同样可以按以上指标重新排序
- 排行榜：日 / 周 / 男性向 / 女性向 / 新人 / AI / R-18，支持历史日期
- 阅读器：连续滚动 / 按原文 `[newpage]` 分页，章节目录，注音 `[[rb:]]`、插图，阅读进度自动保存，上一话 / 下一话
- 6 种阅读主题，可调字体、字号、行距、段距、页边距、段首缩进
- 账号：网页 OAuth（PKCE）登录或 refresh_token 登录，凭证存于钥匙串
- 收藏 / 取消收藏、关注作者、系列目录、标签屏蔽、R-18 开关、图片反代（i.pixiv.re）

## 构建

本地需要 macOS + Xcode 16 + [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
brew install xcodegen
xcodegen generate
open PixNovel.xcodeproj
```

推送到 `main` 后，GitHub Actions（`.github/workflows/build.yml`）会自动：

1. 在 macOS runner 上编译未签名的 `PixNovel.ipa`
2. 发布到 GitHub Release
3. 把 `docs/` 分发页、IPA、`source.json` 软件源部署到 GitHub Pages

> 首次使用需在仓库 **Settings → Pages → Build and deployment → Source** 中选择 **GitHub Actions**。

## 分发页

`https://<用户名>.github.io/PixNovel/`

| 按钮 | 唤起格式 |
| --- | --- |
| 全能签安装 | `nsk-sign://web?url=<IPA 地址>` |
| 全能签添加源 | `nsk-sign://addsource?url=<source.json>` |
| LCSign 安装 | `loadcontroller://import?url=<IPA 地址>` |
| LCSign 添加源 | `loadcontroller://addsource?url=<source.json>` |

## 声明

本项目与 pixiv Inc. 无关，仅供学习交流。作品版权归原作者所有。
