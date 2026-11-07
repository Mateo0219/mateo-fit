# 设计参考与采用边界

研读日期：2026-11-01。本包为选择性改编的工作流规范，未打包或执行上游完整仓库，不声称原作者或临床机构认可本产品。

| 来源 | 用到的部分 | 没有照搬的部分 |
|---|---|---|
| [Surge-Dan/healthy-fitness-coach-skill](https://github.com/Surge-Dan/healthy-fitness-coach-skill) | 渐进建档、当天状态、简短训练、有限变量复盘、精确/习惯饮食模式 | 训记依赖、文件输出编排、未验证的自动连接 |
| [ailabs-393/nutritional-specialist](https://github.com/ailabs-393/ai-labs-claude-skills/tree/main/packages/skills/nutritional-specialist) | 过敏、口味、预算、烹饪偏好的持久化流程 | 写入 ~/.claude 的脚本与未实现的 set CLI；由 App 数据库实现 |
| [npapatheodorou/personal-trainer-skill](https://github.com/npapatheodorou/personal-trainer-skill) | 仅作为训练日志连续性与统一饮食/训练体验的概念参考 | 本次 LICENSE 路径未取得有效许可文件，不复制其源码或文案；固定加重与固定周期规则不采用 |
| [H1an1/health-coach](https://github.com/H1an1/health-coach) | 仅调研过设备导出思路 | 不导入其医学解释、营养缺乏判定与有重复计入风险的热量公式 |

改编自前两个 MIT 项目的部分保留许可于包根 licenses/。本次工作没有验证全部医学或营养主张；正式定量规则需要有来源的独立实现与专业复核。

官方技术依据：
- [HealthKit 授权](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
- [增量查询与删除记录](https://developer.apple.com/documentation/healthkit/executing-anchored-object-queries)
- [WorkoutSession](https://developer.apple.com/documentation/healthkit/hkworkoutsession)
- [Apple 账户与个人设备安装](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [米家 S400 同步苹果健康](https://www.mi.com/ph/support/faq/details/KA-235575/)
- [Apple 健康与隐私规范](https://developer.apple.com/app-store/review/guidelines/)
