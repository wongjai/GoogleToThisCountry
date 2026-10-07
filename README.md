# GoogleToThisCountry (GTTC)

<p align="center">
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License">
  <img src="https://img.shields.io/badge/Shell-Bash-orange?style=for-the-badge&logo=gnu-bash" alt="Bash">
</p>

> ## ⚠️ EXPERIMENTAL: 🇬🇧 United Kingdom (option 6) / 英國（選項 6）為實驗性功能
>
> This repository is a fork of [edmond1294/GoogleToThisCountry](https://github.com/edmond1294/GoogleToThisCountry) whose only functional change is the added **UK option 6** (plus pointing the install command and the script's self-download at this fork, so the UK option is not silently overwritten by upstream).
>
> - **Experimental, no success guarantee.** The UK option sets an ECS (EDNS Client Subnet) prefix for Google-related DNS lookups. ECS only influences which DNS/CDN answers Google DoH returns; it does not guarantee that Google corrects its geolocation of your server's source IP, and a prefix being valid does not mean the redirect will work. Results may be partial or absent.
> - **ECS prefix `81.2.69.0/24`**, checked against the RIPE database on 2026-10-07: it lies inside `inetnum 81.2.64.0 - 81.2.127.255` (netname `UK-AA-20020403`, `country: GB`, route `81.2.64.0/18` originated by AS20712, Andrews & Arnold Ltd), and all 51 more-specific `inetnum` objects inside the /24 are `country: GB`. Reference: <https://rest.db.ripe.net/search.json?query-string=81.2.69.0/24&flags=all-more&flags=no-referenced&flags=no-irt&type-filter=inetnum&source=RIPE>. Google DoH accepted the value in a test query (response scope `81.2.69.0/19`); acceptance is not evidence that Google's geolocation changes.
> - **Xray only.** The script configures Xray (and v2ray-style config paths). It does **not** configure sing-box; a sing-box node is not affected by any option, including 6.
> - **Inherited upstream limitations.** Everything else, including the other regions' ECS values, the keep-alive service and the WARP restriction, is inherited from upstream as-is and has not been independently re-verified by this fork (for example, the upstream text below describes a random 2–5 minute keep-alive interval, while the script currently sleeps a fixed 600 s).
>
> 英國選項為**實驗性功能**：ECS 前綴 `81.2.69.0/24` 已對照 RIPE 資料庫驗證，確實屬於 GB（英國）的位址範圍，但這只代表前綴歸屬正確，**不保證**能修正 Google 的定位。ECS 只影響 Google DoH 回傳的 DNS/CDN 解析結果，**不保證**修正 Google 對伺服器來源 IP 的地理位置判定，也不能因為前綴有效就保證重新導向成功。本腳本只設定 **Xray**，**不會**設定 sing-box；其餘行為與限制均繼承自上游。

**GoogleToThisCountry (GTTC)** 是一款专为 VPS 节点设计的 Google 定位重定向与送中/送台/送日/送美修复工具。通过 **EDNS Client Subnet (ECS) 伪装宣告** 与 **多维保活定时发包** 技术，强行纠正 Google 服务的地理位置识别，将您的 IP 重新送回指定的目标国家或地区。

---

## 🌟 核心特色

- **多地区支持**：一键切换至 🇹🇼 台湾、🇨🇳 中国大陆、🇯🇵 日本、🇲🇴 澳门、🇺🇸 美国、🇬🇧 英國（實驗性，見上方說明）。
- **EDNS 子网宣告**：通过自定义 DNS 客户端子网（ECS），向 Google CDN 宣告特定地区 IP 段，精准获取对应区域的 IP 响应。
- **多维保活机制**：后台轻量化服务，自动模拟移动端 HTTP/204 请求，定期向 Google 核心节点打卡，持续维持地区定位。
- **极轻量无感**：纯 Shell 与 Python 逻辑，不占用额外的网络中转资源，完全不影响原有的 VPS 传输速度与延迟。
- **全平台兼容**：完美支持 Debian / Ubuntu / CentOS / RHEL / Alpine Linux 等主流 Linux 发行版。

---

## 🚀 一键安装与使用

在终端中直接运行以下单行指令即可启动脚本：

```bash
bash <(curl -sSL https://raw.githubusercontent.com/wongjai/GoogleToThisCountry/main/gttc.sh)
```

后续随时在命令行输入：
```bash
gttc
```

即可直接呼出主管理界面！

---

## 🔬 技术原理
### EDNS Client Subnet (ECS)
当脚本启用时，会在 Xray 的 DNS 配置中针对 geosite:google 及相关域名添加特定的 clientSubnet 段（例如台湾 168.95.1.1/24、美国 64.233.160.0/24、英國 81.2.69.0/24［實驗性］）。Google DoH 收到请求后，会将请求分配至对应该子网的最佳 CDN 节点。

### 多维地理位置保活 (Keep-Alive)
脚本会在后台启动 gttc-ping 服务，以随机间隔（2~5 分钟）向 Google 的位置与状态接口（如 generate_204、geolocate）发送带有特定语言标头（Accept-Language）与移动端 UA 的请求，使 Google 持续记录并锁定当前 IP 的地理位置。

## 📖 常见问题 (FAQ)
### Q1: EDNS 宣告与传统 DNS 解锁（SmartDNS/SNI Proxy）有什么区别？
EDNS 宣告：仅在 DNS 查询阶段向 Google 欺骗来源 IP 段，后续建立连接时完全不经过第三方中转服务器，网速与延迟不受任何影响。适合用于修正 Google 搜索定位、YouTube 地区判定等。

传统 DNS 解锁：将特定流量中转至第三方解锁服务器，适合用于对抗检测严格的流媒体（如 Netflix、Disney+ 等）。
