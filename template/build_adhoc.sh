#!/usr/bin/env bash
# Ad Hoc 发版模板：打 ipa → 传 GitHub Releases → 更新 apps-dist 上的安装页。
#
# 从 MultiAI 的发版脚本改的，可变的东西全提到了下面「改这里」那一段，
# 正常情况下你只需要动那 8 行。
#
# 用法：  bash tool/build_adhoc.sh          # 正式安装页 install.html
#         bash tool/build_adhoc.sh debug    # 测试安装页 install-debug.html（不动正式页）
#
# 前置条件：
#   1) 付费 Apple Developer，目标设备 UDID 已在后台登记。
#      **新增设备后必须重跑本脚本** —— UDID 白名单是打包那一刻嵌进 ipa 的，
#      光在后台登记不算数，已发出去的包改不了。
#   2) `gh` 已登录（gh auth status 能看到账号），且有 apps-dist 的推送权限。
#   3) 手机 iOS 版本较新时需要新版 Xcode。

set -euo pipefail
cd "$(dirname "$0")/.."

# ============================ 改这里 ============================
APP_NAME="MyApp"                      # Xcode 工程名与 scheme 名（两者同名时）
APP_SLUG="myapp"                      # apps-dist 里的子目录名，也是 release tag 前缀
BUNDLE="com.example.myapp"            # bundle id
TITLE="我的应用"                       # 安装页上显示的名字
ICON_TEXT="M"                         # 安装页图标里的字，一两个字符
TEAM="UNJU6RW893"                     # Apple Team ID
XCODE=/Applications/Xcode.app/Contents/Developer
GIT_EMAIL="you@example.com"           # 提交到 apps-dist 时的署名
GIT_NAME="Your Name"
# 安装页底部想多说一句就填这里（HTML），不需要就留空
EXTRA_TIP=""
# ================================================================

# debug 通道：ipa / manifest / 安装页都带 -debug 后缀，正式页原封不动。
# 同一个 bundle id —— 手机上测试版会直接覆盖正式版（本来就是同一个 app）。
CHANNEL="${1:-}"
SUFFIX=""
if [ "$CHANNEL" = "debug" ]; then
  SUFFIX="-debug"
  TITLE="${TITLE} 测试版"
elif [ -n "$CHANNEL" ]; then
  echo "未知通道：$CHANNEL（只支持 debug 或不带参数）" >&2
  exit 1
fi

PBX="${APP_NAME}.xcodeproj/project.pbxproj"
WORK="/tmp/${APP_SLUG}-adhoc"

# 分发仓库的本地副本。**放在项目外，所有 app 共用这一份** ——
# 每个项目各 clone 一个的话，每个项目目录里都躺着一份别人的东西。
# 它只是个工作缓存，不属于任何一个项目。
DIST="${APPS_DIST_DIR:-$HOME/AIMoment/apps-dist}"
APPDIR="$DIST/${APP_SLUG}"
APPBASE="https://aimoment29.github.io/apps-dist/${APP_SLUG}"

# ipa 走 GitHub Releases，**不进 git**。
#
# git 是内容寻址的：每个文件的每个版本都是一个永久 blob。把包提交进去，
# 每发一版就在历史里永久留一份副本，而 clone 默认要拉全部历史。
# apps-dist 为此付过学费 —— 120 个历史 ipa 攒到 177MB。
#
# **tag 固定不带版本号**，每次用 --clobber 覆盖同名 asset：release 里永远只有
# 最新的一份，旧的当场删掉。好处是下载地址是个常量，安装页和二维码都不用跟着改。
REPO="AIMoment29/apps-dist"
RELEASE_TAG="${APP_SLUG}-latest"
RELEASE_BASE="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"

echo "==> 自动递增 build 号（CURRENT_PROJECT_VERSION +1）"
build=$(grep -m1 -E 'CURRENT_PROJECT_VERSION = [0-9]+;' "$PBX" | grep -oE '[0-9]+')
newbuild=$((build + 1))
# pbxproj 里两个构建配置各有一份，必须同步改，否则 Debug/Release 版本号漂移
sed -i '' "s/CURRENT_PROJECT_VERSION = ${build};/CURRENT_PROJECT_VERSION = ${newbuild};/g" "$PBX"
marketing=$(grep -m1 -E 'MARKETING_VERSION = [^;]+;' "$PBX" | sed -E 's/.*= (.*);/\1/')
ver="${marketing}+${newbuild}"
echo "    版本：${marketing}+${build}  →  ${ver}"

rm -rf "$WORK" && mkdir -p "$WORK"

echo "==> Archive（Ad Hoc 自动签名，稍等几分钟）"
DEVELOPER_DIR="$XCODE" xcodebuild \
  -project "${APP_NAME}.xcodeproj" -scheme "${APP_NAME}" \
  -destination 'generic/platform=iOS' \
  -archivePath "$WORK/${APP_NAME}.xcarchive" \
  -allowProvisioningUpdates archive -quiet

echo "==> 导出 ipa"
cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>release-testing</string>
	<key>teamID</key>
	<string>${TEAM}</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
EOF
DEVELOPER_DIR="$XCODE" xcodebuild -exportArchive \
  -archivePath "$WORK/${APP_NAME}.xcarchive" \
  -exportPath "$WORK/export" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" \
  -allowProvisioningUpdates -quiet
ipa=$(ls -1 "$WORK"/export/*.ipa | head -1)
echo "    $ipa ($(du -h "$ipa" | cut -f1))"

echo "==> 同步分发仓库"
if [ ! -d "$DIST/.git" ]; then
  git clone git@github.com:${REPO}.git "$DIST"
fi
git -C "$DIST" pull -q --ff-only 2>/dev/null || true
mkdir -p "$APPDIR"
: > "$DIST/.nojekyll"

echo "==> 上传 ipa 到 Releases（不进 git）"
# gh 拿**文件名**当 asset 名，所以上传前先改成最终要的名字
staged="$WORK/${APP_NAME}${SUFFIX}.ipa"
cp "$ipa" "$staged"
# release 不存在就先建一个（只会执行一次）
gh release view "$RELEASE_TAG" --repo "$REPO" >/dev/null 2>&1 || \
  gh release create "$RELEASE_TAG" --repo "$REPO" \
    --title "${TITLE} 最新版" \
    --notes "安装页 ${APPBASE}/install.html"
gh release upload "$RELEASE_TAG" "$staged" --clobber --repo "$REPO"

# 描述里写上版本号，从 Releases 页面一眼看得到当前是哪一版
gh release edit "$RELEASE_TAG" --repo "$REPO" --notes \
"- **${TITLE}** \`${ver}${SUFFIX}\` · $(date '+%m-%d %H:%M') — [安装页](${APPBASE}/install${SUFFIX}.html)

安装包每次发版覆盖同名文件，这里永远是最新的一份。
iOS 必须从安装页装（\`itms-services\`），直接下 ipa 装不上。" >/dev/null

cat > "$APPDIR/manifest${SUFFIX}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>items</key>
	<array>
		<dict>
			<key>assets</key>
			<array>
				<dict>
					<key>kind</key>
					<string>software-package</string>
					<key>url</key>
					<string>${RELEASE_BASE}/${APP_NAME}${SUFFIX}.ipa</string>
				</dict>
			</array>
			<key>metadata</key>
			<dict>
				<key>bundle-identifier</key>
				<string>${BUNDLE}</string>
				<key>bundle-version</key>
				<string>${marketing}</string>
				<key>kind</key>
				<string>software</string>
				<key>title</key>
				<string>${TITLE}</string>
			</dict>
		</dict>
	</array>
</dict>
</plist>
EOF

# 安装页整页重新生成（版本号直接嵌入，避免 sed 改旧页的脆弱性）
ITMS="itms-services://?action=download-manifest&amp;url=${APPBASE}/manifest${SUFFIX}.plist"
cat > "$APPDIR/install${SUFFIX}.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>安装 ${TITLE}</title>
<style>
  :root{
    --bg:#F7F4EC; --card:#ffffff; --label:#1A1A1A; --label2:#6B655C;
    --accent:#8A5A2B; --sep:#E4DED2;
  }
  *{ box-sizing:border-box; }
  body{
    margin:0; min-height:100vh; background:var(--bg); color:var(--label);
    font-family:-apple-system,"SF Pro Text",system-ui,"PingFang SC",sans-serif;
    -webkit-font-smoothing:antialiased;
    display:flex; align-items:center; justify-content:center; padding:28px;
  }
  .card{
    width:100%; max-width:420px; background:var(--card); border-radius:22px;
    padding:30px 24px 26px; text-align:center; border:1px solid var(--sep);
    box-shadow:0 20px 50px -24px rgba(0,0,0,.18);
  }
  .icon{
    width:82px; height:82px; border-radius:19px; margin:0 auto 16px;
    background:linear-gradient(160deg,#C97B4A,#8A5A2B);
    display:flex; align-items:center; justify-content:center;
    color:#fff; font-size:34px; font-weight:700; letter-spacing:-1px;
  }
  h1{ font-size:22px; margin:0 0 4px; }
  .ver{ color:var(--label2); font-size:14px; margin-bottom:22px; }
  a.btn{
    display:block; background:var(--accent); color:#fff; text-decoration:none;
    border-radius:14px; padding:15px 0; font-size:17px; font-weight:600;
  }
  .tips{ text-align:left; color:var(--label2); font-size:13px; line-height:1.75;
         margin-top:22px; border-top:1px solid var(--sep); padding-top:16px; }
  .tips b{ color:var(--label); }
</style>
</head>
<body>
<div class="card">
  <div class="icon">${ICON_TEXT}</div>
  <h1>${TITLE}</h1>
  <div class="ver">当前版本 <b>${ver}</b></div>
  <a class="btn" href="${ITMS}">安装</a>
  <div class="tips">
    1. 必须在 <b>Safari</b> 打开本页（微信里点「···」→ 在浏览器打开）<br>
    2. 点「安装」→ 回桌面等待装完<br>
    3. 打不开时：设置 → 通用 → <b>VPN与设备管理</b> → 信任证书；
       或 隐私与安全性 → <b>开发者模式</b> → 开启<br>
    4. 「Unable to Verify」→ 关 VPN 或换蜂窝网络再点图标${EXTRA_TIP}
  </div>
</div>
</body>
</html>
EOF

git -C "$DIST" add -A
if git -C "$DIST" -c user.email="$GIT_EMAIL" -c user.name="$GIT_NAME" \
     commit -q -m "release ${APP_SLUG} ${ver}${SUFFIX}"; then
  # 不能写 `git push && echo ok`：set -e 对 && 列表中非最后一个命令的失败不生效，
  # push 失败会被静默咽掉、脚本继续宣布“已发布”（踩过）。
  #
  # 显式写 origin main，不靠 upstream 配置 —— 那个配置在重建分支后会丢，
  # 表现是「ipa 都传上去了，最后一步报 no upstream branch」。
  if ! git -C "$DIST" push -q origin main; then
    echo ""
    echo "❌ 推送失败！版本【未】发布，线上仍是旧版。到 $DIST 里 git push 补推。"
    exit 1
  fi
else
  echo "  (无改动，跳过提交)"
fi

# push 成功不等于发布成功：一定要回头核对远程真的变了
git -C "$DIST" fetch -q origin
if [ "$(git -C "$DIST" rev-parse HEAD)" != "$(git -C "$DIST" rev-parse origin/main)" ]; then
  echo ""
  echo "❌ 本地与远程不一致，版本【未】完全发布。请到 $DIST 检查。"
  exit 1
fi

echo ""
echo "✅ 版本 ${ver}${SUFFIX} 已发布（远程 HEAD 已核对一致）。约 1 分钟后 Pages 生效。"
echo ""
echo "安装页（Safari 打开）："
echo "    ${APPBASE}/install${SUFFIX}.html"
