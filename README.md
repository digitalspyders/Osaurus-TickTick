# osaurus-ticktick

An [Osaurus](https://osaurus.ai) plugin for managing [TickTick](https://ticktick.com) projects and tasks. Full CRUD over the TickTick Open API v1 — list, create, get, update, complete, delete, and move projects and tasks, plus search, filtering, reminders, recurrence, checklist items, and convenience views for due-today and overdue tasks.

**Author:** Digital Spyders (admin@digitalspyders.net)  
**License:** MIT

## Setup

1. Register a TickTick app at [developer.ticktick.com](https://developer.ticktick.com/manage) (or reuse an existing one). You need:
   - **Client ID**
   - **Client Secret**
   - **Redirect URL** — set this to `http://127.0.0.1:8080/` in your TickTick app settings (must match exactly).
2. In Osaurus: **Tools → TickTick → Configure** and paste your **Client ID** and **Client Secret** into the secret fields. Click **Save**.
3. Ask Osaurus to do something with TickTick (e.g., "list my TickTick projects"). The plugin will detect you need to authorize and open your browser to TickTick's authorization page automatically. Click **Allow** — the access token is stored and your request completes.

**How it works:** The first time you ask Osaurus to do something with TickTick, the plugin checks for an access token. If none exists but your credentials are configured, it automatically opens your browser to TickTick's OAuth page. After you authorize, TickTick redirects to `http://127.0.0.1:8080/`, the plugin catches the callback, exchanges the code for an access token, and stores it persistently. If the token expires later, just ask Osaurus to "connect my TickTick account" to re-authorize.

## Tools

| Tool | Description |
| --- | --- |
| `connect_account` | Authorize with TickTick via OAuth (opens browser, stores token) |
| `list_projects` | List all your TickTick projects |
| `get_project` | Get details about a specific project |
| `create_project` | Create a new project (name, color, view mode, kind, sort order) |
| `update_project` | Update an existing project's name, color, view mode, kind, or sort order |
| `delete_project` | Delete a project and all its tasks |
| `list_tasks` | List tasks in a project (filter: all / active / completed / overdue) |
| `search_tasks` | Search tasks across all projects and Inbox by keyword (title, content, tags) |
| `filter_tasks` | Server-side filter by project, date range, priority, tags, and status |
| `create_task` | Create a new task (title, content, dates, priority, tags, reminders, recurrence, checklist items) |
| `get_task` | Get details about a specific task |
| `update_task` | Update an existing task's fields (all fields supported) |
| `complete_task` | Mark a task as complete |
| `delete_task` | Delete a task |
| `move_task` | Move a task between projects |
| `get_completed_tasks` | Retrieve tasks completed within a time range |
| `get_tasks_due_today` | List all tasks due today |
| `get_overdue_tasks` | List all past-due active tasks |

## Priority

The plugin exposes a friendly 0–4 scale:

| Value | Label |
| --- | --- |
| 0 | none |
| 1 | low |
| 2 | medium |
| 3 | high |
| 4 | critical |

(TickTick's API uses 0/1/3/5 internally — the plugin translates for you.)

## Dates

Date parameters accept:
- ISO 8601 with offset: `2026-08-01T08:00:00-05:00`
- Day only: `2026-08-01`
- Relative phrases: `today`, `tomorrow`, `tomorrow at 8 AM`, `in 3 days`, `next monday`

Relative dates resolve in the user's local timezone.

## Development

### Build

```bash
swift build -c release
```

### Verify manifest

```bash
osaurus manifest extract .build/release/libosaurus-ticktick.dylib
osaurus manifest validate <extracted.json>
```

### Install locally

```bash
osaurus tools package osaurus.ticktick 0.1.0
osaurus tools install ./osaurus.ticktick-0.1.0.zip
osaurus tools reload
```

### Test

```bash
swift test
```

## License

MIT
