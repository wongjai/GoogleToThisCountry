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
> - **IPv6 ECS prefix `2001:8b0::/32`** (dual-stack / IPv6-only hosts), checked against RIPE on 2026-10-08: it lies inside `inet6num 2001:8b0::/29` (netname `UK-AA-20020820`, `country: GB`), originated by AS20712 (Andrews & Arnold Ltd). The same caveats apply: a valid GB prefix does not guarantee that Google changes its geolocation of your server. Evidence: `logs/ecs-v6-verification-20261008.log`.
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

<!-- dual-stack:begin -->
## 🌐 網路堆疊自動適應（僅 IPv4 / 僅 IPv6 / 雙堆疊）

腳本會在執行時自動偵測主機實際可用的網路堆疊，並依結果調整 DNS 設定與保活行為，不需要手動選擇。

### 偵測方式

分別以 IPv4 與 IPv6 向公開服務（`api.ipify.org` / `api6.ipify.org`，備援 `ifconfig.me`）查詢出口位址；哪一個協定族取得有效位址，即視為可用。

| 偵測結果 | Xray DNS 設定 | 保活服務（`gttc_ping.sh`） |
|---|---|---|
| 僅 IPv4 | IPv4 DoH 與 IPv4 ECS 前綴；備援解析器 `https://1.1.1.1/dns-query`、`8.8.8.8`（與原行為相同） | 僅經由 IPv4 發包 |
| 僅 IPv6 | IPv6 DoH 位址與 IPv6 ECS 前綴；備援解析器 `https://[2606:4700:4700::1111]/dns-query`、`2001:4860:4860::8888`，**完全不寫入** IPv4 的 1.1.1.1 / 8.8.8.8，避免 IPv6 單堆疊主機因無法連線 IPv4 解析器而造成 DNS 卡死 | 僅經由 IPv6 發包 |
| 雙堆疊 | 每個國家 / 地區寫入兩筆伺服器（IPv4 ECS 在前、IPv6 ECS 在後），備援解析器同時包含兩個協定族 | IPv4 與 IPv6 各發一輪 |
| 未能偵測 | 沿用 IPv4 設定並顯示提示 | 不指定協定族，由 curl 自行選擇 |

- 保活服務每一輪都會重新偵測，因此主機的 IPv4 / IPv6 連線狀態改變後會自動跟進；指令碼中不再寫死 `curl -s4`。
- 「關閉重新導向模式」同樣依偵測結果還原解析器，不會把 IPv4 解析器寫回僅 IPv6 的主機。
- WARP 偵測涵蓋兩個協定族：IPv4 出口 `104.28.x.x`，以及 IPv6 出口 `2a09:bac0::/29`（Cloudflare 持有）；任一協定族命中即停止執行。此為位址範圍比對，與原有 IPv4 偵測的性質相同。

### 各地區 ECS 前綴與 DoH

| 地區 | IPv4 ECS | IPv6 ECS | DoH（IPv4 / 雙堆疊） | DoH（僅 IPv6） |
|---|---|---|---|---|
| 🇹🇼 台灣 | `168.95.1.1/24` | `2403:a7c0::/32` | `dns.google` | `[2001:4860:4860::8888]` |
| 🇨🇳 中國大陸 | `114.240.0.0/16` | `240e::/32` | `dns.alidns.com` | `[2400:3200::1]` |
| 🇯🇵 日本 | `133.242.0.0/16` | `2001:7fa:7::/48` | `dns.google` | `[2001:4860:4860::8888]` |
| 🇲🇴 澳門 | `202.175.3.3/24` | `2402:e940:20::/43` | `dns.google` | `[2001:4860:4860::8888]` |
| 🇺🇸 美國 | `64.233.160.0/24` | `2600:8000::/24` | `dns.google` | `[2001:4860:4860::8888]` |
| 🇬🇧 英國（實驗性） | `81.2.69.0/24` | `2001:8b0::/32` | `dns.google` | `[2001:4860:4860::8888]` |

IPv6 前綴已於 2026-10-08 對照各區域網路註冊機構（RIR）資料驗證，紀錄見 `logs/ecs-v6-verification-20261008.log`：

- 台灣 `2403:a7c0::/32`：APNIC，國別 TW。
- 中國大陸 `240e::/32`：位於 APNIC 的 `240e::/18`（China Telecom），國別 CN。
- 日本 `2001:7fa:7::/48`：APNIC（JPNAP），國別 JP。
- 澳門 `2402:e940:20::/43`：位於 APNIC 的 `2402:e940::/32`，國別 MO。
- 英國 `2001:8b0::/32`：位於 RIPE 的 `2001:8b0::/29`，國別 GB，AS20712。
- 美國 `2600:8000::/24`：ARIN 登記為美國退伍軍人事務部（U.S. Department of Veterans Affairs）的區塊，目前未在 BGP 公告；地理資料庫（RIPEstat / MaxMind）標示為 US。它並非 Google 持有的位址，僅作為「美國」的 ECS 前綴使用。

### 限制與注意事項

- 以上僅說明前綴歸屬與設定寫入；與 IPv4 一樣，**不保證**能修正 Google 對來源 IP 的定位。Xray v26 以上版本會忽略 `clientSubnet`（改用 `clientIp`），詳見下方實測說明。
- 本功能的自動化測試在沙盒中以「離線 curl 替身」模擬三種堆疊，未在真實的僅 IPv6 主機上實機驗證。
- 僅 IPv6 主機的「一鍵安裝 / 修復」仍需從 `github.com` 下載 Xray；該網域目前沒有 IPv6 位址，需要主機具備 NAT64 / DNS64 或事先自行安裝 Xray。
<!-- dual-stack:end -->

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
脚本会在后台启动 gttc-ping 服务，定期向 Google 的位置与状态接口（如 generate_204、geolocate）发送带有特定语言标头（Accept-Language）与移动端 UA 的请求，使 Google 持续记录并锁定当前 IP 的地理位置。（注意：上游文档曾述为「随机间隔 2~5 分钟」，实际代码实现为固定的 10 分钟循环 `sleep 600`）。

---

## 🧪 真实环境实测与验证（UK 部署）

在真实英國 VPS 环境（panstar-uk, AS3257, IP: `86.53.183.137`）的实测中，获得了如下实证观察：

1. **HTTP 保活机制有效**：经过约 10–14 小时持续运行后台保活脚本（`gttc-ping`，携带 `Accept-Language: en-GB,en;q=0.9` 及 Android 移动端 User-Agent），Google 成功将其位置分类重新校准回 GBR / en-GB（Google.co.uk 页脚识别生效）。实测证实 HTTP keep-alive 打卡机制在实际纠正与校准 Google IP 定位方面是行之有效的。
2. **校准的关键驱动因素**：观察表明，本次定位校准主要由持续的 HTTP 遥测与 check-in keepalive 请求驱动，而非单纯依赖 DNS ECS 伪装宣告。特别是在 Xray v26+ 版本中，DNS 配置已忽略 `clientSubnet` 并改用 `clientIp`，且测试期间 Xray 并未拦截线上代理流量。
3. **轮询间隔说明**：上游文档提及的随机 2–5 分钟发包与实际实现存在差异，代码实际以固定 10 分钟（`sleep 600`）周期循环。实测表明 10 分钟周期的持续打卡已足够触发 Google 定位数据库的重新校准。

## 📖 常见问题 (FAQ)
### Q1: EDNS 宣告与传统 DNS 解锁（SmartDNS/SNI Proxy）有什么区别？
EDNS 宣告：仅在 DNS 查询阶段向 Google 欺骗来源 IP 段，后续建立连接时完全不经过第三方中转服务器，网速与延迟不受任何影响。适合用于修正 Google 搜索定位、YouTube 地区判定等。

传统 DNS 解锁：将特定流量中转至第三方解锁服务器，适合用于对抗检测严格的流媒体（如 Netflix、Disney+ 等）。
