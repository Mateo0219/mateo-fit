# Mateo Fit 0.10.0（19）：Thinking、联网研究与流式回复

交付日期：2026-11-05。iPhone 已覆盖安装并读回 0.10.0（19），启动成功；保留 `com.personal.xuxu.app` 和原数据目录。后端已部署。用户于 2026-11-05 确认“入口和回复都正常”，思考与联网／研究菜单和普通回复的真机体验验收通过。

## 如何使用

输入框底部保留完整模型版本名称。点“快速”选择快速／思考低／高／最大；点地球图标选择不联网／联网搜索／Deep Research。首次选研究会将快速切到高思考，之后仍可自行调整。默认快速、不联网。图片使用支持图文的 Flash，支持 Thinking；图片分析不同时启用网页研究。

回复生成期间显示实际处理阶段和已生成完整句子的预览；点停止即可取消。来源默认折叠，点引用可打开原文，回复旁的信息按钮显示真实调用次数及供应商返回的 token／缓存用量。未返回的用量显示“未提供”。模型内部原始推理不显示、不落盘。

## 能力对应

| 能力 | 本版行为 | 证据与边界 |
| --- | --- | --- |
| Thinking | 实际传入 disabled 或 enabled + low/high/max | Flash 四档、Pro 低思考均通过真实 API；检测到实际 reasoning_content，仅保留是否存在的布尔标记 |
| 流式回复 | Chat Completions SSE → HTTPS SSE → Swift URLSession | 实际收到完整句子增量；完整回复通过结构与业务校验后才出现可提交操作 |
| Search / Fetch | 仅注册只读搜索与网页读取工具 | 搜索模式最多 3 次工具；研究最多 6 次工具、3 轮检索模型，再进行最终综合 |
| Deep Research | 多轮搜索、阅读、综合，显示已注册来源 | 是 App 的研究工作流，不声称 DeepSeek 存在独立 deep_research 参数；总时限 300 秒 |
| Tool Calling | 保留同一工具轮所需 reasoning_content；工具结果按不可信证据处理 | 工具只有搜索与读取；模型不能写训练、餐食或记忆 |
| 结构化输出 | 复用 JSON、JSON Schema 与业务校验 | 提案仍由 App 确认事件提交，流式预览不是保存回执 |
| 图像 | 已授权的餐食图片内联发送，可选择思考强度 | 真实合成营养标签 + Thinking 通过，结果仍待确认，不进入日合计 |
| 上下文缓存 | 使用供应商自动缓存，显示实际命中统计 | 不设置假的“开启缓存”开关 |
| 取消／超时／预算 | 主动停止、进入后台、撤销摘要授权均取消；无自动重试 | 每日请求与付费子调用分别计数；客户端断开后释放服务器并发名额 |

Responses、Anthropic 兼容是可选协议接入方式；FIM 和前缀补全偏向代码补全，不新增健身聊天入口。Files API 是可复用图片存储接口，不是通用 PDF 解析服务；本版继续使用内联图片，未新增供应商持久文件副本。因此交付的是本产品相关的 API 能力闭环，并非声称包装了供应商的每一个端点。

## 隐私与保存

健康摘要和记忆摘要仍由两个独立设置控制，默认关闭。联网检索规划器只收到当前问题，不收到个人摘要；要求将问题抽象为公共知识查询，拦截联系方式、令牌等检索词。用户消息中的个人描述仍可能被模型理解，不能将这些过滤声称为完美匿名化。网页读取只允许本次搜索返回的公开 HTTPS 地址。

最终综合只得到本次已授权的上下文。服务器不保存健康／记忆库、照片、对话或原始推理；预算数据库只保存计数。请求选项、最终来源与调用详情跟随本机对话保存和备份。进入后台会取消当前请求，尚未实现关闭 App 后持续研究。

## 验证

- 233 项核心、103 项存储、23 项聊天交互、93 项服务端检查通过。新增流顺序／请求身份、错误终止、未知用量、Thinking 参数、来源约束、工具推理衔接、取消释放、照片流程、来源保存恢复等检查。
- 原生 Swift HTTPS 真实调用：Flash 快速／低／高／最大、V4 Pro 低思考、搜索、研究、图片 Thinking 和取消均通过。均使用软件合成文本／标签，没有上传个人健康摘要，没有写入手机正式记录。
- 最终后端复测：连续取消两次后普通回复正常；研究实际 4 次模型、3 次搜索、2 次读取，引用当前官方 Thinking 和 Search 页面。
- iOS、Mac Debug／Release 和 iPhone Air 模拟器编译通过。Mac 与 iOS 签名有效。
- 模拟器已观察到完整模型名、思考入口和地球入口。已检查真实研究回复的合成测试状态，来源折叠与信息入口可见；不把预置状态当作模拟器自动点击完成。
- 原生点击自动化受 macOS ScreenCaptureKit 捕捉错误阻挡；真机 0.10.0（19）安装、版本读回、进程启动已验证，用户已确认思考与联网／研究菜单入口、普通回复正常。
- HTTPS 健康检查正常，服务 active/running、NRestarts=0。本轮未重验 HealthKit 实际后台送达，也未新增后台 Agent、自动周复盘或 Watch App。

取消回归额外发现：ASGI 断开可能再次取消清理阶段的 await，从而漏释放并发名额。已用 try/finally 修复；测试覆盖完整 HTTP 断开路径，最终部署后连续取消复测通过。

## 文件与官方资料

源码主要在 `Server/deepseek_agent.py`、`Server/service.py`、`Sources/FitnessCore/CoachGeneration.swift`、`Sources/FitnessApp/CoachComposer.swift` 和 `CoachHomeView.swift`。保留旧 `/assistant/respond`、`/meal/analyze` 与 V1/V2 兼容，新能力通过 `/agent/status` 协商。

官方文档于本次实施核对：

- [Thinking](https://api-docs.deepseek.com/guides/thinking_mode/)
- [Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/)
- [Tool Calls](https://api-docs.deepseek.com/guides/tool_calls/)
- [Search / Fetch](https://api-docs.deepseek.com/guides/search/)
- [Responses](https://api-docs.deepseek.com/guides/responses_api/)
- [自动缓存](https://api-docs.deepseek.com/guides/kv_cache/)
- [Files](https://api-docs.deepseek.com/guides/files_api/)

证据日志保存在项目外 `../../work/v010-*.log`；日志使用合成数据，不包含连接令牌或供应商密钥。

发布归档：`../Mateo-Fit-0.10.0-Source.zip` 与 `../Mateo-Fit-0.10.0-Mac.zip`；稳定入口源码／Mac ZIP 同步更新。ZIP CRC、版本字段、必需源码以及 Mac 严格签名检查通过。
