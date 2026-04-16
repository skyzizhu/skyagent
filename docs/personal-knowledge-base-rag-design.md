# SkyAgent 个人知识库 / RAG 集成设计稿

更新时间：2026-04-13

## 目标

- 为 SkyAgent 增加一套独立于记忆系统的“个人知识库”能力
- 支持导入用户资料并在会话中按需检索，而不是把大量资料直接塞进上下文
- 尽量不自己重造 RAG 基础轮子，优先集成成熟开源组件
- 保持 SkyAgent 仍然是主产品壳，不把系统做成“再套一个完整产品”
- 为后续扩展团队知识库、定时增量索引、多工作区绑定等能力预留结构

## 一句话结论

SkyAgent 不直接集成一整个现成的 RAG 产品，而是采用：

- 文档解析：Docling
- RAG 编排：LlamaIndex
- 本地向量存储：LanceDB
- 部署形态：本地 sidecar 服务

这意味着：

- SkyAgent 继续负责 UI、聊天、模型、MCP、skills、记忆、日志
- sidecar 负责导入、解析、切块、索引、检索、引用返回

## 为什么不直接嵌入一个完整开源 RAG 产品

市面上像 AnythingLLM、Open WebUI、RAGFlow 这类项目都很强，但它们本身已经是完整应用，不只是“RAG 引擎”。如果直接嵌入，会和 SkyAgent 在以下层面重复：

- 聊天入口
- 模型配置
- 文档管理
- 检索流程
- 工具编排
- 用户权限
- 状态展示
- 日志体系

这样做的后果通常不是“少做事”，而是：

- 两套状态流并存
- 两套配置并存
- 两套上下文逻辑相互影响
- 出问题时难以排查边界

因此本方案采用“组件集成”，而不是“产品套壳”。

## 组件选型

### 1. Docling

职责：

- 解析 PDF、DOCX、PPTX、HTML、Markdown、TXT 等资料
- 输出更结构化的文档中间结果，便于后续切块和引用定位

选择原因：

- 文档解析能力比简单纯文本抽取更稳
- 对复杂文档格式友好
- 与 LlamaIndex 有现成集成路径

### 2. LlamaIndex

职责：

- 文档切块
- 建索引
- 检索
- 召回
- 后续可接入 rerank / hybrid search

选择原因：

- 不是整套聊天产品，而是 RAG 编排层
- 模块化，适合嵌入到 SkyAgent 的现有链路中
- 生态成熟，后续替换模型或向量库都方便

### 3. LanceDB

职责：

- 本地嵌入式向量存储
- 保存 chunk、embedding、metadata

选择原因：

- 本地落地简单，适合个人桌面应用
- 嵌入式运行，部署成本低
- 很适合作为 MVP 的本地知识库存储层

### 4. Qdrant 作为后续备选

不在第一期使用，但保留未来切换可能。

适用场景：

- 多设备同步
- 团队知识库
- 远程服务化部署
- 更强的向量检索服务能力

## 与现有记忆系统的边界

这一层必须严格分开，否则很容易混乱。

### 现有三层记忆

- 全局记忆：`~/.skyagent/GLOBAL_SKYAGENT.md`
- 工作区记忆：`<workspace-root>/SKYAGENT.md`
- 会话记忆：`SESSION_CONTEXT.md` 与会话摘要

它们记录的是：

- 用户长期偏好
- 当前项目长期规则
- 当前会话任务状态

### 知识库不是记忆

个人知识库记录的是：

- 外部资料
- 长文档内容
- 参考手册
- 历史文档事实
- 可被检索的知识片段

它不应该被自动写进：

- 全局记忆
- 工作区记忆
- 会话长期摘要

### 设计原则

- 记忆系统负责“偏好、规则、任务状态”
- 知识库负责“按需检索的事实来源”
- 回答时仅把命中的少量片段注入上下文
- 不把整库内容塞进 prompt

## 产品边界

第一版个人知识库只做这四件事：

1. 导入资料
2. 建立索引
3. 提问时检索
4. 回答附引用

第一版暂时不做：

- 单机迁移与备份恢复
- 云端同步
- 自动写入长期记忆
- 自动知识图谱
- 多用户协作权限
- 文档自动总结看板
- 高级工作流编排

## 部署形态

采用本地 sidecar 服务，而不是把 Python RAG 逻辑直接塞进主 App 进程。

### 推荐结构

- SkyAgent 主程序
  - 会话 UI
  - 模型请求
  - 状态流
  - MCP / skills / shell / 文件工具
  - 记忆系统
  - 日志系统
- Knowledge Base Sidecar
  - 文档导入
  - 文档解析
  - chunking
  - embedding
  - 索引构建
  - 检索与引用返回

### 这样做的好处

- Swift 主工程保持干净
- Python RAG 生态复用更直接
- 后续替换解析器或向量库更容易
- 故障边界更清晰
- 日志更容易分层

## 系统架构

```text
User
  -> SkyAgent Chat UI
  -> Agent Orchestrator
     -> Memory Context Builder
     -> Tool / Skill / MCP Router
     -> Knowledge Retrieval Gateway
         -> KB Sidecar
            -> Docling Parser
            -> Chunk Builder
            -> Embedding Provider
            -> LanceDB Index
            -> Retriever
     -> LLM Final Response
  -> Transcript + Citations
```

## 查询链路

用户提问时，建议链路如下：

1. 用户提交问题
2. SkyAgent 判断当前会话是否启用了知识库
3. 如果未启用，则走原有链路
4. 如果启用了知识库，则发起检索请求到 sidecar
5. sidecar 返回：
   - 命中片段
   - 文件名
   - 标题或章节
   - 命中分数
   - 引用位置
6. SkyAgent 将检索结果作为“受控上下文”注入模型
7. 模型生成答案
8. UI 展示回答与引用来源

## 网页导入链路（补充）

网页导入必须避免“直接把 HTML 原样入库”。否则导航、广告、页脚等噪音会严重影响检索质量与引用可信度。

建议统一为：

1. SkyAgent 通过 `web_fetch` 抽取网页正文（去噪 + 结构化基础信息）
2. 将正文交给 sidecar 的 Docling 进一步结构化
3. 仅把清洗后的正文进入切块与索引

这样可以保证：

- 检索命中的是正文
- 引用片段可信
- 减少模型输出噪音

## 导入链路

资料导入建议如下：

1. 用户创建知识库
2. 用户导入文件、文件夹或网页链接
3. SkyAgent 将任务交给 sidecar
4. sidecar 执行：
   - 文件发现
   - 格式识别
   - Docling 解析
   - chunk 切分
   - embedding 生成
   - LanceDB 入库
5. sidecar 返回导入结果：
   - 成功数量
   - 失败数量
   - 失败原因
   - 索引时间
6. UI 展示导入状态与错误信息

## 与现有聊天链路的结合点

### 1. AgentOrchestrator

新增一层知识库网关，例如：

- `KnowledgeBaseGateway`

职责：

- 接收会话级检索请求
- 选择启用的知识库
- 发起 sidecar 请求
- 返回标准化检索结果

### 2. ChatViewModel / ConversationStore

建议新增会话级知识库选择状态，例如：

- 当前是否启用知识库
- 当前启用了哪些知识库
- 当前回答是否使用了知识库结果

### 3. LLMService

不直接接知识库逻辑，只接收“已整理好的检索片段”作为附加上下文。

这样职责更清楚：

- `LLMService` 只管模型请求
- `KnowledgeBaseGateway` 只管检索

### 4. 日志系统

知识库链路应接入现有日志系统，并新增：

- `kb_import_started`
- `kb_import_finished`
- `kb_parse_failed`
- `kb_index_started`
- `kb_index_finished`
- `kb_query_started`
- `kb_query_finished`
- `kb_query_failed`
- `kb_rerank_finished`

## 目录结构建议

在现有 `~/.skyagent/` 下新增：

```text
~/.skyagent/knowledge/
  libraries.json
  sidecar/
    config.json
    runtime/
    logs/
  libraries/
    <library-id>/
      meta.json
      source/
      parsed/
      chunks/
      index/
      cache/
```

### 各目录职责

- `libraries.json`
  - 知识库总索引
  - 记录每个知识库的名称、ID、创建时间、状态

- `sidecar/config.json`
  - sidecar 配置
  - embedding provider、检索参数、默认 chunk 策略等

- `sidecar/runtime/`
  - 运行时文件，如 PID、socket、临时状态

- `sidecar/logs/`
  - sidecar 独立日志
  - 后续可并入统一日志展示

- `libraries/<library-id>/meta.json`
  - 单个知识库元信息

- `libraries/<library-id>/source/`
  - 原始导入内容或其镜像

- `libraries/<library-id>/parsed/`
  - Docling 输出的结构化中间结果

- `libraries/<library-id>/chunks/`
  - 切块结果与 metadata

- `libraries/<library-id>/index/`
  - LanceDB 实际索引

- `libraries/<library-id>/cache/`
  - embedding 缓存与中间文件

## 数据模型建议

### KnowledgeLibrary

```swift
struct KnowledgeLibrary: Codable, Identifiable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var status: LibraryStatus
    var documentCount: Int
    var chunkCount: Int
}
```

### KnowledgeDocument

```swift
struct KnowledgeDocument: Codable, Identifiable {
    let id: UUID
    let libraryID: UUID
    var name: String
    var sourceType: SourceType
    var originalPath: String?
    var importedAt: Date
    var parseStatus: ParseStatus
    var chunkCount: Int
}
```

### RetrievalHit

```swift
struct RetrievalHit: Codable, Identifiable {
    let id: UUID
    let libraryID: UUID
    let documentID: UUID
    let title: String?
    let snippet: String
    let score: Double
    let citation: String?
}
```

## UI 设计建议

第一版建议新增独立“知识库”页面，而不是混在记忆设置里。

### 页面结构

1. 知识库列表页
- 创建知识库
- 查看知识库状态
- 查看文档数量 / chunk 数量
- 查看最近更新时间

2. 单个知识库详情页
- 导入文件
- 导入文件夹
- 导入网页链接
- 查看文档列表
- 查看失败项
- 重建索引
- 删除知识库

3. 会话中的知识库开关
- 当前会话是否启用知识库
- 选择一个或多个知识库
- 明确显示回答是否引用了知识库

### 会话中的状态建议

知识库检索状态不要和工具/MCP 状态混为一谈，建议单独定义：

- 检索知识库...
- 已命中知识片段
- 正在根据知识库内容生成回答

## 与 MCP / skills 的关系

知识库不直接作为 MCP，也不应该伪装成 skill。

原因：

- MCP 更适合第三方能力接入
- skill 更适合面向模型的显式能力包装
- 知识库是产品原生能力，应该拥有自己的状态、配置、日志和 UI

但后续可以保留扩展点：

- 允许某些知识库由 MCP 提供外部连接源
- 允许 skill 把产出文件写入指定知识库

## 引用展示（补充）

如果知识库参与回答，引用必须明确展示来源。建议显示结构：

- 文件名 / 来源 URL
- 章节标题（如有）
- 命中片段
- 位置定位（页码或段落索引）

不建议只展示“命中片段”，否则用户很难判断可信度。

## Sidecar API 协议（补充）

建议明确最小 API：

- `POST /kb/import`
  - body: libraryId, sources[]
- `POST /kb/query`
  - body: libraryId, query, topK
- `GET /kb/status`
  - 查询 sidecar 健康与索引状态
- `GET /kb/libraries`
  - 返回知识库列表与统计

## 多语言切块（补充）

分句与 chunk 策略应根据系统语言：

- 中文：按句号 / 分号 / 换行优先
- 英文：按句号 / 段落优先

避免中文用英文分句导致 chunk 过长或断句异常。

## Embedding 方案建议

第一期建议把 embedding provider 做成可替换配置，不写死。

初期可支持：

- 与主模型同供应商的 embedding 模型
- 独立 embedding API
- 后续增加本地 embedding 模型

第一版不建议：

- 直接复用聊天模型做 embedding
- 把 embedding 逻辑硬编码进主应用

## 安全与隐私边界

个人知识库里很可能会放敏感资料，因此需要明确边界：

- 默认本地存储
- 默认不上传原文到第三方服务，除非用户显式配置远程 embedding / rerank
- UI 中明确展示当前 embedding provider 是否远程
- 支持删除知识库时彻底删除原始文件镜像、索引和缓存

日志中默认不记录：

- 文档全文
- 完整 chunk 正文
- 敏感凭证

日志中允许记录：

- 文档名
- 大小
- 类型
- chunk 数
- 索引耗时
- 查询耗时
- 命中数量

## Phase 1 MVP 范围

当前进度说明：

- 下面勾选状态表示“当前仓库实现状态”，不是最终目标状态
- 目前已经做出可运行的知识库 MVP，但底层仍是轻量 sidecar 引擎
- 设计稿里规划的 `Docling + LlamaIndex + LanceDB` 正式栈还没有接入，因此“本地解析与切块 / 本地索引”虽然可用，但还不等于最终选型已完成

### 功能

- [x] 创建知识库
- [x] 删除知识库
- [x] 导入文件 / 文件夹
- [x] 本地解析与切块（MVP 轻量实现，非最终技术栈）
- [x] 本地建立 LanceDB 索引（可选后端，自动降级）
- [x] 会话中手动启用知识库
- [x] 提问时进行检索
- [x] 回答中展示引用来源
- [x] 接入基础日志

### 暂不包含

- [x] 多知识库自动路由（MVP 规则版）
- [x] hybrid search（MVP 规则版）
- [x] rerank（MVP 规则版）
- [x] 网页增量抓取（MVP 内容哈希版）
- [x] 单机知识库导出 / 导入（第一版）
- [x] 备份恢复（整库打包）
- [x] 自动定时重建索引（MVP 运行期调度版）

## 后续分期

### Phase 2：可用性增强

- [x] 多知识库选择
- [x] 导入失败重试
- [x] 文档级删除
- [x] 重建索引
- [x] 索引状态可视化
- [x] 知识库健康体检入口（元数据 / 目录 / 孤儿记录审查）
- [x] 独立知识库总览页
- [x] 单库管理页
- [x] 会话引用跳转到具体知识库 / 文档
- [x] 文档详情与片段预览
- [x] 手动测试检索

### Phase 3：检索质量增强

- [x] hybrid retrieval（MVP 规则版）
- [x] rerank（MVP 规则版）
- [x] chunk 策略按文件类型优化（MVP 规则版）
- [x] 查询改写（MVP 规则版）
- [x] source / title 命中加权与弱命中自适应过滤（MVP 规则版）

### Phase 4：工作区融合

- [x] 工作区绑定默认知识库
- [x] 不同工作区自动建议对应知识库
- [x] 与定时任务联动做索引更新（应用运行期间定时巡检 + 维护计划可见化）

## 当前建议的实施顺序

建议不要一开始就写 UI 全套，而是按下面顺序推进：

1. 先落 sidecar 技术方案与本地目录结构
2. 先做最小导入和检索闭环
3. 再接入主会话链路
4. 再做知识库管理 UI
5. 最后做检索质量优化

## Phase 1 拆分（补充）

### Phase 1A（最小闭环）

- [x] sidecar 进程管理
- [x] 本地文件导入
- [x] Docling 解析（可选后端，自动降级）
- [x] chunk 切分（MVP）
- [x] LanceDB 索引（可选后端，自动降级）
- [x] query 检索返回

### Phase 1B（会话接入）

- [x] 会话中启用知识库
- [x] 检索注入模型
- [x] 回答引用展示
- [x] 基础状态与日志接入

## 风险与注意事项

### 1. 不要把知识库和记忆混用

这是最大风险。知识库命中片段只能作为“当前回答的补充上下文”，不能直接沉淀为长期记忆。

### 2. 不要把所有知识库一次性塞进 prompt

必须严格控制注入量，否则很容易：

- 变慢
- token 爆炸
- 回答质量下降

### 3. 不要把 sidecar 做成第二个主系统

sidecar 只负责 RAG 执行层，不负责：

- 用户账户
- 会话 UI
- 主模型配置
- 任务编排

### 4. 引用必须可见

如果知识库参与了回答，用户最好能看到来源文件和片段，否则容易失去信任感。

## 推荐结论

对于当前 SkyAgent，最合适的路径是：

- 不集成整套现成 RAG 产品
- 集成 `Docling + LlamaIndex + LanceDB`
- 用本地 sidecar 方式接入
- 保持知识库与记忆系统严格分层
- 先做个人知识库 MVP，再逐步扩展

## 参考资料

- Docling: https://docling-project.github.io/docling/
- Docling Quickstart: https://docling-project.github.io/docling/getting_started/quickstart/
- Docling + LlamaIndex Integration: https://docling-project.github.io/docling/integrations/llamaindex/
- LlamaIndex RAG: https://developers.llamaindex.ai/python/framework/understanding/rag/
- LanceDB Quickstart: https://docs.lancedb.com/quickstart
- Qdrant Documentation: https://qdrant.tech/documentation/
