# Kanban Factory: исследование рынка и технологий (по состоянию на 2 октября 2026)

> Метод: README и метаданные GitHub (звёзды, дата последнего push, лицензия получены через GitHub API 2026‑10‑02), официальная документация, блоги вендоров. Всё, что не удалось проверить, помечено **[не проверено]** или **[неточно]**. Звёзды округлены.

## 0. TL;DR

1. Готового продукта, который делает **ровно** вашу фабрику (настраиваемые колонки → харнесс+модель+скилл на стадию → WIP-лимиты → петля «тестер возвращает кодеру» → остановка по квотам), среди крупных проектов нет. Ближе всех:
   - **Kangentic** — канбан с настраиваемыми колонками и агентом/моделью/промптом на колонку, передача контекста Claude↔Codex, MCP для агентов (маленький, AGPL-3.0).
   - **Agent Orchestrator (AO)** — зрелый локальный десктоп + демон, 32 харнесса, живой канбан, автоматический возврат упавшего CI и ревью-замечаний агенту, показывает квоты Codex (Apache-2.0, ~12.6k★).
   - **OpenAI Symphony** — не продукт, а **спецификация** оркестратора: опрос трекера, лимиты конкурентности **по состояниям** (= WIP на колонку), ретраи, сверка состояния, учёт rate-limit (только Codex, только Linear в эталонной реализации).
   - **Automaker** — канбан + автозапуск агента при переносе в In Progress, конкурентность (по умолчанию 3), режимы планирования, зависимости.
   - **Archon** — YAML-движок воркфлоу (plan → implement loop until tests pass → review → human approve → PR), не канбан.
   - Мелкие свежие репо почти один в один повторяют идею (`leoli-dev/ai-agent-kanban-board`, `cglab-public/agenfk`, `cyanluna.skills`, `galvani/kanban-pro`), но у них 0–200 звёзд.
2. Технически всё нужное уже есть: `codex app-server` (JSON-RPC + **чтение квот** `account/rateLimits/read`), `claude -p --output-format stream-json` / Claude Agent SDK, `cursor-agent -p --output-format stream-json` + Cursor SDK (TS/Python, bridge-протокол), `gemini -p --output-format stream-json`, **ACP** (Claude/Codex через адаптеры, Gemini, Cursor, Copilot, OpenCode, Kiro и др.), MCP для обратного канала «агент → доска».
3. Рекомендация: строить **тонкий оркестратор** по модели Symphony SPEC (state machine + очередь + WIP по стадиям), а агентов подключать через ACP (универсально) + нативный Codex app-server (ради квот). Java/Spring реально (есть официальные MCP Java SDK и ACP java-sdk), но TS/Node даёт меньше трения, т.к. почти все SDK харнессов — TS/Python.

---

## 1. Существующие продукты и open source

### 1.1 Самые близкие к идее

**Kuzgun** — https://github.com/alpcanaydin/kuzgun · MIT · ~11★ · push 2026‑09‑29
Нативный macOS (Rust/GPUI) канбан тикетов mattpocock/skills из `.scratch/`; показывает сессии агентов (Claude Code, Codex, Cursor, Gemini CLI, OpenCode, Kimi, Copilot CLI, Junie и др.) по их файлам сессий. **Только читает**, ничего не оркестрирует («Kuzgun never writes to a board»). Подтверждено.

**Kangentic** — https://github.com/Kangentic/kangentic (сайт https://www.kangentic.com) · AGPL-3.0 · ~123★ · push 2026‑10‑02
Локальное десктоп-приложение (Win/macOS/Linux, `npx kangentic`). Из README: настраиваемые воркфлоу (Plan/Execute/Review), на колонку — permission mode, авто-команды, «transition actions», инъекция промпта при входе в колонку, скрипты/PR на выходе; **модель на колонку и на задачу** (применяется через `/model`, `/effort` при пересечении границы колонки); **handoff контекста** между агентами (Claude план → Codex исполнение); у каждой сессии есть **MCP-инструменты** для создания/перемещения карточек; worktree на агента; импорт из GitHub Issues/Projects, Azure DevOps, Asana (Jira/Linear — «coming soon»). Харнессы: Claude Code, Codex, Gemini, Qwen, Cursor CLI, Copilot CLI, OpenCode, Aider, Warp Oz, Kimi, Droid — запускаются «родные» CLI в терминалах (PTY). WIP-лимиты и учёт квот в README **не упомянуты** [не проверено в коде].

**Agent Orchestrator (AO)** — https://github.com/Untrivial-ai/agent-orchestrator (бывш. ComposioHQ/agent-orchestrator, редирект) · Apache-2.0 · ~12.6k★ · push 2026‑10‑02 · docs https://docs.aoagents.dev
Локальный десктоп + демон (Go, SQLite, SSE). Worker = задача + агент + модель + worktree; «project orchestrator» — планирующий агент, который режет план на задачи и спаунит воркеров. Канбан строится **из фактов** (сессия, PR, CI, ревью): Working / Needs you / In review / Ready to merge. SCM-наблюдатель шлёт агенту «nudges» при упавшем CI, замечаниях ревью и merge-конфликтах — это **автоматическая петля обратной связи**. 32 агента; Codex через нативный app-server, Claude через `claude-agent-acp`, остальные через ACP/TUI. В Settings → Agents показываются «capacity, usage, reset-credit» для Codex (docs/STATUS.md). Колонки не настраиваются как пайплайн «coder→tester→reviewer» с разными ролями; WIP-лимиты не найдены. Есть телеметрия (включая GitHub-логин, отключаемая).

**OpenAI Symphony** — https://github.com/openai/symphony · Apache-2.0 · ~27.5k★ · создан 2026‑02‑26 · push 2026‑09‑15 · анонс https://openai.com/index/open-source-codex-orchestration-symphony/
«Low-key engineering preview». Главное — `SPEC.md` (~92 КБ), которую предлагается реализовать «на своём языке», плюс эталонная реализация на Elixir. Сервис опрашивает трекер (Linear), диспатчит задачи с ограниченной конкурентностью, каждой задаче — изолированный workspace, агент — `codex app-server`. В спеке есть ровно то, что вам нужно: `agent.max_concurrent_agents` и **`max_concurrent_agents_by_state`** (лимит на состояние = WIP на колонку), `max_turns`, ретраи с экспоненциальным backoff, stall/turn-таймауты, reconciliation (останов, если задача ушла из активного состояния), учёт токенов и `codex_rate_limits`, hooks, «handoff state» вроде `Human Review`. Ограничения: один харнесс (Codex), состояние планировщика in-memory. Есть комьюнити-порты под Claude Code (напр. https://github.com/janvdt/better-symphony; «Stokowski» — пост на Reddit удалён модератором, репо [не проверено]).

**Automaker** — https://github.com/AutoMaker-Org/automaker · MIT (по README; GitHub показывает NOASSERTION) · ~3.2k★ · push 2026‑05‑22 (активность снизилась)
Electron/web. Канбан Backlog → In Progress → Waiting Approval → Verified; перенос в In Progress автоматически запускает агента в worktree; **Concurrent Execution (по умолчанию 3)** — фактически глобальный WIP; режимы планирования (skip/lite/spec/full) с апрувом плана; AI Profiles (промпт+модель); зависимости между фичами и граф; импорт GitHub Issues; трекинг использования Claude. Основа — Claude Agent SDK, плюс провайдеры Codex, Copilot, Cursor, Gemini, OpenCode. Разных агентов на разные колонки и петли tester→coder нет (по README).

**Archon** — https://github.com/coleam00/Archon · MIT · ~23.6k★ · push 2026‑10‑02
«Harness builder»: YAML-DAG воркфлоу в `.archon/workflows/`; узлы — AI-промпты, bash, циклы `loop: until: ALL_TASKS_COMPLETE`, интерактивные human-approval гейты, worktree на запуск. Провайдеры: Claude, Codex, Pi. Учитывает токены/стоимость на прогон. Web UI, CLI, Slack/Telegram/GitHub. Не канбан, но отличный кандидат на «движок стадии».

### 1.2 Параллельные агенты в worktree (без конвейера стадий)

| Проект | URL | Лицензия | ★ / push | Суть |
|---|---|---|---|---|
| Vibe Kanban (BloopAI) | https://github.com/BloopAI/vibe-kanban | Apache-2.0 | 28.2k / 2026‑09‑19 | Канбан задач + workspaces (ветка, терминал, dev-сервер), 10+ агентов, диффы с инлайн-комментами агенту, PR, есть встроенный MCP-сервер. **Компания bloop закрылась 10.04.2026**, проект — «community maintained», облачные функции удалены (https://www.vibekanban.com/blog/shutdown). Автоматического конвейера колонок нет. |
| Conductor | https://www.conductor.build | проприетарный | — | macOS; параллельные Claude Code / Codex / Cursor в изолированных workspace. Free; Pro $50/мес (облако на Vercel Sandbox, API, мобильное приложение). |
| Emdash | https://github.com/generalaction/emdash | Apache-2.0 | 5.9k / 2026‑10‑02 | YC W26; агенты в worktree, локально или по SSH; задачи из Linear/GitHub/Jira/GitLab/Asana/YouTrack и др.; хуки агентов для статуса. |
| Superset | https://github.com/superset-sh/superset | нестандартная [неточно] | 14.8k / 2026‑10‑02 | «Agentic IDE», worktree, diff-viewer, браузер; macOS основная. |
| Claude Squad | https://github.com/smtg-ai/claude-squad | AGPL-3.0 | 8.6k / 2026‑08‑20 | TUI на tmux; Claude Code, Codex, Gemini, Aider, OpenCode, Amp. |
| Nimbalyst (бывш. Crystal) | https://github.com/nimbalyst/nimbalyst | MIT | 1.8k / 2026‑09‑30 | Визуальный workspace, kanban сессий, трекер задач, Codex/Claude Code, OpenCode/Copilot (alpha), Gemini; iOS-компаньон. Crystal (https://github.com/stravu/crystal) заморожен. |
| Sculptor (Imbue) | https://github.com/imbue-ai/sculptor | MIT | 235 / 2026‑10‑02 | Research preview; Claude Code + Pi, любые терминальные агенты; набор скиллов (spec, fix-bug). |
| Uzi | https://github.com/devflowinc/uzi | MIT | 583 / 2025‑06‑04 | CLI tmux+worktree; **заброшен**. |
| Terragon | https://github.com/terragon-labs/terragon-oss | Apache-2.0 | 259 | Облачный оркестратор Claude Code/Codex/Amp/Gemini; **закрыт 16.01.2026**, выложен снапшот. |
| Kiro Crew (AWS) | https://github.com/kirodotdev/KiroCrew | Apache-2.0 | 4.3k / 2026‑10‑02 | Локальный «persistent workspace» поверх `kiro-cli`, расписания, unattended-задачи. Сам Kiro (https://kiro.dev) — spec-driven IDE/CLI, поддерживает ACP. |

### 1.3 Планирование задач для агентов (без исполнителя)

- **Backlog.md** — https://github.com/MrLesk/Backlog.md · MIT · 6.9k★ · push 2026‑09‑28. Markdown-задачи в git, канбан в терминале (`backlog board`) и в браузере (`backlog browser`), MCP-коннектор для Claude Code/Codex/Gemini/Kiro/Cursor. Хорош как «хранилище бэклога».
- **Taskmaster AI** — https://github.com/eyaltoledano/claude-task-master · **MIT + Commons Clause** (не чистый OSS) · 28.1k★ · push 2026‑04‑28. PRD → задачи с зависимостями, MCP; провайдеры, включая Claude Code и Codex CLI по подписке.
- **CCPM** — https://github.com/automazeio/ccpm · MIT · 8.4k★ · push 2026‑03‑18. Agent Skill: PRD → epic → GitHub Issues → параллельные агенты в worktree.

### 1.4 Облачные «назначь тикет агенту»

- **GitHub Agent HQ / Copilot cloud agent** — назначить issue на Copilot, Claude или Codex (или всех трёх для сравнения), draft PR, итерации через `@claude`/`@codex` в комментариях; каждая сессия = 1 premium request. https://github.blog/changelog/2026-02-26-claude-and-codex-now-available-for-copilot-business-pro-users/ , https://docs.github.com/en/copilot/concepts/agents/about-third-party-coding-agents
- **Linear**: делегирование issue в Cursor (https://cursor.com/docs/integrations/linear) и Codex (https://developers.openai.com/codex/integrations/linear), собственные coding sessions Linear Agent на Claude Code/Codex с 11.06.2026 (https://linear.app/docs/coding-sessions), Agents API для своих агентов (https://linear.app/developers/agents) — делегат вместо исполнителя, вебхуки AgentSession.
- **Devin** — интеграции Linear/Jira, параллельные сессии; тарифы Free/Pro $20/Max $200 (по поиску, https://docs.devin.ai/admin/billing/self-serve) [неточно].
- **Factory.ai** — `droid exec` (headless), Missions (worker/validator модели), делегирование из Linear/Jira — Private Preview. https://docs.factory.ai/droid-exec/overview
- **OpenHands** — https://github.com/OpenHands/OpenHands · MIT · 89.8k★. Свой харнесс (не оркестратор чужих), Cloud-интеграции Jira/Linear/GitHub (`@openhands`, метка). Software Agent SDK: https://github.com/OpenHands/software-agent-sdk.
- **Plane/Taiga с агентами** — нативной интеграции «стадия → агент» не найдено [не проверено глубоко]; Plane (AGPL-3.0, 60k★) годится только как трекер.

### 1.5 Свежие маленькие проекты 2026, почти совпадающие с идеей (низкая зрелость!)

| Репо | ★ / лицензия | Что есть |
|---|---|---|
| https://github.com/leoli-dev/ai-agent-kanban-board | 0 / MIT, июнь 2026 | Planner (Q&A) → апрув плана → DAG задач → роли coder/reviewer/tester/debugger; **модель по роли с приоритетами-фолбэками**, retry count, **review bounce limit**, параллелизм, wall-clock лимит, авто-разбиение задачи на подзадачи, worktree, Claude Code/Codex + Anthropic-совместимые API. |
| https://github.com/cglab-public/agenfk | 66 / ISC, активен | TODO→IN_PROGRESS→REVIEW→TEST→DONE; упавшие тесты **автоматически возвращают** карточку в IN_PROGRESS; редактор флоу; импорт Jira/GitHub Issues. |
| https://github.com/cyanluna-git/cyanluna.skills | 183 / без лицензии | 7 колонок, на каждую — роль-агент (Planner, Critic, Builder, Inspector, Ranger), маршрутизация моделей Claude/Codex, уровни пайплайна L1–L3. |
| https://github.com/galvani/kanban-pro | 0 / AGPL-3.0, сент. 2026 | Канбан **как MCP-сервер**: flow state machine, запрет нелегальных переходов, **WIP-лимиты на колонке**, лизинг карточек, attention-флаги, аудит. |
| https://github.com/tinkermonkey/switchyard | 0 / — | GitHub Projects v2 → колонка → специализированный Claude Code агент в Docker. |
| https://github.com/kagan-sh/kagan | ~12 / MIT | TUI-канбан, обязательный human review gate, MCP, 14 агентов. |

---

## 2. Технологии и строительные блоки

### 2.1 Headless-режимы харнессов (проверено по докам)

| Харнесс | Headless | Структурированный вывод | Продолжение сессии | Примечания |
|---|---|---|---|---|
| Codex CLI | `codex exec` | `--json` (JSONL), `--output-schema` | `codex exec resume --last / <id>` | https://developers.openai.com/codex/noninteractive. **`codex app-server`** — двунаправленный JSON-RPC по stdio (на нём VS Code-расширение, Symphony, AO). **Codex SDK** (TS, `@openai/codex-sdk`) оборачивает CLI: https://developers.openai.com/codex/sdk |
| Claude Code | `claude -p` | `--output-format json / stream-json`, `--json-schema` | `--continue`, `--resume <id>` | https://code.claude.com/docs/en/headless. JSON содержит `total_cost_usd` (оценка). Событие `system/api_retry` с `error: rate_limit`. `--bare` для воспроизводимости, `--append-system-prompt` для роли, `--mcp-config`, `--permission-mode`. Claude Agent SDK — Python/TS (официального Java нет). |
| Cursor CLI | `cursor-agent -p` | `--output-format text/json/stream-json`, `--stream-partial-output` | да | https://cursor.com/docs/cli/headless. Также **Cursor SDK** (TS и Python, local и cloud runtime, `agent.get_usage()` с токенами и ценой, `RateLimitError`) и **SDK Bridge** — открытый протокол для SDK на других языках: https://cursor.com/docs/sdk/python , https://cursor.com/docs/api. Cloud Agents API — beta для всех планов. |
| Gemini CLI | `gemini -p` | `--output-format json / stream-json` (init, message, tool_use, tool_result, error, result со статистикой токенов) | — | https://geminicli.com/docs/cli/headless/ |
| OpenCode, Kiro CLI, Copilot CLI, Qwen, Goose… | разные | через ACP | | список ACP-агентов ниже |

### 2.2 Протоколы

- **ACP (Agent Client Protocol)** — https://agentclientprotocol.com , спецификация https://github.com/agentclientprotocol/agent-client-protocol (Apache-2.0, 4.4k★). JSON-RPC по stdio между «клиентом» (редактор/оркестратор) и агентом: сессии, промпты, стриминг, tool calls, **запросы разрешений**. Список агентов (https://agentclientprotocol.com/overview/agents): Claude Agent (через адаптер https://github.com/agentclientprotocol/claude-agent-acp), Codex CLI (через адаптер, https://github.com/zed-industries/codex-acp), Cursor, Gemini CLI, GitHub Copilot (preview), OpenCode, Kiro CLI, Junie, Goose, Qwen Code, Factory Droid, OpenHands, Cline, Pi и др. Есть **Java SDK**: https://github.com/agentclientprotocol/java-sdk (Apache-2.0, ~72★, молодой, примеры со Spring AI). **Для вашей фабрики ACP — лучший универсальный слой управления**.
- **MCP** — канал «агент → доска»: приложение поднимает MCP-сервер с инструментами `report_progress`, `complete_stage(result, artifacts)`, `return_to_stage(stage, issues[])`, `request_human(question)`, `get_task_context`. Так делают Kangentic, kanban-pro, Vibe Kanban, Kagan. Java: официальный https://github.com/modelcontextprotocol/java-sdk (MIT, 3.7k★, со Spring AI). Рекомендую **не доверять только «агент сказал done»**: переход стадии подтверждать детерминированными проверками (тесты/сборка/линтер, exit code, structured output по JSON Schema).
- **A2A** — https://github.com/a2aproject/A2A (Apache-2.0, 26k★), Java SDK https://github.com/a2aproject/a2a-java. Протокол «агент↔агент» между непрозрачными сервисами; для локальной фабрики с CLI-харнессами **не нужен** (ни один из CLI не выставляет A2A-эндпоинт нативно [не проверено для всех]).
- **Codex app-server** — JSON-RPC 2.0 по stdio (README: https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md), генерация схемы `codex app-server generate-json-schema`.

### 2.3 Чтение лимитов/квот (самое слабое место экосистемы)

| Харнесс | Что реально доступно | Надёжность |
|---|---|---|
| Codex (подписка ChatGPT) | app-server `account/rateLimits/read` → `primary`/`secondary` окна с `usedPercent`, `windowDurationMins`, `resetsAt`, + уведомление `account/rateLimits/updated`. Только при ChatGPT-авторизации (API-ключ отклоняется). Схема: https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/typescript/v2/GetAccountRateLimitsResponse.ts | **Хорошо** — официальный протокол |
| Claude Code (Pro/Max) | statusline-скрипт получает JSON `rate_limits.five_hour/seven_day.used_percentage` и `resets_at` (https://code.claude.com/docs/en/statusline); есть баги, когда поле null (https://github.com/anthropics/claude-code/issues/59462). Statusline — функция интерактивного UI; срабатывает ли он в `-p` — [не проверено]. В headless: `total_cost_usd` (оценка) и события `api_retry` с `rate_limit`. | **Средне** |
| Cursor | SDK: `agent.get_usage()` (токены, `charged_cents`), `RateLimitError`; Admin API usage events — только Enterprise. Документированного API «сколько осталось в моём индивидуальном плане» **не найдено**. | **Слабо** — только реактивно + свой бюджет |
| Gemini CLI | токены в `result` (stream-json); остаток квоты — [не найдено] | Слабо |
| ccusage | https://github.com/ccusage/ccusage (18.8k★) — парсит локальные логи Claude Code, Codex, OpenCode, Amp, Gemini CLI, Copilot CLI и др.; это **оценка токенов/стоимости**, а не официальный остаток. | Оценка |

**Важно про подписку Claude:** Anthropic объявила, что с 15.06.2026 `claude -p` и Agent SDK будут списываться из отдельного месячного кредита, а не из лимитов подписки, но **15.06 изменение поставили на паузу**: «For now, nothing has changed» (https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan). Политика нестабильна — абстрагируйте биллинг.

### 2.4 Изоляция: git worktrees
Стандарт де-факто (все проекты выше). Ограничения (Superset docs прямо пишут): worktree **не изолирует процессы/порты и не предотвращает merge-конфликты**. Нужны: аллокация портов на задачу, отдельные БД/контейнеры для тестов (Testcontainers для Java), опционально Docker/devcontainer-песочница, стратегия слияния (rebase перед Review, авто-ретрай при конфликте, сериализация мерджей).

### 2.5 Workflow-движки — нужны ли
- **Temporal** (Java SDK https://github.com/temporalio/sdk-java): даёт durable execution, ретраи, таймеры, сигналы (human approval). Для одного пользователя локально — **перебор** (отдельный сервер). Имеет смысл, если фабрика станет командной/серверной.
- **n8n** — low-code, неудобно для долгих интерактивных агентских процессов и управления процессами CLI.
- **LangGraph / LangChain4j / Embabel** — фреймворки для построения *своего* агента; вам же нужен оркестратор *чужих* агентов → не нужны.
- **Archon** — уже готовый «workflow-движок для кодинг-агентов»; можно использовать как исполнитель отдельной стадии.
- Достаточно: **явная state machine + персистентная очередь (SQLite/Postgres) + планировщик** по образцу Symphony SPEC.

### 2.6 UI
- **Web UI на localhost** (React/Svelte/htmx) — проще всего, работает везде, можно открыть с телефона через tunnel.
- **Tauri** (Rust-оболочка, лёгкая) или **Electron** (тяжелее, но больше примеров: AO, Automaker, Emdash) — когда нужен нативный трей/уведомления/терминалы.
- Терминал в карточке: xterm.js + PTY (node-pty / pty4j в Java).

### 2.7 Рекомендуемый стек

**Вариант A (рекомендую для быстрого старта): TypeScript/Node** backend + React UI, позже Tauri/Electron. Почему: Claude Agent SDK, Codex SDK, Cursor SDK, ACP TS SDK, MCP TS SDK — все «первого класса» именно в TS; меньше адаптеров.

**Вариант B (честно жизнеспособен): Java 21+/Spring Boot**:
- оркестратор = Spring + state machine (свой код или Spring Statemachine) + virtual threads для процессов агентов;
- агенты через **ACP java-sdk** (Claude/Codex/Gemini/Cursor/OpenCode) + прямой JSON-RPC к `codex app-server` (ради квот) + fallback на CLI `-p --output-format stream-json` через `ProcessBuilder`/pty4j;
- MCP-сервер доски через **MCP Java SDK / Spring AI MCP Server**;
- хранилище SQLite/H2 или Postgres; UI — web (React или Vaadin/htmx), упаковка jpackage или Tauri-оболочка над localhost.
- Риски: ACP java-sdk молодой (~72★); Claude Agent SDK для Java только community (https://github.com/markpollack/claude-agent-sdk-java, ~9★); Cursor SDK для Java нет (есть bridge-протокол — придётся писать клиент).

**Вариант C (гибрид):** ядро-оркестратор на Java, «драйверы агентов» — маленькие Node-сайдкары на официальных SDK, общение по JSON-RPC/HTTP.

---

## 3. Собрать из готового vs строить

| Путь | Плюсы | Минусы |
|---|---|---|
| **Форк Kangentic** | Уже есть настраиваемые колонки, модель на колонку, handoff между агентами, MCP для агентов, 11 CLI, локально | AGPL-3.0 (ок для личного использования, ограничения при распространении); маленькое сообщество; WIP/квоты/авто-петли надо дописывать; Electron/TS |
| **Agent Orchestrator как есть / форк** | Зрелый, Apache-2.0, 32 агента, ACP + Codex app-server, петли CI/review → агент, квоты Codex | Колонки = факты PR/CI, а не ваш конвейер ролей; Go-кодовая база большая; телеметрия |
| **Реализовать Symphony SPEC (на Java)** | Готовая продуманная модель: опрос трекера, WIP по состоянию, ретраи, reconciliation, таймауты, учёт rate-limit; OpenAI прямо предлагает «build in your language» | Только Codex/Linear в спеке — надо расширить драйверами агентов и локальным трекером; UI писать самому |
| **Vibe Kanban форк** | Популярен (28k★), Rust+TS, MCP, 10+ агентов | Компания закрылась; конвейера стадий нет; судьба community-версии неясна |
| **Backlog.md + скрипт-оркестратор** | Задачи — markdown в git, канбан и MCP бесплатно; оркестратор = cron/демон, который читает статусы и вызывает `codex exec`/`claude -p` | Нет живого статуса агентов, квот, UI для логов — всё дописывать; гонки при параллельной записи файлов |
| **Linear/GitHub + облачные агенты** | Ноль кода: делегировать issue на Cursor/Codex/Copilot/Claude, триаж-правила | Облако, не локально; нет вашего конвейера «coder→tester→reviewer» с WIP; платные premium requests/кредиты |
| **Archon как исполнитель стадии** | YAML-воркфлоу с циклами «до прохождения тестов» и human gate | Не канбан; провайдеры только Claude/Codex/Pi |

**Вывод:** если цель — пользоваться через 1–2 недели: попробовать **Kangentic** и **AO**, параллельно прочитать **Symphony SPEC**. Если цель — своя платформа (вы директор AI-инфры, возможно для команды): **свой тонкий оркестратор по SPEC Symphony**, агенты через ACP + Codex app-server, MCP-сервер доски, трекеры через их MCP/API. Харнессы не писать.

---

## 4. Дополнительные идеи

1. **Стоимость/токены на задачу и на стадию** (Claude `total_cost_usd`, Cursor `get_usage`, Codex token events, Gemini stats) + бюджет на задачу с остановкой.
2. **Лимит возвратов** tester→coder (как «review bounce limit») и **эскалация человеку** / смена модели на более сильную после N неудач.
3. **Граф зависимостей** задач (блокирующие — не берутся в работу).
4. **Merge-очередь**: rebase перед Review, детект конфликтов, автозадача «разрешить конфликт», сериализованный merge.
5. **Детерминированные гейты** между стадиями: сборка, тесты, линтер, coverage, SAST — агент не может «сказать done» без зелёного гейта.
6. **CI-интеграция**: результат CI по PR как вход стадии Testing; упавший CI → автоматический возврат.
7. **Best-of-N / racing**: одна задача 2–3 агентам (разные харнессы/модели), ревьюер выбирает лучший дифф (как в Agent HQ «assign multiple agents»).
8. **Стадия Spec/Plan** до разработки + апрув плана человеком (Automaker, Kiro, leoli).
9. **Авто-разбиение** больших задач на подзадачи (planner возвращает DAG).
10. **Таймауты**: stall timeout (нет событий N минут), wall-clock, max turns (как в Symphony).
11. **Маршрутизация моделей по сложности** (размер задачи/метки → модель; дешёвая модель для ревью).
12. **Квотный планировщик**: порог (например, <10% остатка) — не брать новые задачи; ночные окна; переключение на другой харнесс при исчерпании; приоритет «обновления лимита» по `resetsAt`.
13. **Уведомления** (desktop/Telegram/Slack) на «нужен человек», «задача готова».
14. **Аудит-лог и replay**: хранить транскрипты/события (stream-json/ACP) по каждой попытке, дифф на каждой стадии, кто перевёл карточку.
15. **Сохранение контекста между стадиями**: handoff-резюме (что сделано, решения, открытые вопросы) вместо полного транскрипта.
16. **Безопасность**: permission-профиль на стадию (ревьюер — read-only; тестер — без push), секреты не в промпт, песочница для `--yolo`-режимов.
17. **Метрики фабрики**: lead time, процент возвратов по стадиям, стоимость на задачу, успешность по харнессу/модели — данные для выбора моделей.
18. **Ресурсный учёт хоста**: лимит параллельности не только по WIP, но и по CPU/RAM/портам (сборки Java тяжёлые).

---

## 5. Неопределённости
- WIP-лимиты и учёт квот в Kangentic/AO — по README не найдены, код не изучался.
- Лицензия Superset и Automaker в GitHub API не распознана (NOASSERTION); README Automaker заявляет MIT.
- Будущее биллинга `claude -p`/Agent SDK по подписке — изменение на паузе с 15.06.2026, может вернуться.
- Работает ли statusline Claude Code (с `rate_limits`) в headless-режиме — не проверено.
- Официального API остатка квоты для индивидуальных планов Cursor/Gemini не найдено.
- Звёзды/активность — снимок на 2026‑10‑02.

---

## 6. Сравнительная таблица против требований

Легенда: ✅ есть · 🟡 частично · ❌ нет · ? не удалось подтвердить

| Проект | Харнессы | Стадии с разным агентом/моделью/скиллом | WIP-лимит | Петля tester→coder | Учёт квот | Трекеры (MCP/API) | Локально | Лицензия / ★ |
|---|---|---|---|---|---|---|---|---|
| Kuzgun | 12 (только чтение сессий) | ❌ (read-only) | ❌ | ❌ | ❌ | файлы mattpocock/skills | ✅ macOS | MIT / 11 |
| Kangentic | 11 CLI | ✅ колонка: модель, промпт, permissions, actions | ? | 🟡 (переходы/скрипты, авто-петля не описана) | ? | GitHub, Azure DevOps, Asana; Jira/Linear скоро | ✅ | AGPL-3.0 / 123 |
| Agent Orchestrator | 32 | 🟡 worker: агент+модель; оркестратор-агент; ревьюеры | ? | ✅ CI/ревью/конфликты → nudge агенту | 🟡 Codex usage/capacity | GitHub (PR/CI) | ✅ | Apache-2.0 / 12.6k |
| Symphony (спека) | Codex app-server | 🟡 состояния трекера, один агент | ✅ `max_concurrent_agents_by_state` | 🟡 через состояния трекера + ретраи | ✅ rate-limit snapshot Codex | Linear | ✅ self-host | Apache-2.0 / 27.5k |
| Automaker | Claude SDK + Codex, Cursor, Copilot, Gemini, OpenCode | 🟡 AI Profiles на фичу, не на колонку | ✅ глобально (3) | ❌ (ручная верификация) | 🟡 Claude usage | GitHub Issues | ✅ | MIT? / 3.2k |
| Archon | Claude, Codex, Pi | ✅ узлы DAG | ❌ | ✅ loop until tests pass | 🟡 учёт стоимости | GitHub, Slack, Telegram | ✅ | MIT / 23.6k |
| Vibe Kanban | 10+ | ❌ (агент на workspace) | ❌ | 🟡 ручные комменты к диффу | ❌ | — (облако удалено) | ✅ | Apache-2.0 / 28.2k, sunset |
| Emdash | ~10+ | ❌ | ❌ | ❌ | ❌ | Linear, GitHub, Jira, GitLab… | ✅ (+SSH) | Apache-2.0 / 5.9k |
| Conductor | Claude, Codex, Cursor | ❌ | ❌ | ❌ | ? | ? | ✅ macOS (+cloud Pro) | проприетарный |
| Claude Squad | 5+ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ TUI | AGPL-3.0 / 8.6k |
| Nimbalyst | Codex, Claude, OpenCode, Copilot, Gemini | ❌ | ❌ | ❌ | ? | свой трекер | ✅ | MIT / 1.8k |
| Backlog.md | любой через MCP/CLI | ❌ (нет исполнителя) | ❌ | ❌ | ❌ | git-markdown | ✅ | MIT / 6.9k |
| Taskmaster | через MCP | ❌ (нет исполнителя) | ❌ | ❌ | ❌ | — | ✅ | MIT+Commons Clause / 28.1k |
| CCPM | skill для многих | ❌ | ❌ | ❌ | ❌ | GitHub Issues | ✅ | MIT / 8.4k |
| GitHub Agent HQ | Copilot, Claude, Codex | ❌ | ❌ | 🟡 `@agent` в PR | premium requests | GitHub, Jira, Linear, Azure Boards | ❌ облако | SaaS |
| Linear agents | Cursor, Codex, Linear Agent (Claude Code/Codex) | 🟡 триаж-правила | ❌ | ❌ | AI-кредиты | Linear | ❌ облако | SaaS |
| leoli-dev/ai-agent-kanban-board | Claude Code, Codex, Anthropic-совм. API | ✅ роли + модель по роли | ✅ параллелизм | ✅ review bounce limit, retry | ❌ | ❌ | ✅ | MIT / 0 |
| agenfk | Claude Code и др. [неточно] | 🟡 настраиваемый флоу | ? | ✅ TEST fail → IN_PROGRESS | ? | Jira, GitHub Issues | ✅ | ISC / 66 |
| kanban-pro | любой через MCP | 🟡 flow state machine | ✅ на колонке | 🟡 легальные переходы | ❌ | ❌ | ✅ | AGPL-3.0 / 0 |
