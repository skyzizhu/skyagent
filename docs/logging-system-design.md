# SkyAgent 日志系统设计稿

更新时间：2026-04-07

## 目标

- 看性能：为什么提交后慢，慢在哪一段
- 看行为：为什么命中了某个 skill / MCP / tool
- 看故障：超时、失败、重试、权限、脚本异常到底发生在哪
- 看产品：后面能统计哪些能力最常用、最慢、最容易失败

## 总原则

- 统一事件模型
- 统一 `trace_id`
- 分层分类
- 开发态可读，持久化可分析
- 默认低干扰，开发模式更详细
- 敏感信息默认脱敏

## 分期计划

### Phase 1：Conversation Trace + 基础事件骨架

- [x] 定义 `LogEvent`、`LogLevel`、`LogCategory`、`LogStatus`
- [x] 定义 `TraceContext`
- [x] 实现 `LoggerService`、`LogStore`、`LogRedactor`
- [x] 实现按天 `ndjson` 落盘
- [x] 接入 `conversation` 基础事件
- [x] 构建验证通过

### Phase 2：LLM Timing

- [x] 记录 `context_prepare_started / finished`
- [x] 记录 `memory_context_built`
- [x] 记录 `llm_request_started`
- [x] 记录 `llm_first_token_received`
- [x] 记录 `llm_stream_finished / request_failed`
- [x] 构建验证通过

### Phase 3：Tool / Skill / MCP / Shell Execution

- [x] 接入内建 tool 开始 / 完成 / 失败 / 跳过
- [x] 接入 skill 路由、activate、script 开始 / 完成 / timeout
- [x] 接入 MCP discover / initialize / call / read / prompt
- [x] 接入 shell 开始 / 完成 / timeout
- [x] 构建验证通过

### Phase 4：Error / Timeout / Retry 统一模型

- [x] 定义统一 `error_kind`
- [x] 接入 `retry_count`
- [x] 接入 `recovery_action`
- [x] 接入 `is_user_visible`
- [x] 构建验证通过

### Phase 5：UI / Rendering / Interaction

- [x] 接入会话切换耗时
- [x] 接入 transcript 刷新耗时
- [x] 接入 markdown 渲染耗时
- [x] 接入输入框焦点异常
- [x] 构建验证通过

## 统一数据结构

```swift
struct LogEvent: Codable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: LogCategory
    let event: String

    let traceID: String?
    let conversationID: UUID?
    let messageID: UUID?
    let operationID: String?
    let requestID: String?

    let status: LogStatus?
    let durationMs: Double?
    let summary: String
    let metadata: [String: LogValue]
}
```

## 目录结构

第一版统一落盘到：

- `~/.skyagent/logs/events/YYYY-MM-DD.ndjson`

后续可拆分为：

- `~/.skyagent/logs/app/`
- `~/.skyagent/logs/conversations/`
- `~/.skyagent/logs/llm/`
- `~/.skyagent/logs/tools/`
- `~/.skyagent/logs/mcp/`
- `~/.skyagent/logs/skills/`
- `~/.skyagent/logs/ui/`

## 默认日志等级策略

- 用户模式：`info / warn / error`
- 开发模式：`debug / info / warn / error`

## 敏感信息策略

默认禁止直接记录：

- API Key
- MCP token
- Authorization header
- 完整用户正文
- 完整工具参数中的大段正文
- 文件全文

默认允许记录：

- 长度
- 摘要
- 路径
- 前 80-120 字预览
- 哈希

## 首批关键性能指标

- `submit_to_context_prepare_ms`
- `context_prepare_ms`
- `memory_retrieval_ms`
- `llm_first_token_ms`
- `llm_total_ms`
- `tool_exec_ms`
- `skill_script_exec_ms`
- `mcp_initialize_ms`
- `mcp_call_ms`
- `transcript_refresh_ms`
- `markdown_render_ms`
- `conversation_switch_ms`
