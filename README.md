# Debian Security Check

面向 Debian 12（Bookworm）和 Debian 13（Trixie）的安全检查与保守更新脚本。

交互菜单提供一个“小白智能模式”：先检查，只有发现可安装更新且预检通过时才更新；更新成功后自动重启。没有更新时不会修改系统，并自动返回菜单。高级用户仍可用 `--check` / `--fix` 参数执行不会自动重启的检查或更新。

## 先获取脚本

### 一条命令安装并启动（推荐）

本项目使用公开 GitHub 仓库。在 Debian VPS 运行下面这一条命令即可：

```bash
curl -fsSL https://github.com/elonjack/debian-security-check/releases/download/v1.3.0/install.sh | bash
```

安装器会自动：

1. 从最新 GitHub Release 下载正式脚本和 `SHA256SUMS`。
2. 校验脚本 SHA-256；不一致就停止，不会执行。
3. 安装到 `$HOME/debian-security-check/`。
4. 恢复终端输入并打开 `1/0` 中文菜单。

这条命令的引导安装器本身来自公开 Release。安全要求更高时，应使用下一节的手动下载方法，先把文件保存下来检查，再执行。

### 手动下载并校验

仅输入下面这条命令并不能下载脚本：

```bash
sudo bash debian-security-check.sh
```

它只会执行当前目录中已经存在的 `debian-security-check.sh`。必须先从 GitHub Release 下载或上传到 VPS。

### 当前公开仓库：直接在 VPS 下载

本仓库当前是公开仓库，可以直接在 VPS 下载最新版 Release：

```bash
curl -fL -o debian-security-check.sh \
  https://github.com/elonjack/debian-security-check/releases/download/v1.3.0/debian-security-check.sh
curl -fL -o SHA256SUMS \
  https://github.com/elonjack/debian-security-check/releases/download/v1.3.0/SHA256SUMS
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

## 功能

- 检查 Debian 版本、架构和支持状态
- 检查 `bookworm-security` / `trixie-security` 软件源
- 检查待更新软件包和被 hold 的软件包
- 检查 `CVE-2026-98432` 对当前运行内核的影响
- 识别容器、第三方内核、自编译内核和缺失的内核元包
- 检查是否需要重启，以及是否启用了 `unattended-upgrades`
- 如果已安装 `debsecan`，列出已有修复可安装的漏洞包
- 交互模式先检查，有更新才安装，成功后自动重启
- `--fix` 使用不会主动删除软件包的保守更新方式，且不会自动重启

## 小白推荐流程

运行一个命令即可打开中文菜单：

```bash
sudo bash debian-security-check.sh
```

菜单内容：

```text
1) 智能检查并修复（有更新才安装，成功后自动重启）
0) 退出
```

选择 `1` 即可完成“检查 → 必要时更新 → 必要时重启”的流程，不再需要把检查结果发给别人判断，也不用再次选择修复选项。

执行流程如下：

```text
选择 1
   ├─ 先检查 Debian、security 源并刷新 APT 索引
   ├─ 没有可安装更新、无需重启 → 不修改系统，3 秒后自动返回菜单
   ├─ 有可安装更新且预检通过 → 安装更新
   │                              ├─ 安装成功 → 提示 10 秒后自动重启，SSH 会断开
   │                              └─ 安装失败 → 不重启，保留错误信息
   ├─ 新内核已安装但尚未启用 → 提示 10 秒后自动重启
   └─ 系统版本、软件源或 APT 有严重错误 → 不安装、不重启，提示人工处理

服务器重启恢复后 → 再运行脚本并选择 1 复查
```

自动重启前有 10 秒提示时间，可按 `Ctrl+C` 取消本次重启。自动重启会断开当前 SSH，请确认 VPS 有可用备份、快照或带外控制台。

### 第一步：选择智能检查并修复

下载后先检查：

```bash
sudo bash debian-security-check.sh
```

然后选择：

```text
1) 智能检查并修复
```

脚本始终先检查。若没有更新，它不会执行升级，也不会重启；若有更新，只有在系统版本、安全软件源和 APT 索引检查均无严重问题时，才执行 `apt-get -y upgrade --with-new-pkgs`。

智能模式的更新顺序是：

1. 检查 Debian 版本、支持状态和 security 软件源。
2. 执行 `apt-get update`，要求所有软件源成功刷新。
3. 显示 hold 包和待更新数量。
4. 没有待更新包时跳过安装；有更新且预检通过时执行保守升级。
5. 重新检查待更新包、漏洞状态、运行中内核和重启需求。
6. 更新成功或新内核等待启用时自动重启；检查/升级失败时绝不自动重启。

脚本不会自动解除 hold，也不会运行会主动删除包的 `dist-upgrade/full-upgrade`。

修复模式更新的是所有已配置 APT 软件源中的可用包，不仅是 Debian security 仓库；如果系统配置了第三方软件源，对应软件也可能被更新。

### 第二步：重启后复查

服务器恢复后，再运行脚本并选择 `1`：

```bash
sudo bash debian-security-check.sh
```

如果显示当前没有可安装更新，并自动返回菜单，说明本次 APT 更新流程已完成。它仍不能证明所有第三方软件、业务代码或尚无补丁的漏洞都已解决。

## 自动化和批量服务器

菜单适合人工操作。Ansible、定时任务或批量 SSH 不能等待菜单输入，因此仍然保留参数模式；参数模式不会自动重启服务器，但更新软件时仍可能重启部分服务，应先在测试机验证：

```bash
# 直接检查，不显示菜单
sudo bash debian-security-check.sh --check

# 直接预检并安装更新，不显示菜单
sudo bash debian-security-check.sh --fix
```

所以菜单和参数并不冲突：普通用户使用菜单，自动化运维使用参数。

`--check` 只检查；`--fix` 预检并安装更新。两者都不会自动执行 `reboot`，自动重启只属于人工明确选择的交互菜单智能模式。

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
