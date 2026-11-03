# Debian Security Check

面向 Debian 12（Bookworm）和 Debian 13（Trixie）的安全检查与保守更新脚本。

交互菜单同时提供“一次性智能检查修复”“长期自动安全更新设置”和“旧内核安全清理”。一次性模式先完整检查，只有发现可安装更新且没有安全阻断项时，才先模拟再正式更新；长期模式由用户明确开启后，在指定时间只安装 Debian 官方安全仓库允许的更新，并可选择是否在更新成功且确实需要时自动重启。旧内核清理同样默认关闭，只有三个及以上同系列内核时才可能清理第三个或更旧且安装满30天的内核。高级用户仍可用 `--check` / `--fix` 参数执行不会自动重启的检查或更新。

## 安装与运行

### 一条命令安装并启动（推荐）

在 Debian VPS 或独立服务器上运行：

```bash
curl -fsSL https://github.com/elonjack/debian-security-check/releases/download/v1.5.0/install.sh | bash
```

安装器会自动：

1. 从 `v1.5.0` GitHub Release 下载正式脚本和 `SHA256SUMS`。
2. 校验脚本 SHA-256；不一致就停止，不会执行。
3. 安装到 `$HOME/debian-security-check/`。
4. 恢复终端输入并打开 `1/2/3/0` 中文菜单。

### 手动下载并校验（可选）

希望先查看脚本再执行时：

```bash
curl -fL -o debian-security-check.sh \
  https://github.com/elonjack/debian-security-check/releases/download/v1.5.0/debian-security-check.sh
curl -fL -o SHA256SUMS \
  https://github.com/elonjack/debian-security-check/releases/download/v1.5.0/SHA256SUMS
grep '  debian-security-check.sh$' SHA256SUMS | sha256sum -c -
```

确认输出 `debian-security-check.sh: OK` 后运行：

```bash
sudo bash debian-security-check.sh
```

root 用户也可以去掉 `sudo`。不要把主脚本 `debian-security-check.sh` 直接通过 `curl ... | bash` 执行；推荐的一键命令运行的是固定版本安装器，安装器会先校验主脚本 SHA-256。

## 适用环境

- **KVM、VMware、Hyper-V 等完整虚拟机：支持。** 自动重启只重启当前虚拟机，不会重启宿主机。
- **Debian 独立服务器/物理服务器：支持。** 自动重启会重启整台物理机，SSH 会断开；重要业务机器建议开启自动安全更新但暂不自动重启，并提前确认 IPMI、iDRAC、iLO 或其他带外控制台可用。
- **LXC、OpenVZ、Docker 等容器：仅建议使用检查或人工更新。** 容器共享或受宿主机内核控制，容器内更新不能修复宿主机内核，也不应依赖容器内自动重启。
- **Proxmox、云厂商或自编译内核：只能更新 Debian 用户态软件包。** 内核漏洞必须使用对应内核提供方发布的补丁。

脚本只支持 Debian 12 和 Debian 13。Ubuntu、Debian testing/unstable/sid、混合发行版软件源以及不受支持的架构会被阻止进入智能更新流程。

## 功能

- 检查 Debian 版本、架构和支持状态
- 检查 `bookworm-security` / `trixie-security` 软件源
- 检查待更新软件包和被 hold 的软件包
- 检查 `CVE-2026-98432` 对当前运行内核的影响
- 读取当前内核系列对应的 Debian 元包目标，检查最新已安装官方内核是否真正处于运行状态
- 识别容器、第三方内核、自编译内核和缺失的内核元包
- 检查是否需要重启，以及是否启用了 `unattended-upgrades`
- 如果已安装 `debsecan`，列出已有修复可安装的漏洞包
- 交互模式先完整检查，有更新才模拟并安装，复查确认需要时才自动重启
- 可单独开启长期自动安全更新，并选择“不自动重启”或“更新完整成功后确需重启才自动重启”
- 长期模式清空默认更新来源，只允许 Debian 官方 `Debian-Security` 来源，不自动更新第三方仓库
- 长期模式禁止自动删包、自动降级和关机时升级；有登录用户时不自动重启
- 可选的旧内核清理始终保留当前最新内核和一个最近备用；只清理第三个或更旧且安装满30天的同系列内核
- 旧内核清理先执行 APT 模拟，删除方案出现任何未列入候选的软件包就停止；不会运行宽泛的 `autoremove`
- 禁用/备份的 APT 源不会被误判为有效安全源；混入 testing/sid 时阻止自动更新
- 升级失败、仍有补丁或存在严重问题时绝不自动重启
- `--fix` 使用不会主动删除软件包的保守更新方式，且不会自动重启

## 小白推荐流程

运行一个命令即可打开中文菜单：

```bash
sudo bash "$HOME/debian-security-check/debian-security-check.sh"
```

主菜单内容：

```text
1) 智能检查并修复（有更新才安装，需要时自动重启）
2) 自动安全更新设置（长期生效，默认不会自动开启）
3) 旧内核安全清理（默认关闭，始终保留当前和一个备用）
0) 退出
```

选择 `1` 即可完成本次“检查 → 必要时更新 → 必要时重启”的流程，不再需要把检查结果发给别人判断，也不用再次选择修复选项。选择 `2` 才会进入长期自动更新设置；选择 `3` 管理旧内核清理。两个长期功能都不会自行开启。

执行流程如下：

```text
选择 1
   ├─ 先检查 Debian、security 源并刷新 APT 索引
   ├─ 禁用安全源、混入 testing/sid 或检查失败 → 不安装、不重启
   ├─ 没有可安装更新、无需重启 → 不安装软件包，3 秒后自动返回菜单
   ├─ 有可安装更新且完整检查通过 → 先模拟升级，再安装更新
   │                                  ├─ 安装失败 → 明确禁止重启，保留错误信息
   │                                  └─ 安装成功 → 再完整检查一次
   │                                                     ├─ 仍有补丁/严重问题 → 不重启
   │                                                     ├─ 确实需要重启 → 10 秒后自动重启
   │                                                     └─ 无需重启 → 返回菜单
   ├─ 新内核已安装但尚未启用 → 提示 10 秒后自动重启
   └─ 系统版本、软件源或 APT 有严重错误 → 不安装、不重启，提示人工处理

服务器重启恢复后 → 再运行脚本并选择 1 复查
```

自动重启前有 10 秒提示时间，可按 `Ctrl+C` 取消本次重启。自动重启会断开当前 SSH，请确认 VPS 有可用备份、快照或带外控制台。

### 第一步：选择智能检查并修复

下载后先检查：

```bash
sudo bash "$HOME/debian-security-check/debian-security-check.sh"
```

然后选择：

```text
1) 智能检查并修复
```

脚本始终先完成全部检查。若没有更新且不需要重启，它不会执行升级或重启；若有更新，只有在系统版本、架构、真正启用的安全源、APT 索引、软件包状态和内核检查均无阻断项时，才继续。

智能模式的更新顺序是：

1. 检查 Debian 版本、支持状态和 security 软件源。
2. 执行 `apt-get update`，要求所有软件源成功刷新。
3. 显示 hold 包和待更新数量。
4. 没有待更新包时跳过安装；有更新时先执行 `apt-get -s upgrade --with-new-pkgs` 模拟升级。
5. 模拟通过后才执行正式的保守升级。
6. 更新成功后重新检查安全源、待更新包、漏洞状态，并比较运行中内核与 Debian 内核元包指向的最新内核。
7. 只有复查确认没有剩余补丁、没有严重问题并且确实需要重启时才自动重启；检查或升级失败时绝不自动重启。

脚本不会自动解除 hold，也不会运行会主动删除包的 `dist-upgrade/full-upgrade`。

修复模式更新的是所有已配置 APT 软件源中的可用包，不仅是 Debian security 仓库；如果系统配置了第三方软件源，对应软件也可能被更新。

### 第二步：重启后复查

服务器恢复后，再运行脚本并选择 `1`：

```bash
sudo bash "$HOME/debian-security-check/debian-security-check.sh"
```

重启后复查应同时满足：

```text
没有安全阻断项
当前 APT 索引中没有待更新软件包
运行中内核达到脚本列出的 CVE 修复线
运行中内核就是对应 Debian 内核元包当前指向的最新已安装内核
系统不再要求重启
```

满足这些条件并自动返回菜单，表示“当前已配置 APT 源中，适用于这台机器且已经发布的更新均已安装”。它不等于系统不存在任何漏洞，也不能证明第三方软件、业务代码、容器镜像或尚无补丁的漏洞已经解决。

## 长期自动安全更新

在主菜单选择 `2`：

```text
1) 开启自动安装 Debian 安全更新（不自动重启）
2) 定时安装安全更新（成功后确需重启才自动重启）
3) 查看当前状态
4) 关闭无人值守安装和自动重启
5) 移除本脚本配置（恢复系统原有设置）
0) 返回主菜单
```

建议普通 KVM VPS 选择 `2` 并指定业务低峰时间；重要业务服务器和独立服务器建议先选择 `1`，由管理员安排重启。这里的设置长期生效，与主菜单选项 `1` 的单次检查修复不同。

开启前，脚本会重新检查 Debian 版本、security 软件源以及是否混入 testing/sid，并要求 `apt-get update` 完整成功。随后安装 Debian 的 `unattended-upgrades`，写入独立的 APT 配置、受控执行器和 systemd service/timer，校验 APT 最终有效配置及 systemd 单元后才启用。已有但并非本脚本创建的同名文件不会被覆盖。

本脚本管理的文件为：

```text
/etc/apt/apt.conf.d/99debian-security-check
/usr/local/sbin/debian-security-check-auto-update
/etc/systemd/system/debian-security-check-auto-update.service
/etc/systemd/system/debian-security-check-auto-update.timer
```

长期模式具有以下边界：

- 只允许 Origin/Label 为 Debian 官方安全仓库的更新，不自动安装普通 stable 更新或第三方仓库更新。
- 不自动删除软件包，不自动降级，不在关机过程中升级，也不会自动跨版本升级 Debian。
- Debian 自带的 `Unattended-Upgrade::Automatic-Reboot` 始终保持关闭；重启只由本脚本受控执行器判断。
- 选择自动重启后，也只有索引刷新成功、安全更新命令完整成功，且本次执行新产生 `/run/reboot-required` 或新安装了尚未启用的官方内核时才继续；有登录用户时跳过自动重启。
- 指定时间使用服务器本机时区；为避免多台服务器同时访问镜像并同时重启，每台机器会在指定时间后的 5 分钟随机窗口内开始，安装耗时也不固定，满足全部条件时会在安装结束后重启。
- 定时器不补跑关机期间错过的任务；机器在当天时间窗口内关机，就等下一次计划时间。
- 若因为有用户登录而跳过重启，脚本不会在用户退出后突然补重启；请在维护窗口手动重启或运行主菜单选项 `1`。
- 更新日志位于 `/var/log/unattended-upgrades/`。
- 定时任务及失败原因可用 `journalctl -u debian-security-check-auto-update.service` 查看；主菜单的普通检查也会提示上一次任务是否失败。

选择 `4` 会停用本脚本定时器，并用本脚本配置明确关闭 APT 自带的无人值守安装和自动重启，但保留软件包、管理文件及日志；选择 `5` 只删除本脚本创建的上述四个管理文件，使结果重新由机器上其他 APT 配置决定。两项操作都不会卸载软件或删除已安装更新。

长期模式只处理 Debian Security 来源。仍建议定期运行主菜单选项 `1`，检查普通 stable 更新、被 hold 的包、运行中内核以及自动任务失败记录。

## 旧内核安全清理

在主菜单选择 `3`：

```text
1) 查看可清理的旧内核（只检查，不删除）
2) 立即安全清理一次（仍然遵守30天和保留规则）
3) 开启每周自动检查和清理（周日低峰执行）
4) 关闭每周自动清理
5) 查看每周自动清理状态
0) 返回主菜单
```

此功能默认关闭。选项 `2` 只执行一次；选项 `3` 由用户主动开启后，每周日服务器本地时间 `04:15` 后的30分钟随机窗口检查一次。每周执行的是安全检查，不代表每周一定会删除内核。

候选内核必须同时满足以下条件：

- 机器是 Debian 12/13 的完整虚拟机或物理机，不是 LXC、OpenVZ、Docker 等容器。
- 当前运行内核属于 Debian 官方包，并且已经是对应内核元包指向的最新内核；如果新内核已安装但尚未重启，整个清理流程停止。
- 只统计当前内核元包对应的同系列内核；普通 `amd64`、`cloud-amd64`、RT 等系列不会混在一起计数或删除。
- 同系列至少存在三个内核。
- 当前运行的最新内核始终保留，版本最高的另一个内核作为备用始终保留。
- 只有第三个或更旧的内核，并且 Debian `dpkg` 记录的包文件最后变更时间至少已满30天，才列为候选；时间无法确认时保留。
- `dpkg --audit`、`apt-get check` 必须通过，不能有 hold 包，APT 也不能正被其他任务占用。

真正删除前，脚本会执行 `apt-get -s purge` 模拟。模拟结果只要包含候选列表以外的软件包，或计划安装其他软件包，就立即停止。正式操作只 purge 已列出的版本化 `linux-image-*` 旧内核包，不运行 `apt autoremove`，不删除内核元包、当前内核、备用内核或其他软件包。与旧内核配套但独立安装的旧 headers 可能继续保留，这是为了避免宽泛自动删除。

每周任务由以下受管文件组成：

```text
/usr/local/sbin/debian-security-check-kernel-cleanup
/etc/systemd/system/debian-security-check-kernel-cleanup.service
/etc/systemd/system/debian-security-check-kernel-cleanup.timer
```

选择 `4` 会停止定时器并移除这三个受管文件，但不会删除任何内核。自动任务日志可用下面的命令查看：

```bash
journalctl -u debian-security-check-kernel-cleanup.service
```

## 自动化和批量服务器

菜单适合人工操作。Ansible、定时任务或批量 SSH 不能等待菜单输入，因此仍然保留参数模式；参数模式不会自动重启服务器，但更新软件时仍可能重启部分服务，应先在测试机验证：

```bash
# 直接检查，不显示菜单
sudo bash "$HOME/debian-security-check/debian-security-check.sh" --check

# 直接预检并安装更新，不显示菜单
sudo bash "$HOME/debian-security-check/debian-security-check.sh" --fix
```

所以菜单和参数并不冲突：普通用户使用菜单，自动化运维使用参数。

`--check` 只检查；`--fix` 预检并安装更新。两者本次执行都不会自动调用 `reboot`。交互菜单选项 `1` 的一次性智能模式，以及用户主动开启的长期定时重启策略，是两套独立机制。

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
sudo apt-get install debsecan debian-security-support needrestart
```

`unattended-upgrades` 可直接从脚本主菜单选项 `2` 安装和安全配置，不需要另行执行 `dpkg-reconfigure`。

## `CVE-2026-98432`

脚本按照 Debian Security Tracker 公布的修复线检查当前正在运行的内核：

- Debian 13：`linux` 6.12.113-1 或更高
- Debian 12 默认 6.1 内核：`linux` 6.1.190-1 或更高
- Debian 12 的 6.12 内核：`linux-6.12` 6.12.113-1~deb12u1 或更高

参考：[Debian Security Tracker: CVE-2026-98432](https://security-tracker.debian.org/tracker/CVE-2026-98432)

这项 CVE 检查只是额外的已知漏洞核对，不再作为判断内核是否最新的唯一依据。即使当前内核已经越过该修复线，只要同系列 Debian 内核元包已经指向并安装了更新内核，脚本仍会要求重启启用新内核；因此以后出现新内核时不需要等待脚本再硬编码另一个 CVE 编号。

## 退出码

- `0`：未发现需要立即处理的问题
- `1`：存在警告、待更新软件包或待重启状态
- `2`：存在严重问题，或关键检查失败

## 安全建议

先在一台同类型测试机或低风险服务器运行，再按业务批次部署。生产服务器更新内核前，应确认存在可用快照、备份和带外控制台。
