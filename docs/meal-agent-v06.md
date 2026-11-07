# 0.6 饮食 Agent：部署与使用

2026-11-03。原 App 标识、健康读取和本地记录目录不变。

## 使用

吃饭 → 记录一餐 → 添加照片或填写食物、实际吃下的份量 → 同意本次上传 → 分析照片与描述。照片和文字中不放病历、用药或其他人的个人信息。

结果展示食物、份量范围、来源、待确认问题及能量/蛋白质/碳水/脂肪估计。补充说明后可重新分析；修改餐食内容会使旧结果失效。核对后将估计填入表单，最终点「确认吃过并保存」。当日汇总仅使用已保存记录。没有数据的营养素仍为未知。

「我的 → 饮食 Agent 连接 → 检查服务配置」仅检查服务配置，不会调用模型或上传健康记录。当前 iPhone 已通过 USB 写入专用配对配置；首次进入连接页面/饮食分析区时移入设备钥匙串并删除临时文件。手机连接令牌不等于 DeepSeek API Key。

## 已实测

- 核心规则 124 项、保存/恢复 49 项、本地服务端 30 项检查通过。
- DeepSeek 官方 API 文本、合成营养标签两次真实调用通过。
- 部署后使用同一 Swift MealAgentTransport / URLSession 请求公网 HTTPS：图片识别、响应校验、150 克换算及需确认标记通过。测试不是用户真实餐食。
- 公网健康检查 200，未授权分析请求 401；IP 证书受信任，续期 dry-run 与 nginx reload hook 成功。
- JPEG 重编码的合成 GPS 测试通过；结果卡片在 390 点宽的独立 SwiftUI 渲染中检查。
- iOS 0.6.0 / build 11 编译、签名、覆盖安装通过。安装不代表手机点击流程已验收；具体状态见 validation-status.json。

## 服务运行

地址为 `https://39.96.23.222`，没有购买域名。主机目录 `/opt/mateo-fit-agent`；systemd 服务 `mateo-fit-agent.service`，专用低权限用户 `mateofit`，只监听回环地址 8787。nginx 提供 HTTPS，80 端口仅响应 ACME 验证路径，其他路径 404。

模型为 DeepSeek 官方 `deepseek-flash`。服务端只接受餐食图片/文字，不接收 App 的睡眠、用药、体重记录。模型识别食物和份量，服务器用 31 条 USDA SR Legacy 通用食品条目或待核对的标签值计算。目录不足、隐藏配料/份量不明时返回问题，不能将不完整分项当成整餐总量。照片估重不是精密测量，区间不是统计置信区间。

服务器不持久化餐食内容，不输出请求体或密钥到日志。SQLite `/var/lib/mateo-fit-agent/limits.sqlite3` 仅保存分钟/日期计数；每分钟最多 10 次、每天最多 100 次，最多 2 个模型请求同时处理，不自动重试。每日次数上限不是金额硬上限，供应商费用以账单为准。

API Key 与客户端令牌由 systemd LoadCredential 从 `/etc/mateo-fit-agent/` 的 root 0600 文件注入。令牌不在 App 二进制、源码和备份里。轮换时先更新专用凭据，再重启服务并重新配对手机；不要将值写到 shell 参数或日志。

证书使用 Let's Encrypt shortlived IP profile。`mateo-fit-cert-renew.timer` 每 6 小时检查；成功续期后 nginx 校验并重载。当前签发证书到期 2026-11-09 19:02:11 UTC，正常运行依赖续期任务和 80 端口 ACME 可达。SSH 经本 Mac 的普通代理路径会提前断开，已验证通过 Wi-Fi 接口连接可用；不要改变整个系统的代理配置。

生产依赖快照见 `Server/requirements-production.lock`。服务器使用 Python venv + systemd；Docker/Compose 只是备选配置，未部署。该实例的旧 eatbot 在本次只读检查时已不存在，本次未删除其代码或服务。

## 数据与删除

本 App 删除记录只删除本地记录/照片；不撤销已经发送的请求，也不保证删除模型服务商的副本。DeepSeek 公布的政策未提供这里可依赖的固定 API 零留存保证；保留和删除依其政策，个人数据权利请求可按官方政策联系 privacy@deepseek.com。没有为用户发送任何此类邮件。

- [DeepSeek 隐私政策](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html)
- [DeepSeek 图片输入](https://api-docs.deepseek.com/guides/vision/)
- [Let's Encrypt IP 证书与 Certbot](https://letsencrypt.org/2026/03/11/shorter-certs-certbot)
- [USDA 数据集下载](https://fdc.nal.usda.gov/download-datasets/)

这版实现单餐识别与日记汇总，不自动诊断营养缺乏、开补剂、制定精确热量缺口或替换训练计划。独立 Watch App 和长期签名分发不在此更新内。
