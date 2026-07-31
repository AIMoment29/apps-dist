# apps-dist

多个 App 共用的分发中心。GitHub Pages 提供安装页，GitHub Releases 存安装包。

```
https://aimoment29.github.io/apps-dist/<你的app>/install.html
```

## 一条铁律

**安装包不进 git，走 Releases。**

git 是内容寻址的：每个文件的每个版本都是一个永久 blob。你在新提交里删掉一个包，
只是这次快照不再引用它，blob 仍然躺在历史里——因为旧提交还引用着。而 `git clone`
默认要拉全部历史，也就是全部 blob。

这个仓库为此付过学费：120 个历史 ipa 攒到 **177MB**，每个人 clone 都得等半天。
2026-07-31 重建了一次历史，现在是 **172KB**。

Releases 的 asset 不是 git 对象，`--clobber` 覆盖旧包不留任何痕迹。

## 目录长这样

```
apps-dist/
├── index.html              总入口
├── multiai/
│   ├── install.html            正式通道安装页
│   ├── install-debug.html      测试通道
│   ├── install-mac.html        Mac 版下载页
│   ├── manifest.plist          ← 里面写着包在 Releases 的地址
│   └── manifest-debug.plist
└── shareprobe/
    ├── install.html
    └── manifest.plist
```

**只有网页和清单进 git**，加起来几十 KB。

Releases 那边一个 app 一个 tag，**tag 固定不带版本号**：

```
multiai-latest      ← MultiAI.ipa / MultiAI-debug.ipa / MultiAI-mac.zip
shareprobe-latest   ← ShareProbe.ipa
```

固定 tag 的好处是下载地址是个常量，安装页、二维码、书签都不用跟着版本改：

```
https://github.com/AIMoment29/apps-dist/releases/download/multiai-latest/MultiAI.ipa
```

## 接入一个新 App

**1. 要权限**

- GitHub：`AIMoment29/apps-dist` 的 collaborator（找仓库主人加）
- Apple：Team `UNJU6RW893` 的成员，角色 **Admin**（Ad Hoc 要用 Distribution 证书，
  Developer 角色权限不够）

**2. 用模板**

仓库里有现成的：[`template/build_adhoc.sh`](template/build_adhoc.sh)。
可变的东西全在文件头「改这里」那一段，正常只需动这几行：

```bash
APP_NAME="MyApp"                  # Xcode 工程名与 scheme 名
APP_SLUG="myapp"                  # apps-dist 子目录名，也是 release tag 前缀
BUNDLE="com.example.myapp"
TITLE="我的应用"                   # 安装页上显示的名字
ICON_TEXT="M"                     # 安装页图标里的字
TEAM="UNJU6RW893"                 # 不用改
XCODE=/Applications/Xcode.app/Contents/Developer   # 你机器上 Xcode 的位置
GIT_EMAIL="you@example.com"       # 提交署名
GIT_NAME="Your Name"
```

放到你项目的 `tool/build_adhoc.sh`，然后 `bash tool/build_adhoc.sh` 就能发版。

<details>
<summary>如果想从 MultiAI/ShareProbe 的脚本直接改（不推荐）</summary>

需要动的：

```bash
DIST="${APPS_DIST_DIR:-$HOME/AIMoment/apps-dist}"   # 不用改，大家共用这一份 clone
REPO="AIMoment29/apps-dist"                          # 不用改
RELEASE_TAG="你的app-latest"                          # ← 改
APPDIR="$DIST/你的app"                                # ← 改
APPBASE="https://aimoment29.github.io/apps-dist/你的app"   # ← 改
BUNDLE=com.aimoment.你的app                           # ← 改
```

再把 `-scheme`、页面标题、安装页里的项目专属文案换成你自己的 ——
散落在整个文件里十几处，容易漏，所以还是建议用模板。

</details>

**3. 上传用这两句**

```bash
# release 不存在就先建（只会执行一次）
gh release view "$RELEASE_TAG" --repo "$REPO" >/dev/null 2>&1 || \
  gh release create "$RELEASE_TAG" --repo "$REPO" --title "..." --notes "..."

# 每次发版覆盖同名 asset
gh release upload "$RELEASE_TAG" "$ipa" --clobber --repo "$REPO"
```

`gh` 拿**文件名**当 asset 名，所以上传前先把 ipa 改成最终要的名字。

**4. manifest 指向 Releases**

```xml
<key>url</key>
<string>https://github.com/AIMoment29/apps-dist/releases/download/你的app-latest/你的App.ipa</string>
```

iOS 对包的位置只有一个要求：**HTTPS 可达**。放 Releases 和放仓库里对它没区别。

## 三条容易踩的

**① clone 放在项目外，大家共用一份**

```bash
DIST="${APPS_DIST_DIR:-$HOME/AIMoment/apps-dist}"
```

早先是每个项目在自己目录下 clone 一个 `dist-repo`，于是每个项目里都躺着一份别人的
东西——打开 multiai 却看到 shareprobe，很费解。它只是个工作缓存，不属于任何项目。

**② push 要写全 `origin main`**

```bash
git -C "$DIST" push -q origin main
```

不写的话依赖 upstream 配置，而那个配置在重建分支后会丢，表现是「包都传上去了，
最后一步报 no upstream branch」。

**③ push 之后一定要核对**

```bash
git -C "$DIST" fetch -q origin
[ "$(git -C "$DIST" rev-parse HEAD)" = "$(git -C "$DIST" rev-parse origin/main)" ] || exit 1
```

`git push` 失败被静默咽掉、脚本继续宣布「已发布」，这个坑踩过。

## .gitignore 已经挡了包

```
multiai/*.ipa
multiai/*.zip
multiai/*.dmg
shareprobe/*.ipa
shareprobe/*.zip
```

加新 app 时把你的目录也加进去——脚本写错时这是最后一道防线。
