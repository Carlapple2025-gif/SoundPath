# 正式发版：Developer ID 签名 + 公证

`bash build.sh` 默认出的是 **ad-hoc 签名**的 App，只在本机可用；别人从网上下载会被 Gatekeeper 拦下。
要分发给其他人，需要 Apple Developer Program 的 **Developer ID Application** 证书，并把 App **公证（notarize）**。

`release.sh` 把这些步骤串好了：通用二进制（arm64 + x86_64）→ 签名 → 公证 → 装订票据 → 可选上传。

## 一、一次性准备

### 1. 加入 Apple Developer Program

- 入口：<https://developer.apple.com/programs/enroll/>
- 个人：**US$99/年**（中国区 ¥688/年，以官网为准）；组织需要 D-U-N-S 编号
- 个人账号的 Seller Name 会显示证件真名；公司与个人按实际身份选
- Apple ID 需开启双重认证；个人报名要验证身份证件
- 审核通常 **1–2 个工作日**（偶尔更久），通过后 `developer.apple.com` 的 Certificates / App Store Connect 全部解锁

> 免费 Apple ID 只能在 Xcode 里做本地开发签名（Apple Development），**不能**创建 Developer ID、不能公证。

### 2. 创建 Developer ID Application 证书

1. 「钥匙串访问」→ 菜单「证书助理」→「从证书颁发机构请求证书…」→ 存到磁盘（得到 `.certSigningRequest`）
2. 打开 <https://developer.apple.com/account/resources/certificates/list> → **+** → 选 **Developer ID Application** → 上传 CSR
3. 下载 `.cer`，双击装进「登录」钥匙串
4. 验证：

   ```bash
   security find-identity -v -p codesigning
   # 1) XXXX "Developer ID Application: 你的名字 (TEAMID)"
   ```

   也可以在 Xcode → Settings → Accounts → Manage Certificates → **+** → Developer ID Application。

5. 备份：在钥匙串里选中证书+私钥，导出 `.p12`（给 CI 用；私钥丢失只能吊销重签）。

### 3. 公证凭据

- **Team ID**：<https://developer.apple.com/account> → Membership details
- **App 专用密码**：<https://appleid.apple.com> → 登录与安全 → App 专用密码（形如 `abcd-efgh-ijkl-mnop`）

存进钥匙串，`release.sh` 会自动读：

```bash
xcrun notarytool store-credentials soundpath-notary \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "abcd-efgh-ijkl-mnop"
```

之后发版用 `SOUNDPATH_NOTARY_PROFILE=soundpath-notary bash release.sh`。
临时也可以直接给环境变量：`APPLE_ID` / `APPLE_TEAM_ID` / `APPLE_APP_PASSWORD`。

> 公证需要**完整 Xcode**（`xcrun notarytool`、`xcrun stapler`），只装 Command Line Tools 不够。

## 二、每次发版

1. 改版本号与日志：
   - `Resources/Info.plist`：`CFBundleShortVersionString`（如 `1.1.0`）与 `CFBundleVersion`（递增整数）
   - `CHANGELOG.md` 增加对应条目
2. 提交并打 tag（tag 保护规则已生效，`v*` 不能被删/移动）：

   ```bash
   git add -A && git commit -m "v1.1.0: ..."
   git tag -a v1.1.0 -m "声路 1.1.0"
   git push origin main --tags
   ```

3. 构建 + 签名 + 公证 + 装订：

   ```bash
   SOUNDPATH_NOTARY_PROFILE=soundpath-notary bash release.sh
   ```

   产物：`dist/SoundPath-1.1.0-universal.zip`（arm64 + x86_64）。

4. 本机验收（脚本已经跑过，可复查）：

   ```bash
   spctl -a -vvv -t exec dist/声路.app     # accepted / source=Notarized Developer ID
   xcrun stapler validate dist/声路.app
   ```

5. 建 Release 并上传：

   ```bash
   gh release create v1.1.0 --title "声路 1.1.0" --notes "…"
   bash release.sh --upload      # 重新构建/公证后上传
   # 或对已有 zip：gh release upload v1.1.0 dist/SoundPath-1.1.0-universal.zip
   ```

## 三、常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| `spctl` 拒绝 | 未公证、未 staple、不是 Developer ID 签名，或 zip 是装订前打的。`release.sh` 会在装订后重新打包 |
| 下载后仍提示「无法验证开发者」 | 同上；确认附件是 `release.sh` 重新生成的 zip |
| 公证 `Invalid` | `xcrun notarytool log <id> --keychain-profile soundpath-notary` 看具体问题（常见：缺 hardened runtime、嵌套签名不对） |
| 本机没有证书 | `security find-identity -v -p codesigning` 应为 0 条以外至少 1 条 Developer ID |
| 首次接管没权限 | 公证 ≠ 免 TCC；仍要在系统设置里允许「屏幕与系统音频录制」 |
| 为什么不上 App Store | 系统音频捕获类工具审核风险高；Developer ID 直接分发更稳，也保留全部功能 |

## 四、CI 自动发版（可选）

证书到位后，可把下面这些加到仓库 Secrets，由 tag 触发的 workflow 调 `release.sh`：

- `MACOS_CERT_P12`：`.p12` 的 base64（`base64 -i cert.p12 | pbcopy`）
- `MACOS_CERT_PASSWORD`：`.p12` 密码
- `KEYCHAIN_PASSWORD`：CI 临时钥匙串密码（任意）
- `APPLE_ID`、`APPLE_APP_PASSWORD`、`APPLE_TEAM_ID`

流程：导入证书到临时 keychain → `bash release.sh` → `gh release upload`。需要时再加 workflow。
