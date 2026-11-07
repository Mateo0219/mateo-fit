# 输入、工具与状态

## 必要输入
由宿主提供 JSON snapshot，字段应包括：snapshot_id、generated_at、timezone、mode、profile_revision、current_plan_version、confirmed_profile、today_state、records、coverage、calculation_results、consent_scope、available_tools。时间采用带时区的 ISO 8601；数值注明单位。不要向模型发送不相关的身份信息。

每条记录含 record_id、source_id、source_type（healthkit / manual / photo_estimate / calculation）、start_at、end_at、value、unit、confidence/uncertainty、confirmed、revision。来源不明不能提升为确认事实。模型不得自行补造这些字段的值。

coverage 按数据类型提供查询区间、有效记录天数、最后更新时间、已知限制。睡眠应说明区间覆盖；饮食应说明哪些餐次未知。读取权限可能不透明，禁止把无样本编码为“用户拒绝权限”或“全天未活动”。

## 实际工具
接口设计见包根 contracts/tools.json。只有宿主实际注册的工具可用。
- get_context：最少范围的结构化快照。
- lookup_food：有营养来源、版本、单位和过敏原字段的食品条目。
- calculate_meal：按食品 ID、确认份量、原始数据库字段计算；缺项不填零。
- calculate_trends：已去重、可比较数据的趋势和覆盖说明。
- commit_confirmed_record、apply_confirmed_plan：App 确认事件调用，不暴露为可由模型自行执行的写工具。

## 响应
使用 contracts/coach-response.schema.json。status 是 proposal、needs_input、insufficient_data 或 safety_pause。questions 只用于真正缺少的信息，普通建议无问题时为空。evidence_ids 只能引用 snapshot 中真实存在的记录或已返回工具结果 ID。缺少证据可返回空数组，但必须写明局限。

模型建议不能自动成为正式计划。计划变更保留旧版本、调整理由、证据 ID、应用日期、下次检查条件。宿主验证 snapshot 和版本，阻止并发覆盖及重复提交。

## 失败与降级
无云端授权：本地汇总和已有计划照常工作；不调用云模型。无饮食记录：给可执行的候选搭配并询问缺口，不能宣称全天缺多少蛋白质。食品数据库无法覆盖：明确估计/未知，不能虚构具体品牌营养值。查询或模型超时：返回已有计划与真实状态，取消后停止重试。
