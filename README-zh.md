# pilot

Claude Code 自动化开发流水线：从 Notion 需求到 Draft PR，全程自主运行。

## 功能概述

输入一个 Notion 需求链接，流水线自动完成：
1. **获取** 需求 — 从 Notion 拉取需求（+ Figma 设计稿）
2. **设计** 技术方案 — Opus 子代理分析代码库，产出架构设计 + 可测试组件表
3. **审查** 设计 — 独立 Opus 子代理，隔离上下文防止自评偏差
4. **规划** 实施步骤 — 带测试分类、模式引用、验证命令、需求溯源（acRefs）
5. **实现** 代码 — 可测试步骤走 TDD（RED→GREEN + 锚定集回归），验证步骤走构建验证
6. **审查** 代码 — 双层审查（硬门槛 + 评分维度）、交互式 QA（Chrome DevTools）、计划覆盖率 + 测试覆盖率
7. **创建** Draft PR — 完成后自动切换到队列中的下一个项目

全程自主运行 — 仅在审查升级（ESCALATE）或不可恢复错误时询问用户。

## 安装

```bash
# 从 GitHub 安装
claude plugin install github:housesigma/pilot

# 本地开发
claude --plugin-dir /path/to/pilot
```

## 前置要求

- Claude Code（Opus 模型）
- Notion MCP 访问权限（OAuth — 首次使用触发浏览器认证）
- Figma MCP 访问权限（可选，用于设计关联的需求）
- `gh` CLI 已认证（用于创建 PR）
- `jq`（用于流水线门控脚本）

## 使用方式

```bash
# 启动流水线
/pilot https://notion.so/your-requirement-page

# 恢复中断的流水线
/pilot resume

# 查看流水线状态
/pilot status

# 清理流水线产物
/pilot clean
```

### 推荐启动方式

```bash
# 在目标项目目录中启动（自动加载项目的 .claude/ hooks/rules）
cd ~/housesigma/web-hybrid
claude
/pilot https://notion.so/your-requirement-page

# 或从 monorepo 根目录启动（支持多项目）
cd ~/housesigma
claude
/pilot https://notion.so/your-requirement-page
```

### 流水线运行中

流水线全自主运行，你会看到阶段转换日志：

```
需求: Claim Homes | 平台: web-hybrid, ios, android | AC: 15 条 | Figma: 有
项目: web-hybrid | 分支: feat/claim-homes | 步骤: 8
✅ web-hybrid PR: https://github.com/.../pull/321 (score: 90)
✅ ios PR: https://github.com/.../pull/28 (score: 100)
✅ android PR: https://github.com/.../pull/26 (score: 100)
Pipeline 完成. 清理 .pilot/ 文件？
```

### 何时需要人工介入

仅三种情况：
1. **ESCALATE** — 设计审查或代码审查发现不可自动解决的问题
2. **完成** — 所有 PR 已创建，询问是否清理
3. **不可恢复错误** — 环境故障、MCP 认证过期

## 架构

### 流水线阶段

```
FETCH → RESOLVE → [DESIGN → REVIEW →] PLAN → IMPLEMENT → CODE_REVIEW (+VISUAL_CHECK) → PR [→ PROJECT_TRANSITION → repeat]
```

- 方括号内的阶段对**简单任务**（≤3 AC, 1-3 文件）自动跳过
- **父代理**（轻量编排器）直接执行 FETCH、RESOLVE、PLAN、PR、PROJECT_TRANSITION
- **4 个 Opus 子代理**执行 DESIGN、REVIEW、IMPLEMENT、CODE_REVIEW

### 子代理职责

| 子代理 | 模型 | 工具 | 职责 |
|--------|------|------|------|
| tech-designer | Opus | Read, Glob, Grep, LSP | 分析代码库，产出技术设计 + 可测试组件表 |
| design-reviewer | Opus | Read, Glob, Grep, LSP | 独立审查设计，检查未溯源假设（groundingCheck） |
| implementer | Opus | Read, Write, Edit, Bash, Glob, Grep, LSP | TDD 实现 + JIT 文件读取 + 锚定集回归保护 |
| code-reviewer | Opus | Read, Glob, Grep, Bash, LSP, Chrome DevTools | 双层审查 + 交互式 QA + 评分一致性验证 |

### 核心设计原则

1. **脚本 > 提示词** — 关键门控用 hook 脚本强制（exit 2 阻断），不靠提示词遵守
2. **架构前置，实现即时** — tech-designer 决定"做什么"，implementer 通过读真实代码发现"怎么做"
3. **SDD + AC 驱动 TDD** — 规范驱动设计，验收标准驱动测试，测试框架无关
4. **上下文隔离** — 每个子代理获得全新上下文；父代理不积累实现细节
5. **显式上下文注入** — 子代理不自动继承项目文档；父代理发现 .claude/ 文件并注入
6. **需求溯源** — 每个计划步骤必须关联到验收标准（acRefs），脚本强制阻断未溯源步骤
7. **评分校准** — FIX_REQUIRED 时信心分不超过 72，评分维度 < 5 强制 FIX_REQUIRED

### 质量门控（脚本强制）

| 脚本 | 触发 | 规则 |
|------|------|------|
| `validate-plan.sh` | 写入 plan.json | 非脚手架步骤必须有 acRefs；AC 编号不超范围 |
| `validate-code-review.sh` | 写入 code-review.json | FIX_REQUIRED → 信心分 ≤ 72；维度 < 5 → 必须 FIX_REQUIRED；信心分 ≈ 维度均值 × 10 |
| `validate-review.sh` | 写入 review.json | 必须包含 groundingCheck；未溯源 API 变更 → 不能 APPROVE |
| `validate-artifacts.sh` | 所有 .pilot/ 写入 | 调度器：路由到对应验证器 + state.json session 注入 |

### 复杂度路由

RESOLVE 阶段根据需求范围分类：
- **简单**（≤3 AC, 1-3 文件, bug 修复）→ 跳过 DESIGN+REVIEW，直接 PLAN
- **标准**（新功能, 多组件）→ 完整流水线
- **复杂**（多项目, 新架构）→ 完整流水线

## 项目配置

### 目标项目自定义

每个目标项目通过 `.claude/` 目录自定义流水线行为：

| 目录 | 用途 | 读取者 |
|------|------|--------|
| `CLAUDE.md` | 构建/测试/lint 命令 | 所有子代理（父代理注入） |
| `.claude/rules/*.md` | 编码规范 | implementer + code-reviewer |
| `.claude/steering/*.md` | 架构、技术栈文档 | implementer + code-reviewer |
| `.claude/docs/*.md` | 环境配置、认证流程 | implementer + code-reviewer |

### MCP 服务器

`.mcp.json` 配置：
```json
{
  "mcpServers": {
    "notion": { "command": "npx", "args": ["-y", "@anthropic/notion-mcp"] },
    "figma": { "command": "npx", "args": ["-y", "@anthropic/figma-mcp"] },
    "chrome-devtools": { "command": "npx", "args": ["-y", "@anthropic/chrome-devtools-mcp"] }
  }
}
```

### 遥测

每次流水线运行追加到 `~/.pilot-telemetry.tsv`：

| 维度 | 分值 | 计算方式 |
|------|------|---------|
| 完成度 | 40 分 | 运行到 PR/COMPLETED |
| 低干预 | 30 分 | 0 次询问 = 30 分，每次 -10 |
| 设计一次通过 | 15 分 | 1 轮 = 15 分，每多一轮 -5 |
| 代码审查一次通过 | 15 分 | 1 轮 = 15 分，每多一轮 -5 |

```bash
# 查看遥测数据
column -t -s $'\t' ~/.pilot-telemetry.tsv
```

## 流水线产物

```
.pilot/
├── state.json                 ← 流水线状态机
├── requirement.json           ← 获取的需求（跨项目共享）
├── tech-design.md             ← 架构设计（当前项目）
├── review.json                ← 设计审查结果（含 groundingCheck）
├── plan.json                  ← 实施计划（含 acRefs 溯源 + 验证命令）
├── code-review.json           ← 代码审查（含 rubricScores + qaResult）
├── visual-review.json         ← 视觉检查结果（条件性）
├── cross-project-summary.md   ← API 契约 + 设计决策（多项目）
└── completed/                 ← 已完成项目的归档产物
```

## 监控

```bash
# 查看当前状态
cat .pilot/state.json | jq '{phase, targetProject, completedSteps}'

# 停滞检测（超过 10 分钟无状态更新发送 macOS 通知）
bash /path/to/pilot/scripts/health-check.sh 10
```

## 目标 Monorepo 布局

本插件为 HouseSigma monorepo 结构设计：
```
~/housesigma/                      (非 git 仓库)
├── web-hybrid/                    (Vue 3, pnpm, TS)
├── housesigma-ios-native/         (Swift 6+, SwiftUI)
├── housesigma-android-native/     (Kotlin, Gradle)
└── realagent-datafeed/            (PHP, Phalcon)
```

每个子项目是独立的 git 仓库。`.pilot/` 产物始终在 CWD（monorepo 根目录或子项目目录）。

## 开发

### 本地开发

```bash
claude --plugin-dir /path/to/pilot
```

### 测试

无自动化测试套件。通过对 Notion URL 运行完整流水线手动测试。测试结果记录在 `TEST-RESULTS-v*.md` 文件中。

### 架构压力测试

每次模型升级时，运行结构化实验验证组件是否仍然必要：

| 实验 | 假设 | 通过标准 |
|------|------|---------|
| Designer + Reviewer 合并 | 单个代理能否同时生成和审查设计 | 变体捕获 ≥ 80% 的未溯源假设 |
| Implementer 自审查 | Implementer 能否自行发现代码问题 | 0 个 CRITICAL 遗漏，≤ 1 个 MAJOR |
| Context 持久化 | 每步新上下文 vs 单次调用全步骤 | 锚定回归数、总耗时、上下文使用量 |

## 许可证

MIT
