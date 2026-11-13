# cf-ddns

VPS 公网 IP 变了，自动把 Cloudflare 上的 DNS 记录改成新 IP。适用于甲骨文换 IP、搬瓦工换机房、各类动态 IP 机器。

- **一次覆盖多个域名**：IP 变化时，所有域名中指向旧 IP 的 A/AAAA 记录都会改成新 IP，不用一条条配置。
- **30 秒内生效**：systemd timer 每 30 秒检测一次，开机 15 秒后也会自动检测（没有 systemd 的机器用 cron）。
- **只改 IP**：小云朵（代理开关）、TTL、备注保持不变；指向其他服务器的记录不受影响。
- **IP 没变时不请求 Cloudflare API**；更新失败会在下一轮自动重试。
- 可选 Telegram 通知，支持 IPv6。

## 一键安装

用 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/cf-ddns/main/install.sh)
```

按提示填写 Cloudflare API Token 等信息即可。之后再执行同一条命令，会出现管理菜单：重新配置、更新、检查、查看日志、卸载。

### 非交互安装（批量部署）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wwintj/cf-ddns/main/install.sh) install \
  --token 你的Token --zone example.com --record vps.example.com
```

| 参数 | 说明 |
|---|---|
| `--token` | Cloudflare API Token（必填） |
| `--zone` | 只处理这些域名，空格分隔；不填则处理 Token 能访问的全部域名 |
| `--record` | 强制指向本机的记录，空格分隔，可不填 |
| `--ipv6` | 同时同步 AAAA 记录 |
| `--tg-token` / `--tg-chat` | Telegram 通知 |

其他子命令：`update`、`check`、`log`、`uninstall`

## 创建 API Token

1. 打开 https://dash.cloudflare.com/profile/api-tokens → **Create Token**
2. 选择模板 **Edit zone DNS**
3. Permissions：`Zone - DNS - Edit`，再加一条 `Zone - Zone - Read`
4. Zone Resources：`Include - All zones`（以后新加的域名也会自动覆盖）

> 不要使用 Global API Key。

## 工作原理

```
每 30 秒 → 获取公网 IP（Cloudflare trace / ipify / icanhazip 多源备用）
        → 与 /var/lib/cf-ddns/last_ipv4 比较
        → 没变：退出
        → 变了：遍历所有 Zone，把 content == 旧IP 的记录 PATCH 为新 IP
                （以及 EXTRA_RECORDS 中的记录）
        → 全部成功才保存新 IP，失败则下次重试
```

> ⚠️ 要在 IP 变化**之前**安装，脚本才能记录“旧 IP”。如果 IP 已经变了才安装，执行一次：
> `cf-ddns.sh --old-ip 旧IP`

## 常用命令

```bash
cf-ddns.sh --check          # 检查 Token，列出指向本机的记录
cf-ddns.sh --force          # 强制同步一次
journalctl -u cf-ddns -f    # 实时日志
vi /etc/cf-ddns/cf-ddns.conf  # 修改配置（下次运行自动生效）
```

## 配置项 `/etc/cf-ddns/cf-ddns.conf`

| 变量 | 说明 |
|---|---|
| `CF_API_TOKEN` | API Token |
| `ZONES` | 只处理的域名，留空 = 全部 |
| `EXTRA_RECORDS` | 强制指向本机的记录 |
| `EXCLUDE_RECORDS` | 永远不改的记录 |
| `ENABLE_IPV4` / `ENABLE_IPV6` | 1 开启 / 0 关闭 |
| `TG_BOT_TOKEN` / `TG_CHAT_ID` | Telegram 通知 |

## 依赖

bash、curl、jq（安装脚本会自动安装）。支持 Debian / Ubuntu / CentOS / RHEL / Alpine。

## License

MIT
