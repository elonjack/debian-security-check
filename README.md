# Debian Security Check

面向 Debian 12（Bookworm）和 Debian 13（Trixie）的安全检查与保守更新脚本。

脚本默认只刷新 APT 软件包索引并检查系统，不安装或删除软件。`--fix` 模式会先进行预检，只有在系统版本、安全软件源和 APT 索引均无严重问题时，才安装仓库中已经提供的更新。

## 先获取脚本

仅输入下面这条命令并不能下载脚本：

```bash
sudo bash debian-security-check.sh
```

它只会执行当前目录中已经存在的 `debian-security-check.sh`。必须先从 GitHub Release 下载或上传到 VPS。

### 当前公开仓库：直接在 VPS 下载

本仓库当前是公开仓库，可以直接在 VPS 下载最新版 Release：

```bash
curl -fL -o debian-security-check.sh \
  https://github.com/elonjack/debian-security-check/releases/latest/download/debian-security-check.sh
curl -fL -o SHA256SUMS \
  https://github.com/elonjack/debian-security-check/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS
```

确认输出 `debian-security-check.sh: OK` 后再运行。使用 root 登录 VPS 时：

```bash
bash debian-security-check.sh
```

使用具有 sudo 权限的普通用户时：

```bash
sudo bash debian-security-check.sh
```

不要使用未经校验的 `curl ... | bash`，因为这样会把网络返回内容直接交给 root 执行，也不方便先阅读脚本。

### 以后改回私有仓库

改回私有仓库后，未登录 GitHub 的 VPS 使用上述 `curl` 会返回 `404`。届时可以在已经登录 GitHub CLI 的电脑下载：

```bash
gh release download v1.2.1 \
  --repo elonjack/debian-security-check \
  --pattern debian-security-check.sh \
  --pattern SHA256SUMS
```

然后上传到 VPS：

```bash
scp debian-security-check.sh SHA256SUMS root@你的VPS地址:/root/
```

## 功能

- 检查 Debian 版本、架构和支持状态
- 检查 `bookworm-security` / `trixie-security` 软件源
- 检查待更新软件包和被 hold 的软件包
- 检查 `CVE-2026-98432` 对当前运行内核的影响
- 识别容器、第三方内核、自编译内核和缺失的内核元包
- 检查是否需要重启，以及是否启用了 `unattended-upgrades`
- 如果已安装 `debsecan`，列出已有修复可安装的漏洞包
- `--fix` 使用不会主动删除软件包的保守更新方式

## 小白推荐流程

运行一个命令即可打开中文菜单：

```bash
sudo bash debian-security-check.sh
```

菜单内容：

```text
1) 普通检查（推荐先选，不安装更新）
2) 检查并修复（安装所有已配置 APT 源的可用更新）
0) 退出
```

第一次使用始终先选择 `1`。只有检查结果明确建议修复时，才重新运行脚本并选择 `2`。

不要一上来就运行修复模式。正确顺序如下：

```text
普通检查
   ├─ 检查通过、没有可安装更新 → 到此结束，不需要 --fix
   ├─ 提示可以通过 Debian 更新修复 → 运行 --fix
   │                                  ├─ 提示需要重启 → 重启
   │                                  └─ 不需要重启 → 修复结束
   └─ 软件源/系统版本等严重错误 → 先人工处理，不要盲目运行 --fix

修复或重启完成后 → 再运行一次普通检查确认
```

脚本最后会显示“下一步”，直接告诉你现在应该停止、运行 `--fix`、重启，还是先人工处理严重问题。

### 第一步：始终先检查

下载后先检查：

```bash
sudo bash debian-security-check.sh
```

然后选择：

```text
1) 普通检查
```

如果最后明确显示“当前无需运行 `--fix`”，说明没有发现可以通过更新修复的问题，到这里就结束了。

### 第二步：只有检查建议时才修复

只有普通检查明确建议修复时，才再次运行：

```bash
sudo bash debian-security-check.sh
```

然后选择：

```text
2) 检查并修复
```

`--fix` 的执行顺序是：

1. 检查 Debian 版本、支持状态和 security 软件源。
2. 执行 `apt-get update`，要求所有软件源成功刷新。
3. 显示修复前的 hold 包和待更新数量。
4. 仅在预检没有严重问题时执行 `apt-get -y upgrade --with-new-pkgs`。
5. 重新检查待更新包、漏洞状态、运行中内核和重启需求。

脚本不会自动解除 hold、不会运行会主动删除包的 `dist-upgrade/full-upgrade`，也不会自动重启服务器。

修复模式更新的是所有已配置 APT 软件源中的可用包，不仅是 Debian security 仓库；如果系统配置了第三方软件源，对应软件也可能被更新。

### 第三步：根据修复结果决定是否重启

如果脚本提示需要重启：

```bash
sudo reboot
```

服务器恢复后，再运行脚本并选择 `1` 普通检查：

```bash
sudo bash debian-security-check.sh
```

如果普通检查说明无需运行 `--fix`，流程才算完成。

## 自动化和批量服务器

菜单适合人工操作。Ansible、定时任务或批量 SSH 不能等待菜单输入，因此仍然保留参数模式；但修复会更新软件并可能重启服务，应先在测试机验证：

```bash
# 直接检查，不显示菜单
sudo bash debian-security-check.sh --check

# 直接预检并安装更新，不显示菜单
sudo bash debian-security-check.sh --fix
```

所以菜单和参数并不冲突：普通用户使用菜单，自动化运维使用参数。

离线检查（结果可能不是最新）：

```bash
bash debian-security-check.sh --no-refresh
```

为了防止使用过期索引，`--fix` 不能和 `--no-refresh` 同时使用。

## 这是否算“打补丁”

算。Debian 通常把安全修复回移植到稳定版软件包中。安装 Debian security 仓库提供的新软件包，就是应用 Debian 官方安全补丁，不要求软件主版本发生变化。

但是，脚本不能保证修复“所有最新漏洞”：

- Debian 尚未发布修复的软件漏洞，只能报告或等待上游补丁。
- 第三方仓库、手工安装的软件、容器镜像和业务代码不一定由 APT 覆盖。
- Proxmox、云厂商或自编译内核必须使用对应提供方的补丁。
- 内核更新安装后必须重启；容器内更新不能替代宿主机内核更新。
- 被 hold、依赖冲突或需要删除旧包才能升级的软件会被保留，脚本会在最终结果中提示。
- 补丁不会证明机器过去没有被入侵；发现入侵迹象时应隔离、保留证据并从可信镜像重建。

建议额外安装 Debian 官方扫描工具：

```bash
sudo apt-get install debsecan debian-security-support needrestart unattended-upgrades
```

## `CVE-2026-98432`

脚本按照 Debian Security Tracker 公布的修复线检查当前正在运行的内核：

- Debian 13：`linux` 6.12.113-1 或更高
- Debian 12 默认 6.1 内核：`linux` 6.1.190-1 或更高
- Debian 12 的 6.12 内核：`linux-6.12` 6.12.113-1~deb12u1 或更高

参考：[Debian Security Tracker: CVE-2026-98432](https://security-tracker.debian.org/tracker/CVE-2026-98432)

## 退出码

- `0`：未发现需要立即处理的问题
- `1`：存在警告、待更新软件包或待重启状态
- `2`：存在严重问题，或关键检查失败

## 安全建议

先在一台同类型测试机或低风险服务器运行，再按业务批次部署。生产服务器更新内核前，应确认存在可用快照、备份和带外控制台。
