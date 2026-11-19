# 02 · postmarketOS 适配分析

> 数据来源：postmarketOS 官方 Wiki 设备页 `Xiaomi Redmi Note 5A (xiaomi-ugglite)`，采集于 2026-11-19。
> 官方入口：<https://wiki.postmarketos.org/wiki/Xiaomi_Redmi_Note_5A_(xiaomi-ugglite)>

---

## 1. 设备条目概览

| 字段 | 值 |
|---|---|
| 设备 | Xiaomi Redmi Note 5A |
| 代号 | `xiaomi-ugglite` |
| 厂商 | Xiaomi |
| 发布年份 | 2017 |
| SoC | Qualcomm Snapdragon 425 (MSM8917) |
| CPU | 四核 1.4 GHz Cortex-A53 |
| GPU | Adreno 308 |
| 屏幕 | 720×1280 IPS |
| 存储 / 内存 | 8/16 GB / 2 GB |
| 架构 | aarch64 |
| 原厂系统 | Android 7 |

---

## 2. 支持级别与内核

- **支持类别**：`testing`（测试级 —— 可引导、基础功能可用，但仍有若干硬件未适配）
- **Mainline 主线内核**：`yes` ✅
- **内核版本**：`7.1.3`（`linux-postmarketos-qcom-msm89x7`）
- **通用端口**：`Qualcomm MSM89x7 (qcom-msm89x7)` —— 覆盖 MSM8917 / MSM8920 / MSM8937 / MSM8940
- **设备包**：`device-qcom-msm89x7`
- **内核包**：`linux-postmarketos-qcom-msm89x7`
- **维护者**：`barni2000`

> 关键点：虽然设备页标题是 `xiaomi-ugglite`，但**实际构建时应选择通用端口 `vendor=qcom`、`device=msm89x7`**（见官方安装片段）。这也是本设备适配的推荐做法。

---

## 3. 功能支持矩阵

### ✅ 正常可用（Works）

| 类别 | 功能 |
|---|---|
| 基础 | 刷机（flashing）、USB 网络（SSH over USB）、内部存储 eMMC、SD 卡、电池充电与电量显示 |
| 显示 / 输入 | 屏幕（含休眠与亮度）、触摸屏、3D 硬件加速（GPU） |
| 多媒体 | 音频播放（有轻微杂音，见下）、FDE 全盘加密 + unl0kr 解锁 |
| 连接 | Wi-Fi、蓝牙、GPS |
| 通信 | 电话、短信、移动数据（2G/3G/VoLTE 正常，含音频） |
| 传感器 | 加速度传感器、震动（Haptics） |

### ❌ 不可用（Broken）

相机、相机闪光灯、红外发射（IR TX）、USB OTG、环境光传感器、接近传感器、霍尔传感器。

### ⚠️ 部分可用（Partial）

磁力计（指南针）。

---

## 4. 已知问题（对服务器用途的影响评估）

| 已知问题 | 对服务器用途的影响 |
|---|---|
| 音频有静电杂音；PulseAudio 挂起扬声器时有噪声；启动/退出时有异响 | **无影响**（服务器无需音频） |
| GPU 较不稳定，GTK4 采用软件渲染；游戏需强制 OpenGL 2.1/ES 2.0 | **轻微**（无图形界面，不受影响） |
| 相机 / OTG / 接近传感器不可用 | **无影响** |
| 环境光传感器不可用（无法自动亮度） | **无影响**（无头运行） |
| `testing` 类别，非日常主力机级别 | **需注意**：长期运行前做 24h 稳定性测试 |

---

## 5. 关键依赖：lk2nd（强制）

官方 Wiki 明确警告：

> ⚠️ **Flashing lk2nd is required**, as it is a hard dependency. Without it the mainline kernel will not select the display panel (resulting in black screen on boot).

- 需要从 <https://github.com/msm8916-mainline/lk2nd/releases/> 获取 `lk2nd-msm8952.img`
- 在 `boot` 分区刷入：`fastboot flash boot lk2nd-msm8952.img`
- 顺序：先刷 lk2nd，再 `pmbootstrap flasher flash_rootfs`

> 即使作为无头服务器不需要屏幕，**仍需刷 lk2nd** —— 它是该端口内核启动链条的硬依赖，缺失会导致启动失败/黑屏。

---

## 6. 官方安装参考片段

```
$ pmbootstrap init        # Vendor: qcom  Device codename: msm89x7
$ pmbootstrap install
$ fastboot flash boot lk2nd-msm8952.img    # 从 lk2nd releases 获取
$ pmbootstrap flasher flash_rootfs
```

**双系统（保留 Android + pmOS 装到 SD 卡）参考**：

```
$ pmbootstrap init
$ pmbootstrap install --sdcard=/dev/sdcard_goes_here
$ fastboot flash recovery lk2nd-msm8952.img    # lk2nd 刷到 recovery 而非 boot
```

> 本方案默认采用**单机全覆盖**（pmOS 独占 eMMC），理由：服务器需稳定持久化运行，SD 卡 I/O 性能与寿命不佳。若你希望保留 Android 作为救援，可采用上述双系统方案。

---

## 7. 服务器适用性结论

| 服务器核心需求 | 本设备支持 |
|---|---|
| 稳定引导 | ✅（依赖 lk2nd） |
| 网络连接（USB / Wi-Fi） | ✅ 均可用，USB 网络更可靠 |
| 持久化存储 | ✅ eMMC 10GB + SD 卡扩展 |
| 远程管理（SSH） | ✅ 通过 USB 网络或 Wi-Fi |
| 容器 / Docker | ✅ 真正 Linux 内核，cgroups/namespaces 完整（优于 Termux proot） |
| 长期供电 | ⚠️ 电池长期插电需关注（见 `docs/04`） |
| 算力 / 内存 | ⚠️ 骁龙 425 + 2GB RAM，适合轻量服务（Web、代理、自动化、轻量容器） |

**适配结论：适合改造为轻量级 Linux 服务器（家庭自动化、轻量 Web/代理、Git 同步、监控采集等），不适合高算力或大内存负载。**
