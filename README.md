# Mateo Fit

个人自用的原生 iPhone 健身 Agent，以简洁聊天完成训练建议、饮食分析、记录和复盘。当前 App 版本为 **0.11.1（22）**，服务端包含 2026-11-05 的取消调用次数配额更新。

## 当前能力

- 聊天、历史会话、模型与思考模式切换、联网搜索及 Deep Research。
- 本地跨会话记忆，可查看、修改、忘记和撤销；健康摘要与记忆摘要分别授权。
- 训练和餐食在聊天中提出操作，确认后原子保存；保留草稿、版本与幂等回执。
- HealthKit 体重、睡眠、活动与训练读取，以及本地统计、计划和备份。
- 已提交任务由服务端继续执行，回到 App 后取回进度或结果。原生完成推送尚未接入。
- 应用自有的每日请求数、每日供应商调用数、每分钟请求数配额均关闭。保留用量统计、鉴权、超时、取消、幂等与并发控制。

模型只生成建议和操作提案，不直接写入正式记录。未知数据保持未知，未确认餐食不进入每日合计。离线时可使用已有本地记录、计划和记忆管理。

## 工程结构

| 路径 | 内容 |
| --- | --- |
| `Sources/FitnessApp` | SwiftUI 界面、本地原子 JSON 存储、HealthKit 和远程任务协调 |
| `Sources/FitnessCore` | 数据类型、确定性统计、训练和营养规则、协议与校验 |
| `Sources/CoreChecks` | 核心行为检查 |
| `Server` | Python 服务端、供应商适配、检索、后台任务及测试 |
| `AgentResources` | 教练规则、JSON Schema 和第三方许可 |
| `scripts` | 构建与隔离测试脚本 |
| `Config`、`project.yml`、`XuXu.xcodeproj` | iOS 配置、XcodeGen 工程及共享 Scheme |

## 本地验证

Swift 检查需要 macOS 与相应 Swift 工具链。以下命令使用测试数据，不需要读取手机健康记录或调用模型：

```sh
swift run CoreChecks
bash scripts/check-store.sh
bash scripts/check-chat-interactions.sh
bash scripts/check-background.sh
bash scripts/check-composer-events.sh

python3 -m venv .venv
.venv/bin/python -m pip install -r Server/requirements-production.lock
.venv/bin/python -m unittest discover -s Server -v
```

`scripts/*-live.swift` 为真实 API 检查，需要另行配置服务地址和凭据；不属于上述离线检查。

## 构建

```sh
# macOS 本地试用版
bash scripts/build-mac.sh

# iPhone：先在 Xcode 中登录开发者账号，并核对签名团队
bash scripts/build-ios.sh

# 可选：构建后覆盖安装到已连接、解锁且受信任的手机
XUXU_DEVICE_ID="你的设备 ID" bash scripts/build-ios.sh
```

iOS 最低部署版本为 17.0，macOS 为 14.0。工程保留现有 App 标识 `com.personal.xuxu.app`，避免升级改变本地记录归属。换一台 Mac 时需要配置自己的签名团队；仓库不包含签名证书、描述文件或供应商密钥。

## 服务端

生产入口为 `Server/service.py`，依赖见 `Server/requirements-production.lock`。`Server/mateo-fit-agent.service`、`Server/compose.yaml` 和 Nginx 模板提供部署配置；部署需单独配置 HTTPS、客户端鉴权令牌及供应商密钥。凭据通过环境或凭据文件注入，不能写入源码、Git 或 App。

下列配置的默认值与部署模板均为 `-1`，表示不设置应用自有次数配额；除非用户明确要求，后续升级不要重新启用：

```text
XUXU_MAX_DAILY_REQUESTS=-1
XUXU_MAX_DAILY_PROVIDER_CALLS=-1
XUXU_MAX_MINUTE_REQUESTS=-1
```

后台任务采用加密暂存与过期清理，服务端不保存长期个人记忆库。健康原始记录默认留在设备上，只有已授权的必要摘要或选定照片会进入模型请求。

## 验证与仓库范围

首次导入前的历史交付记录：0.11.1 已完成构建与真机安装，用户确认发送立即清空、后续草稿保留，后台任务可恢复；取消次数配额更新的 124 项服务端检查通过。这些是对应交付时的证据，不代表每次克隆后均重新执行，也不代表 HealthKit 后台送达或完整健康效果已验收。

仓库保留源码、测试、契约与必要工程文档。原始需求对话、正式健康日志、设备日志、运行数据库、签名资产和构建产物只保留在本地，详见 [仓库内容说明](docs/github-repository.md)。工程约定见 [AGENTS.md](AGENTS.md)。第三方资源许可位于 `AgentResources/licenses`。

独立 Watch App、长期目标任务、主动提醒和自动周复盘属于后续范围。
