# Что Cooldown читает и куда обращается

[English](PRIVACY.md) · **Русский**

Cooldown работает на вашем Mac. У проекта нет серверов, аналитики и телеметрии.

## Читает (только чтение)

| Что | Зачем |
|---|---|
| `~/.codex/sessions`, `~/.codex/archived_sessions` | токены, лимиты, начало и конец работы Codex |
| `~/.codex/state_*.sqlite` (только чтение) | список разговоров Codex и где лежат их файлы |
| `~/.codex/session_index.jsonl` | названия разговоров |
| `~/.claude/projects` | токены Claude Code |
| `~/Library/Application Support/Claude/plan-usage-history.json` | история лимитов, которую ведёт Claude Desktop |
| `~/Library/Application Support/Claude/claude-code-sessions` | названия сессий Claude Code из Claude Desktop |
| Окно Claude Desktop через «Универсальный доступ» | какой чат открыт, пишет ли Claude ответ, первые слова ответа |

## Запускает

- `codex app-server` — запрос лимитов `account/rateLimits/read` (официальный клиент Codex).
- `claude /usage` — экран лимитов Claude Code (официальный клиент). Хуки, строка статуса и фоновый
  трафик Claude Code для этого запуска выключены.
- `codex exec` — только задачи, которые вы сами отложили.
- `claude -p … --resume` — только сессии Claude Code, которые вы сами поставили на продолжение.

## Меняет (только с вашего согласия)

- `~/.claude/settings.json` — строка статуса и хуки Cooldown, если вы их включили. Перед записью
  рядом сохраняется копия. Чужие записи (например, Coucou) не трогаются.
- `~/.codex/hooks.json` — хуки Cooldown, если вы их включили. Codex попросит их разрешить.

Хук Cooldown только дописывает одну строку в
`~/Library/Application Support/Cooldown/hook-events.jsonl` и сразу выходит.

## Отправляет

- В чат Claude Desktop — одно сообщение-продолжение, **только по вашему нажатию**.
- На claude.ai — только если вы сами вошли в claude.ai в настройках Cooldown: чтение лимитов и
  списка чатов (не чаще раза в 2 и 5 минут). Это внутренние адреса сайта, не официальный API;
  автоматический доступ ограничен условиями Anthropic — включайте осознанно.

Вход Claude Code (токен из Связки ключей) Cooldown не использует: Anthropic разрешает его только
в собственных приложениях.

## Хранит

Всё в `~/Library/Application Support/Cooldown/`: история лимитов и токенов (45 дней), итоги по дням,
события, выбранные чаты, записи для диагностики (`activity.log`, до 256 КБ).
