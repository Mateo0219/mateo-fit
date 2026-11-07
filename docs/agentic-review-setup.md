# Agentic Review 本机配置

配置日期：2026-11-05。按用户选择安装到当前 macOS 用户的全局 Codex 技能目录，适用于该账户使用同一 Codex Home 的所有工程。

- 安装路径：`~/.codex/skills/agentic-review/`
- Skill 版本：`0.2.0`
- 来源：用户上传的 `agentic-review-main (1).zip` 中 `skills/agentic-review/`，共 28 个文件，原样安装。
- 调用方式：显式 `$agentic-review`；保持原包 `allow_implicit_invocation: false`，不会自动在每次开发后执行。
- Mateo Fit 项目规则：根目录 `.agentic-review.md`，由 `AGENTS.md` 的项目审查入口引用。其他项目使用各自的项目指令，不继承 Mateo Fit 的业务规则。

## 使用

需要独立审查时，在目标工程另开一段未参与编写的新对话，输入例如：

```text
$agentic-review 整体审查当前项目的代码，重点检查行为、可靠性、安全、性能和验证证据。只读，输出有依据的问题与完成条件。
```

也可选择具体产物和层级：

```text
$agentic-review 审查 docs/requirements.md 的需求与验收，以本轮提供的原始诉求为依据。
$agentic-review 审查 docs/architecture.md 的状态、失败和恢复责任。
$agentic-review 审查 docs/plan.md 的依赖、迁移及集成验收安排。
```

上述路径为其他工程的使用示例，调用时换成实际存在的文件。Mateo Fit 当前没有 Git 元数据，默认固定文件与哈希审查现状；有明确前后快照时才做增量审查。作者原会话内使用时标为自检，不当作独立审查。

默认审查已有材料，只写审查工作稿或指定报告；修复、执行项目测试、部署和发布依本轮授权另行处理。无需为本地 Skill 新增模型 API Key；它使用当前 Codex 会话的模型。GitHub App、Cloudflare Worker 与中央 PR 发布链路不属于本次全局 Skill 配置。

## 已验证

- 检查压缩包路径及文件类型，仅复制 Skill 子目录，没有执行上传包中的脚本或 workflow。
- 28 个安装文件逐一与上传版本核对 SHA-256，全部一致；相对文档引用完整。
- 使用本机 Codex App Server 的 `skills/list`，对 Mateo Fit 和独立临时目录分别强制刷新：均返回恰好一份 `agentic-review`，`scope=user`、`enabled=true`，没有该 Skill 的解析错误。
- 只验证安装和加载，没有运行项目审查，也没有据此宣称代码已经通过审查。

下一条 Codex 消息即可显式调用。安装证据位于项目外 `../../work/agentic-review-installation-2026-11-05.json`。
