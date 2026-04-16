# SkyAgent 等待状态与执行反馈系统设计稿

更新时间：2026-04-11

## 目标

- 让用户在等待过程中始终知道“系统现在在做什么”
- 避免状态重复、刷屏、晚到、内部名泄漏
- 统一 `Thinking / Tool / Skill / MCP / Shell / File` 的等待与结果反馈
- 将“运行中的状态”和“执行完成后的结果”彻底分层
- 为后续接入 `RAG / 定时任务 / 更多 MCP / 更多 skills` 预留统一框架

## 当前问题

现阶段等待过程存在几类典型问题：

- 状态来源不统一，有的来自 `pendingResponseStatus`，有的来自 `runningToolStatus`，有的又被额外插入到消息流里
- 工具或 MCP 已经触发，但用户第一时间看不到具体对象名
- 等待提示有时会重复插入，造成“思考中”卡片堆叠
- 执行中的反馈和执行完成后的工具结果卡片没有清晰分工
- MCP、skill、shell、文件工具在命名、时机、细节程度上不一致
- 长耗时任务缺少连续反馈，容易让用户误以为程序卡住

## 设计原则

### 1. 正文只放真实产出

聊天正文中只保留：

- 用户消息
- 助手正文
- 工具执行结果卡片
- 审批/确认类必要交互

等待态不再通过插入伪系统消息的方式进入正文流。

### 2. 等待态单实例

任一时刻，界面只应存在一个主等待态。

- 新状态覆盖旧状态
- 同一状态只更新内容，不新增第二张卡片
- 秒数递增基于同一视图刷新，不通过新消息实现

### 3. 触发即告知

一旦模型已经决定调用某个能力，必须立刻显示对象名。

例如：

- `MCP · drawiomcp · open_drawio_mermaid`
- `Skill · sky-prompt-image-gen-skill`
- `Shell · find ~/Desktop ...`
- `文件 · 写入 · SKYAGENT.md`

不能等到结果返回后才告诉用户刚刚调用了什么。

### 4. 状态与结果分层

- 主状态条：表达“现在正在做什么”
- 执行卡片：表达“刚刚做了什么，以及结果是什么”

这两个层级不能混用。

### 5. 命名统一、对用户友好

禁止在 UI 中泄漏内部实现名，例如：

- `mcp__734F8240BEC7__open_drawio_mermaid`
- `run_skill_script`
- `write_multiple_files`

统一转换为对用户可读的标题。

### 6. 长耗时要持续反馈，但不能刷屏

超过阈值后可以加强提示，但方式应为更新原位状态，而不是继续插入多条卡片或消息。

## 整体结构

等待状态系统分为三层：

### Layer 1：Activity State Engine

负责统一维护当前等待态。

职责：

- 收集 orchestrator / tool runner / MCP / skill / shell / LLM 流式事件
- 计算“当前唯一主状态”
- 负责阶段切换与耗时统计
- 为 UI 提供稳定、统一的 ViewModel

### Layer 2：Execution Timeline

负责记录实际执行过的动作节点。

职责：

- 当工具、skill、MCP、shell 真正启动时，生成一个执行节点
- 节点先以“占位卡片”存在
- 结果回来后回填摘要、耗时、错误、详细输出

### Layer 3：UI Presentation

负责展示。

职责：

- 主状态条
- 执行卡片
- 详情折叠面板
- 长输出截断与摘要

## 一、统一状态模型

建议引入统一的等待状态枚举：

```swift
enum ConversationWaitPhase {
    case thinking
    case preparing
    case running
    case streaming
    case waitingForApproval
    case retrying
    case failed
}
```

建议引入统一的执行对象类型：

```swift
enum ActivityKind {
    case assistant
    case tool
    case file
    case skill
    case mcp
    case shell
    case network
}
```

建议引入统一的主状态结构：

```swift
struct ConversationActivityState {
    let id: String
    let phase: ConversationWaitPhase
    let kind: ActivityKind
    let title: String
    let detail: String?
    let context: String?
    let badges: [String]
    let startedAt: Date
    let canShowElapsed: Bool
    let isBlocking: Bool
}
```

### 主状态含义

#### 1. `thinking`

含义：
模型正在理解输入、整理上下文、规划下一步。

显示策略：

- 标题：`思考中`
- 右侧显示秒数
- 默认不显示二级长文案

说明：
这个阶段用户只需要知道“系统在思考”，不需要再加一大段解释。

#### 2. `preparing`

含义：
模型已经决定要执行某个动作，但调用尚未正式发出。

显示策略：

- 标题：具体对象名
- 详情：`准备调用` / `准备执行` / `准备写入`

示例：

- `MCP · drawiomcp · open_drawio_mermaid`
- `Skill · sky-prompt-image-gen-skill`
- `文件 · 写入 · GLOBAL_SKYAGENT.md`

#### 3. `running`

含义：
外部动作已发出，系统正在等待返回。

显示策略：

- 标题：具体对象名
- 详情：当前阶段说明
- 秒数持续递增

示例：

- `MCP · drawiomcp · open_drawio_mermaid`
- `Shell · find ~/Desktop ...`

#### 4. `streaming`

含义：
模型已经开始输出正文。

显示策略：

- 当正文尚短且没有稳定输出时，显示 `生成中`
- 当正文已经持续滚动时，弱化或隐藏主状态条，避免视觉抢占

#### 5. `waitingForApproval`

含义：
需要用户授权或确认。

显示策略：

- 标题：待确认对象
- 详情：风险动作说明

说明：
不是所有 MCP/tool 都该弹窗，只有真正高风险动作才进入本状态。

#### 6. `retrying`

含义：
网络、MCP、skill 脚本等正在重试。

显示策略：

- 标题：对象名
- 详情：`重试中（第 N 次）`

#### 7. `failed`

含义：
执行失败，等待上层继续处理或展示结果。

显示策略：

- 标题：对象名
- 详情：失败摘要

## 二、统一标题规范

所有运行中和结果态标题必须遵守同一套规范。

### MCP

格式：

```text
MCP · <serverName> · <toolName>
```

示例：

```text
MCP · drawiomcp · open_drawio_mermaid
```

### Skill

格式：

```text
Skill · <skillName>
Skill · <skillName> · <scriptName>
```

示例：

```text
Skill · sky-prompt-image-gen-skill
Skill · sky-prompt-image-gen-skill · gen_from_prompt.sh
```

### Shell

格式：

```text
Shell · <commandPreview>
```

策略：

- 命令过长时截断到 36-48 个字符
- 保留最能识别意图的前缀

### 文件工具

格式：

```text
文件 · 读取 · <fileName>
文件 · 写入 · <fileName>
文件 · 扫描 · <directoryName>
文件 · 导出 · <fileName>
```

### 内建工具

格式：

```text
工具 · <friendlyName>
```

### Assistant 自身

格式：

```text
思考中
生成中
整理结果中
```

## 三、UI 结构

建议采用两层展示：

### A. 主状态条

位置建议：

- 紧贴在当前会话底部、输入框上方，或
- 紧贴在最后一个 AI 消息下方

建议优先级：

- 比正文更轻
- 比工具卡片更即时

建议组成：

- 左侧小图标
- 标题
- 紧挨标题的秒数
- 一行 detail
- 可选 badges

示意：

```text
[icon] MCP · drawiomcp · open_drawio_mermaid   12s
       正在等待 MCP 服务返回
```

交互规则：

- 单实例
- 实时替换，不叠加
- 状态消失后不在正文留痕

### B. 执行卡片

位置：

- 出现在正文流中

创建时机：

- 真实执行启动时创建占位卡片

回填时机：

- 得到结果、错误、超时、部分输出后更新卡片

卡片内容：

- 标题
- 成功/失败状态
- 用时
- 一段摘要
- 展开看参数/输出/日志

示意：

```text
MCP · drawiomcp · open_drawio_mermaid
已完成 · 14.2s
已生成 draw.io Mermaid 图并返回结果
[详情]
```

### C. 详情折叠面板

用于承载：

- 参数
- 输出
- stdout/stderr
- 截断提示
- 打开文件 / Reveal in Finder / 打开结果

默认折叠，防止会话被大文本撑爆。

## 四、时间维度规则

等待反馈需要分层，但只能更新原状态，不新增消息。

### `0-2s`

- 只显示状态标题
- 不显示“长说明”

### `2-8s`

- 显示对象名 + 秒数
- 显示一行 detail

示例：

```text
MCP · drawiomcp · open_drawio_mermaid   5s
正在执行
```

### `8-20s`

- 开始强调阶段
- detail 可以升级为更具体的提示

示例：

```text
MCP · drawiomcp · open_drawio_mermaid   14s
正在等待服务返回结果
```

### `20s+`

- 显示“耗时较长但仍在继续”
- 不能用弹窗打断
- 不能再往正文插入提示消息

示例：

```text
MCP · drawiomcp · open_drawio_mermaid   24s
执行时间较长，仍在处理中
```

## 五、不同能力的特殊反馈

### MCP

建议细分内部阶段：

- 已选择 server
- 初始化中
- 调用中
- 读取结果中
- 已返回

UI 映射：

- 主状态条显示当前阶段
- 执行卡片保存完整生命周期

如果有 progress / partial output：

- 优先更新执行卡片 detail
- 不要插入新消息

### Skill

建议阶段：

- 已选择 skill
- 激活中
- 读取资源中
- 执行脚本中
- 等待外部 API
- 汇总结果中

### Shell

建议阶段：

- 启动命令
- 命令运行中
- 收到输出
- 仍在执行
- 成功结束 / 超时 / 手动终止

### 文件工具

建议阶段：

- 定位目标
- 读取中 / 写入中 / 扫描中
- 已完成

对于大目录扫描，应优先返回统计摘要，而不是把全量路径直接塞进卡片正文。

## 六、长文本与大结果策略

这是等待感和“系统像断了一样”的关键问题之一。

### 原则

- 工具返回超大文本时，先做摘要，再决定是否展示原文
- AI 正文必须补一段自然语言总结，不能只把内容塞在工具卡片里

### 分层策略

#### 1. 小结果

- 直接显示

#### 2. 中结果

- 显示前 N 行 + 可展开

#### 3. 大结果

- 工具卡片只展示：
  - 数量统计
  - 前若干项
  - 已截断提示
- 助手正文补一段总结，例如：
  - `桌面共发现 4231 张图片，我先列出最相关的前 30 项，并可继续按目录汇总。`

### 推荐阈值

- 卡片默认预览：`2,000-4,000` 字符
- 展开后本地预览：`24,000-40,000` 字符
- 超过阈值必须摘要，不直接裸出全部结果

## 七、弹框与审批规则

建议重新收紧：

### 必须弹框

- 删除文件
- 覆盖关键文件
- 执行高风险 shell
- 导出到外部敏感目录
- 带 destructive hint 的第三方 MCP 动作

### 不应弹框

- 普通 MCP 读取/绘图/查询
- 普通 skill 执行
- 普通文件读取
- 普通 shell 查询类命令
- 普通工具结果展示

MCP 不应因为“第三方”这个事实就默认弹窗，应按风险级别决定。

## 八、事件流建议

### 典型链路：用户提问 -> MCP

```text
用户发送消息
-> 主状态：thinking
-> 主状态：preparing / MCP · drawiomcp · open_drawio_mermaid
-> 创建执行卡片占位：MCP · drawiomcp · open_drawio_mermaid
-> 主状态：running / 正在初始化
-> 主状态：running / 正在调用
-> 主状态：running / 正在等待结果
-> 执行卡片回填结果
-> 若随后模型继续写正文：主状态切换为 streaming
-> 正文完成后主状态消失
```

### 典型链路：用户提问 -> 纯文本回答

```text
用户发送消息
-> 主状态：thinking
-> 主状态：streaming
-> 正文稳定输出后弱化主状态
-> 结束
```

### 典型链路：用户提问 -> skill -> 文件产出

```text
thinking
-> preparing / Skill · xxx
-> 执行卡片占位：Skill · xxx
-> running / 执行脚本中
-> running / 等待 API 返回
-> 执行卡片回填：已生成图片
-> 若需要补正文，则进入 streaming
```

## 九、推荐的数据结构补充

建议新增一个“执行节点”模型：

```swift
struct ExecutionTimelineItem: Identifiable, Equatable {
    let id: String
    let kind: ActivityKind
    let title: String
    var subtitle: String?
    var status: ExecutionStatus
    let startedAt: Date
    var finishedAt: Date?
    var durationMs: Double?
    var summary: String?
    var detailPreview: String?
    var argumentsPreview: String?
    var outputPreview: String?
    var canExpand: Bool
}

enum ExecutionStatus {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case timedOut
}
```

用途：

- 将“工具结果卡片”从一次性消息视图升级为真正的执行节点
- 支持先占位后回填
- 支持未来接入流式日志和进度

## 十、实施分期

### Phase 1：状态模型收口

- [ ] 清理等待态插入正文的逻辑
- [ ] 收口主状态来源，只保留一个活动状态引擎
- [ ] 统一标题规范
- [ ] 统一 `thinking / preparing / running / streaming / retrying / failed`

### Phase 2：执行卡片占位化

- [ ] tool / skill / MCP / shell 启动即生成占位卡片
- [ ] 卡片支持结果回填
- [ ] 卡片标题全部改为友好格式
- [ ] 卡片默认展示摘要、耗时、状态

### Phase 3：长耗时与长输出优化

- [ ] 秒数原位递增
- [ ] 按时间阈值更新 detail
- [ ] 大结果默认摘要
- [ ] AI 正文补自然语言总结

### Phase 4：风险与审批统一

- [ ] 收紧弹框边界
- [ ] MCP 按风险分级，不再默认弹框
- [ ] destructive shell / file / MCP 使用统一审批入口

### Phase 5：视觉细调

- [ ] 主状态条视觉收敛
- [ ] 动画只保留一个轻量方案
- [ ] 深色模式适配
- [ ] 与正文卡片的层级关系统一

## 十一、V1 建议落地范围

第一版不建议一下做太满，优先做最能改善体感的部分：

- 单实例主状态条
- 统一标题规范
- MCP / Skill / Shell / 文件触发即显示对象名
- 删除伪等待消息
- 执行卡片先占位后回填
- 大结果做摘要，不让交互“断掉”

这一版完成后，等待过程的可理解性会明显提升。

## 十二、验收标准

满足以下标准，才算这套系统第一版合格：

- 用户提交后，1 秒内能看到明确状态
- 触发 tool / MCP / skill / shell 后，1 秒内能看到对象名
- 会话正文中不再出现重复“思考中”卡片
- 同一时刻只有一个主等待态
- 工具返回超大文本时，AI 正文仍会给出总结
- 执行结束后，结果卡片标题不再显示内部名
- 长耗时任务不会因状态缺失让用户误以为程序卡死

## 十三、结论

等待态不应再被当作文案问题零散修补，而应被视为一套统一的“执行反馈系统”。

这套系统的核心不是让界面更热闹，而是让用户在任何时刻都明确知道：

- 系统是否还在运行
- 当前正在做哪一步
- 刚刚到底调用了什么
- 结果出来后该去哪里看

后续如果认可这份设计稿，建议直接按 `Phase 1 -> Phase 2 -> Phase 3` 顺序实施，不再做零碎局部修补。
