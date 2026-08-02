//
//  Plugin.swift
//  osaurus-ticktick
//
//  TickTick plugin for Osaurus — full CRUD over projects and tasks via
//  the TickTick Open API v1.
//
//  Auth: a single OAuth2/personal access token, configured in Osaurus
//  plugin settings and injected as the `access_token` secret.
//

import Foundation
import OsaurusPluginABI
import OsaurusPluginKit
#if canImport(AppKit)
import AppKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Manifest

/// File-scope plugin manifest JSON, returned verbatim by `get_manifest`.
/// The host caches this and uses it to populate the tool list and inject
/// the system prompt.
let ticktickManifestJSON = """
{
  "plugin_id": "osaurus.ticktick",
  "name": "TickTick",
  "version": "0.1.0",
  "description": "Full CRUD control of your TickTick projects and tasks via the TickTick Open API.",
  "license": "MIT",
  "authors": ["Digital Spyders"],
  "contact": "admin@digitalspyders.net",
  "min_macos": "15.0",
  "min_osaurus": "0.5.0",
  "instructions": "You can use the TickTick plugin to manage the user's projects and tasks.\\n\\n**Setup:** The user configures their TickTick Client ID and Client Secret in the plugin settings. The first time you call any TickTick tool, the plugin will automatically open the user's browser for OAuth authorization if they haven't connected yet. You can also call `connect_account` explicitly to re-authorize.\\n\\nIf any tool returns 'permission_denied', the access token has expired or is missing. Call `connect_account` to re-authorize.\\n\\nAvailable tools:\\n  - connect_account: Opens browser for TickTick OAuth authorization (use for re-authorization)\\n  - list_projects: Shows all TickTick projects\\n  - create_project: Creates a new project (supports color, view_mode, kind, sort_order)\\n  - get_project: Gets details about a specific project\\n  - update_project: Updates an existing project (name, color, view_mode, kind, sort_order)\\n  - delete_project: Deletes a project and all its tasks\\n  - list_tasks: Lists tasks in a project (filter: all/active/completed/overdue)\\n  - search_tasks: Searches tasks across ALL projects and Inbox by keyword. Returns task id and project_id needed for update/complete/delete.\\n  - filter_tasks: Server-side filter by project, date range, priority, tags, and status\\n  - create_task: Creates a new task (supports tags, reminders, recurrence, checklist items)\\n  - get_task: Gets details about a specific task\\n  - update_task: Updates an existing task (supports all fields)\\n  - complete_task: Marks a task as complete\\n  - delete_task: Deletes a task\\n  - move_task: Moves a task between projects\\n  - get_completed_tasks: Retrieves completed tasks within a time range\\n  - get_tasks_due_today: Lists tasks due today\\n  - get_overdue_tasks: Lists past-due tasks\\n\\nPriority uses a friendly 0-4 scale: 0=none, 1=low, 2=medium, 3=high, 4=critical. Note: filter_tasks uses the API scale (0,1,3,5).\\n\\nDates accept ISO 8601 ('2026-08-01T08:00:00-05:00'), 'YYYY-MM-DD', or relative phrases like 'today' / 'tomorrow at 8 AM'. Relative dates resolve in the user's local timezone.",
  "secrets": [
    {
      "id": "client_id",
      "label": "TickTick Client ID",
      "description": "The Client ID from your TickTick app at [developer.ticktick.com](https://developer.ticktick.com/manage) → your app → Settings.",
      "required": true,
      "url": "https://developer.ticktick.com/manage"
    },
    {
      "id": "client_secret",
      "label": "TickTick Client Secret",
      "description": "The Client Secret from your TickTick app at [developer.ticktick.com](https://developer.ticktick.com/manage) → your app → Settings.",
      "required": true,
      "url": "https://developer.ticktick.com/manage"
    }
  ],
  "capabilities": {
    "tools": [
      {
        "id": "connect_account",
        "description": "Connects the user's TickTick account via OAuth2. CALL THIS TOOL directly — it opens the user's browser automatically, catches the OAuth callback, and stores the access token. Do NOT give the user manual instructions or URLs. Run this first before any other TickTick tool, or when the access token has expired.",
        "parameters": {
          "type": "object",
          "properties": {},
          "required": []
        },
        "requirements": ["network"],
        "permission_policy": "ask"
      },
      {
        "id": "list_projects",
        "description": "List all your TickTick projects",
        "parameters": {
          "type": "object",
          "properties": {
            "view": {
              "type": "string",
              "enum": ["all", "active"],
              "description": "Filter projects by status (default: active)"
            },
            "limit": {
              "type": "integer",
              "description": "Maximum number of projects to return (default: 50, max: 100)",
              "minimum": 1,
              "maximum": 100
            }
          },
          "required": []
        },
        "requirements": ["network"],
        "permission_policy": "auto"
      },
      {
        "id": "get_project",
        "description": "Get details about a specific TickTick project",
        "parameters": {
          "type": "object",
          "properties": {
            "project_id": {
              "type": "string",
              "description": "The unique identifier of the TickTick project"
            }
          },
          "required": ["project_id"]
        },
        "requirements": ["network"],
        "permission_policy": "auto"
      },
      {
        "id": "create_project",
        "description": "Create a new TickTick project",
        "parameters": {
          "type": "object",
          "properties": {
            "name": {
              "type": "string",
              "description": "Name of the project"
            },
            "color": {
              "type": "string",
              "description": "Project color as a hex string, e.g. '#F18181' or '#4A90E2'",
              "maxLength": 7
            },
            "view_mode": {
              "type": "string",
              "enum": ["list", "kanban", "timeline"],
              "description": "Project view mode. Defaults to 'list'."
            },
            "kind": {
              "type": "string",
              "enum": ["TASK", "NOTE"],
              "description": "Project kind. 'TASK' (default) for task lists, 'NOTE' for notes."
            },
            "sort_order": {
              "type": "integer",
              "description": "Sort order value for the project. Lower values appear higher in the list."
            },
            "tag": {
              "type": "string",
              "description": "Optional tag (accepted for compatibility; TickTick v1 does not tag projects)"
            }
          },
          "required": ["name"]
        },
        "requirements": ["network"],
        "permission_policy": "ask"
      },
      {
        "id": "delete_project",
        "description": "Delete a TickTick project and all its tasks",
        "parameters": {
          "type": "object",
          "properties": {
            "project_id": {
              "type": "string",
              "description": "The unique identifier of the project to delete"
            }
          },
          "required": ["project_id"]
        },
        "requirements": ["network"],
        "permission_policy": "ask"
      },
      {
        "id": "update_project",
        "description": "Update an existing TickTick project. Only provided fields are changed.",
        "parameters": {
          "type": "object",
          "properties": {
            "project_id": {
              "type": "string",
              "description": "The unique identifier of the project to update"
            },
            "name": {
              "type": "string",
              "description": "New project name"
            },
            "color": {
              "type": "string",
              "description": "New project color as a hex string, e.g. '#F18181'",
              "maxLength": 7
            },
            "view_mode": {
              "type": "string",
              "enum": ["list", "kanban", "timeline"],
              "description": "New project view mode"
            },
            "kind": {
              "type": "string",
              "enum": ["TASK", "NOTE"],
              "description": "New project kind"
            },
            "sort_order": {
              "type": "integer",
              "description": "New sort order value for the project"
            }
          },
          "required": ["project_id"]
        },
        "requirements": ["network"],
        "permission_policy": "ask"
      },
      {
        "id": "list_tasks",
        "description": "List tasks in a specific TickTick project",
        "parameters": {
          "type": "object",
          "properties": {
            "project_id": {
              "type": "string",
              "description": "The project ID containing the tasks"
            },
            "filter": {
              "type": "string",
              "enum": ["all", "active", "completed", "overdue"],
              "description": "Filter tasks by status (default: active)"
            },
            "priority": {
              "type": "integer",
              "minimum": 0,
              "maximum": 4,
              "description": "Filter by priority (0=none, 1=low, 2=medium, 3=high, 4=critical)"
            },
            "limit": {
              "type": "integer",
              "minimum": 1,
              "maximum": 100,
              "description": "Maximum number of tasks to return (default: 50)"
            }
          },
          "required": ["project_id"]
        },
        "requirements": ["network"],
        "permission_policy": "auto"
      },
      {
        "id": "search_tasks",
        "description": "Search for tasks by keyword across ALL projects and the Inbox. Matches against task title, content, or tags. Returns matching tasks with their id and project_id — use these with update_task, complete_task, or delete_task.",
        "parameters": {
          "type": "object",
          "properties": {
            "query": {
              "type": "string",
              "description": "Search term to match against task title, content, or tags"
            },
            "project_id": {
              "type": "string",
              "description": "Optional: limit search to a specific project"
            },
            "limit": {
              "type": "integer",
              "minimum": 1,
              "maximum": 50,
              "description": "Maximum number of results (default: 20)"
            }
          },
          "required": ["query"]
        },
        "requirements": ["network"],
        "permission_policy": "auto"
      },
      {
        "id": "create_task",
        "description": "Create a new task in a TickTick project. Supports tags, reminders, recurrence, checklist items, and more.",
        "parameters": {
          "type": "object",
          "properties": {
            "project_id": {
              "type": "string",
              "description": "The project ID to add the task to. If omitted, the task is created in the user's default list (Inbox)."
            },
            "title": {
              "type": "string",
              "description": "Title of the task"
            },
            "content": {
              "type": "string",
              "description": "Task description / notes (Markdown supported)"
            },
            "desc": {
              "type": "string",
              "description": "Calendar description — shown in calendar views. Separate from 'content' which is the task's notes."
            },
            "start_date": {
              "type": "string",
              "description": "Start date. Accepts ISO 8601 ('2026-08-01T08:00:00-05:00'), 'YYYY-MM-DD', or relative phrases like 'today' / 'tomorrow at 8 AM'. Resolved in the user's local timezone."
            },
            "due_date": {
              "type": "string",
              "description": "Due date. Same format as start_date."
            },
            "priority": {
              "type": "integer",
              "minimum": 0,
              "maximum": 4,
              "description": "Priority level (0=none, 1=low, 2=medium, 3=high, 4=critical). Defaults to 0."
            },
            "is_all_day": {
              "type": "boolean",
              "description": "If true, the task is an all-day task (no specific time). Defaults to false."
            },
            "tags": {
              "type": "array",
              "items": { "type": "string" },
              "description": "List of tag names to assign, e.g. ['work', 'urgent']."
            },
            "time_zone": {
              "type": "string",
              "description": "Time zone for the task, e.g. 'America/New_York', 'Europe/London'. Defaults to the user's local time zone."
            },
            "parent_id": {
              "type": "string",
              "description": "Parent task ID — set this to create a subtask. The parent must be in the same project."
            },
            "reminders": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Alert reminders using iCalendar TRIGGER format. 'TRIGGER:PT0S' = at the due time, 'TRIGGER:PT-15M' = 15 min before, 'TRIGGER:PT-1H' = 1 hour before, 'TRIGGER:P1D' = 1 day before. Can include multiple reminders."
            },
            "repeat_flag": {
              "type": "string",
              "description": "Recurrence rule in RRULE-like format. Examples: 'FREQ=DAILY;INTERVAL=1' (daily), 'FREQ=WEEKLY;INTERVAL=1' (weekly), 'FREQ=MONTHLY;INTERVAL=1' (monthly), 'FREQ=DAILY;INTERVAL=3' (every 3 days)."
            },
            "sort_order": {
              "type": "integer",
              "description": "Sort position within the project. Lower values appear higher. Defaults to 0."
            },
            "items": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "title": { "type": "string", "description": "Checklist item title" },
                  "start_date": { "type": "string", "description": "Item start date (ISO 8601 or relative)" },
                  "is_all_day": { "type": "boolean", "description": "All-day flag for the item" },
                  "sort_order": { "type": "integer", "description": "Sort order within the checklist" }
                },
                "required": ["title"]
              },
              "description": "Checklist items (subtasks) to include in the task. Each item has a title and optional date/sort."
            }
          },
          "required": ["title"]
        },
        "requirements": ["network"],
        "permission_policy": "ask"
      },
      {
        "id": "get_task",
        "description": "Get detailed information about a specific task",
        "parameters": {
          "type": "object",
          "properties": {
            "project_id": {
              "type": "string",
              "description": "The project ID containing the task"
            },
            "task_id": {
              "type": "string",
              "description": "The unique identifier of the task"
            }
          },
          "required": ["project_id", "task_id"]
        },
        "requirements": ["network"],
        "permission_policy": "auto"
      },
      {
        "id": "update_task",
        "description": "Update an existing task's details. Only provided fields are changed. Supports updating tags, reminders, recurrence, checklist items, and more.",
        "parameters": {
          "type": "object",
          "properties": {
            "project_id": {
              "type": "string",
              "description": "The project ID containing the task"
            },
            "task_id": {
              "type": "string",
              "description": "The unique identifier of the task to update"
            },
            "title": {
              "type": "string",
              "description": "New task title"
            },
            "content": {
              "type": "string",
              "description": "New task description / notes (Markdown supported)"
            },
            "desc": {
              "type": "string",
              "description": "New calendar description — shown in calendar views."
            },
            "start_date": {
              "type": "string",
              "description": "New start date. Supports relative dates like 'today' or 'tomorrow at 8 AM'."
            },
            "due_date": {
              "type": "string",
              "description": "New due date. Supports relative dates like 'today' or 'tomorrow at 8 AM'."
            },
            "priority": {
              "type": "integer",
              "minimum": 0,
              "maximum": 4,
              "description": "New priority level (0=none, 1=low, 2=medium, 3=high, 4=critical)"
            },
            "is_all_day": {
              "type": "boolean",
              "description": "If true, the task is an all-day task (no specific time)."
            },
            "tags": {
              "type": "array",
              "items": { "type": "string" },
              "description": "New list of tag names. Replaces existing tags entirely, e.g. ['work', 'urgent']."
            },
            "time_zone": {
              "type": "string",
              "description": "New time zone, e.g. 'America/New_York', 'Europe/London'."
            },
            "parent_id": {
              "type": "string",
              "description": "Parent task ID — set to convert this task into a subtask. Must be in the same project."
            },
            "reminders": {
              "type": "array",
              "items": { "type": "string" },
              "description": "New alert reminders using iCalendar TRIGGER format. 'TRIGGER:PT0S' = at the due time, 'TRIGGER:PT-15M' = 15 min before, 'TRIGGER:PT-1H' = 1 hour before, 'TRIGGER:P1D' = 1 day before. Replaces existing reminders."
            },
            "repeat_flag": {
              "type": "string",
              "description": "New recurrence rule. 'FREQ=DAILY;INTERVAL=1' (daily), 'FREQ=WEEKLY;INTERVAL=1' (weekly), 'FREQ=MONTHLY;INTERVAL=1' (monthly). Set to empty string to remove recurrence."
            },
            "sort_order": {
              "type": "integer",
              "description": "New sort position within the project. Lower values appear higher."
            },
            "items": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "id": { "type": "string", "description": "Existing item ID (for updating an existing checklist item)" },
                  "title": { "type": "string", "description": "Checklist item title" },
                  "start_date": { "type": "string", "description": "Item start date (ISO 8601 or relative)" },
                  "is_all_day": { "type": "boolean", "description": "All-day flag for the item" },
                  "sort_order": { "type": "integer", "description": "Sort order within the checklist" },
                  "status": { "type": "integer", "description": "0=active, 2=completed" },
                  "completed_time": { "type": "string", "description": "Completion timestamp (ISO 8601), set when status=2" }
                },
                "required": ["title"]
              },
              "description": "Checklist items (subtasks). Replaces existing items entirely. Each item has a title and optional date/sort/status."
            }
          },
          "required": ["project_id", "task_id"]
        },
        "requirements": ["network"],
        "permission_policy": "ask"
      },
      {
        "id": "complete_task",
        "description": "Mark a task as complete",
        "parameters": {
          "type": "object",
          "properties": {
            "project_id": {
              "type": "string",
              "description": "The project ID containing the task"
            },
            "task_id": {
              "type": "string",
              "description": "The unique identifier of the task"
            }
          },
          "required": ["project_id", "task_id"]
        },
        "requirements": ["network"],
        "permission_policy": "ask"
      },
      {
        "id": "delete_task",
        "description": "Delete a task from a project",
        "parameters": {
          "type": "object",
          "properties": {
            "project_id": {
              "type": "string",
              "description": "The project ID containing the task"
            },
            "task_id": {
              "type": "string",
              "description": "The unique identifier of the task"
            }
          },
          "required": ["project_id", "task_id"]
        },
        "requirements": ["network"],
        "permission_policy": "ask"
      },
      {
        "id": "move_task",
        "description": "Move a task from one project to another.",
        "parameters": {
          "type": "object",
          "properties": {
            "task_id": {
              "type": "string",
              "description": "The unique identifier of the task to move"
            },
            "from_project_id": {
              "type": "string",
              "description": "The project ID the task currently belongs to"
            },
            "to_project_id": {
              "type": "string",
              "description": "The destination project ID"
            }
          },
          "required": ["task_id", "from_project_id", "to_project_id"]
        },
        "requirements": ["network"],
        "permission_policy": "ask"
      },
      {
        "id": "get_completed_tasks",
        "description": "Retrieve tasks that have been completed within a time range. Useful for reviewing productivity or finding recently finished work.",
        "parameters": {
          "type": "object",
          "properties": {
            "project_ids": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Filter to specific project IDs. If omitted, searches all projects."
            },
            "start_date": {
              "type": "string",
              "description": "Start of the time range (inclusive). Accepts ISO 8601 or relative phrases like '7 days ago'."
            },
            "end_date": {
              "type": "string",
              "description": "End of the time range (inclusive). Accepts ISO 8601 or relative phrases like 'today'."
            }
          },
          "required": []
        },
        "requirements": ["network"],
        "permission_policy": "auto"
      },
      {
        "id": "filter_tasks",
        "description": "Filter tasks using advanced criteria: project scope, date range, priority, tags, and status. Uses the TickTick server-side filter API for efficient querying.",
        "parameters": {
          "type": "object",
          "properties": {
            "project_ids": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Filter to specific project IDs. If omitted, searches all projects."
            },
            "start_date": {
              "type": "string",
              "description": "Filter tasks with startDate >= this value. Accepts ISO 8601 or relative phrases."
            },
            "end_date": {
              "type": "string",
              "description": "Filter tasks with startDate <= this value. Accepts ISO 8601 or relative phrases."
            },
            "priority": {
              "type": "array",
              "items": { "type": "integer" },
              "enum": [0, 1, 3, 5],
              "description": "Filter by priority on the TickTick API scale: 0=none, 1=low, 3=medium, 5=high. Can specify multiple values."
            },
            "tags": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Filter tasks that contain ALL of the specified tags."
            },
            "status": {
              "type": "array",
              "items": { "type": "integer" },
              "enum": [0, 2],
              "description": "Filter by status: 0=active (open), 2=completed. Can specify both to get all."
            }
          },
          "required": []
        },
        "requirements": ["network"],
        "permission_policy": "auto"
      },
      {
        "id": "get_tasks_due_today",
        "description": "List all tasks due today (in the user's local timezone)",
        "parameters": {
          "type": "object",
          "properties": {
            "project_id": {
              "type": "string",
              "description": "Optional: limit to a specific project"
            }
          },
          "required": []
        },
        "requirements": ["network"],
        "permission_policy": "auto"
      },
      {
        "id": "get_overdue_tasks",
        "description": "List all tasks that are past their due date and still active",
        "parameters": {
          "type": "object",
          "properties": {
            "project_id": {
              "type": "string",
              "description": "Optional: limit to a specific project"
            },
            "max_days_overdue": {
              "type": "integer",
              "minimum": 1,
              "maximum": 365,
              "description": "Maximum number of days overdue (default: no limit)"
            }
          },
          "required": []
        },
        "requirements": ["network"],
        "permission_policy": "auto"
      }
    ],
    "routes": []
  },
  "config": {
    "fields": []
  },
  "web": {},
  "artifact_handler": false
}
""".trimmingCharacters(in: .whitespacesAndNewlines)

// MARK: - Plugin Context

/// Per-instance plugin state. The TickTick plugin is stateless across
/// calls (every tool builds its own HTTP client from the injected
/// secrets), so this just owns the tool structs.
private class PluginContext: @unchecked Sendable {
    let connectAccount = ConnectAccountTool()
    let listProjects = ListProjectsTool()
    let getProject = GetProjectTool()
    let createProject = CreateProjectTool()
    let updateProject = UpdateProjectTool()
    let deleteProject = DeleteProjectTool()
    let listTasks = ListTasksTool()
    let searchTasks = SearchTasksTool()
    let createTask = CreateTaskTool()
    let getTask = GetTaskTool()
    let updateTask = UpdateTaskTool()
    let completeTask = CompleteTaskTool()
    let deleteTask = DeleteTaskTool()
    let moveTask = MoveTaskTool()
    let getCompletedTasks = GetCompletedTasksTool()
    let filterTasks = FilterTasksTool()
    let getTasksDueToday = GetTasksDueTodayTool()
    let getOverdueTasks = GetOverdueTasksTool()
}

// MARK: - API Implementation

nonisolated(unsafe) var pluginAPI = PluginEntry.makeAPI(
    version: OsrABIVersion.v2,
    init: {
        let ctx = PluginContext()
        return Unmanaged.passRetained(ctx).toOpaque()
    },
    destroy: { ctxPtr in
        guard let ctxPtr = ctxPtr else { return }
        Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
    },
    getManifest: { _ in
        osrMakeCString(ticktickManifestJSON)
    },
    invoke: { ctxPtr, typePtr, idPtr, payloadPtr in
        guard let ctxPtr = ctxPtr,
              let typePtr = typePtr,
              let idPtr = idPtr,
              let payloadPtr = payloadPtr
        else { return nil }

        let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
        let type = String(cString: typePtr)
        let id = String(cString: idPtr)
        let payload = String(cString: payloadPtr)

        guard type == "tool" else {
            return osrMakeCString(
                Envelope.failure(.invalidArgs, "Unknown capability type: \(type)")
            )
        }

        let result: String
        switch id {
        case ctx.connectAccount.name:      result = ctx.connectAccount.run(args: payload)
        case ctx.listProjects.name:        result = ctx.listProjects.run(args: payload)
        case ctx.getProject.name:          result = ctx.getProject.run(args: payload)
        case ctx.createProject.name:       result = ctx.createProject.run(args: payload)
        case ctx.updateProject.name:       result = ctx.updateProject.run(args: payload)
        case ctx.deleteProject.name:       result = ctx.deleteProject.run(args: payload)
        case ctx.listTasks.name:           result = ctx.listTasks.run(args: payload)
        case ctx.searchTasks.name:         result = ctx.searchTasks.run(args: payload)
        case ctx.createTask.name:          result = ctx.createTask.run(args: payload)
        case ctx.getTask.name:             result = ctx.getTask.run(args: payload)
        case ctx.updateTask.name:          result = ctx.updateTask.run(args: payload)
        case ctx.completeTask.name:        result = ctx.completeTask.run(args: payload)
        case ctx.deleteTask.name:          result = ctx.deleteTask.run(args: payload)
        case ctx.moveTask.name:            result = ctx.moveTask.run(args: payload)
        case ctx.getCompletedTasks.name:   result = ctx.getCompletedTasks.run(args: payload)
        case ctx.filterTasks.name:         result = ctx.filterTasks.run(args: payload)
        case ctx.getTasksDueToday.name:    result = ctx.getTasksDueToday.run(args: payload)
        case ctx.getOverdueTasks.name:     result = ctx.getOverdueTasks.run(args: payload)
        default:
            result = Envelope.failure(.notFound, "Unknown tool: \(id)")
        }

        return osrMakeCString(result)
    },
    onConfigChanged: { ctxPtr, keyPtr, valuePtr in
        // Auto-trigger OAuth when all credentials are saved and no token exists.
        // This runs when the user enters client_id/client_secret/redirect_uri
        // in the plugin config UI — no need to ask the LLM to call connect_account.
        guard let keyPtr, let valuePtr else { return }
        let key = String(cString: keyPtr)
        let value = String(cString: valuePtr)

        // Only react to credential-related keys
        guard ["client_id", "client_secret"].contains(key),
              !value.isEmpty
        else { return }

        // Cache the value that just changed
        OAuthCredentialCache.shared.set(key: key, value: value)

        // Don't start if a token already exists
        if HostBridge.shared.configGet("access_token") != nil { return }

        // Check if we have both credentials (redirect_uri is hardcoded)
        guard let clientId = OAuthCredentialCache.shared.clientId,
              let clientSecret = OAuthCredentialCache.shared.clientSecret,
              !clientId.isEmpty, !clientSecret.isEmpty
        else { return }

        // Run OAuth in the background so we don't block the config callback
        DispatchQueue.global(qos: .userInitiated).async {
            OAuthFlow.run(
                clientId: clientId,
                clientSecret: clientSecret,
                redirectUri: "http://127.0.0.1:8080/"
            )
        }
    }
)

// MARK: - OAuth Auto-Connect

/// Thread-safe cache for OAuth credentials received via `on_config_changed`.
/// The host calls this callback when a config field or secret changes, passing
/// the key and new value. We cache them and trigger OAuth when all three are set.
final class OAuthCredentialCache: @unchecked Sendable {
    static let shared = OAuthCredentialCache()
    private let lock = NSLock()
    private var _clientId: String?
    private var _clientSecret: String?

    var clientId: String? { lock.lock(); defer { lock.unlock() }; return _clientId }
    var clientSecret: String? { lock.lock(); defer { lock.unlock() }; return _clientSecret }

    func set(key: String, value: String) {
        lock.lock(); defer { lock.unlock() }
        switch key {
        case "client_id":      _clientId = value
        case "client_secret":  _clientSecret = value
        default: break
        }
    }
}

/// Shared OAuth flow runner — used by both `on_config_changed` (auto-connect)
/// and the `connect_account` tool. Opens the browser, starts a local HTTP
/// server, exchanges the code, and stores the token.
enum OAuthFlow {
    static func run(clientId: String, clientSecret: String, redirectUri: String) {
        // Double-check: don't start if a token was stored since we were queued
        if HostBridge.shared.configGet("access_token") != nil { return }

        HostBridge.shared.log(1, "ticktick: auto-connecting OAuth after credentials saved")

        guard let redirectURL = URL(string: redirectUri), let port = redirectURL.port else {
            HostBridge.shared.log(3, "ticktick: invalid redirect_uri: \(redirectUri)")
            return
        }

        let useDida365 = (HostBridge.shared.configGet("use_dida365") == "true")
        let authHost = useDida365 ? "https://dida365.com" : "https://ticktick.com"
        let path = redirectURL.path.isEmpty ? "/" : redirectURL.path

        var authComponents = URLComponents(string: "\(authHost)/oauth/authorize")!
        authComponents.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "scope", value: "tasks:read tasks:write"),
            URLQueryItem(name: "state", value: "osaurus-ticktick-auto"),
            URLQueryItem(name: "response_type", value: "code"),
        ]
        guard let authURL = authComponents.url else {
            HostBridge.shared.log(3, "ticktick: could not build auth URL")
            return
        }

        let oauthDelegate = OAuthCallbackDelegate()
        let server = LocalHTTPServer(port: port, path: path) { queryParams in
            if let code = queryParams["code"] {
                oauthDelegate.authCode = code
                oauthDelegate.signal()
                return "<html><body style='font-family:-apple-system;padding:40px;text-align:center;'><h1>TickTick connected!</h1><p>You can close this tab and return to Osaurus.</p></body></html>"
            }
            if let error = queryParams["error"] {
                oauthDelegate.authError = error
                oauthDelegate.signal()
                return "<html><body style='font-family:-apple-system;padding:40px;text-align:center;'><h1>Authorization failed</h1><p>\(error)</p></body></html>"
            }
            return "<html><body><h1>Waiting...</h1></body></html>"
        }

        guard server.start() else {
            HostBridge.shared.log(3, "ticktick: could not start local server on port \(port)")
            return
        }

        #if canImport(AppKit)
        DispatchQueue.main.async { NSWorkspace.shared.open(authURL) }
        #endif

        oauthDelegate.waitForCallback(timeout: 180)
        server.stop()

        if let error = oauthDelegate.authError {
            HostBridge.shared.log(3, "ticktick: OAuth auto-connect failed: \(error)")
            return
        }
        guard let code = oauthDelegate.authCode else {
            HostBridge.shared.log(3, "ticktick: OAuth auto-connect timed out")
            return
        }

        // Exchange code for token
        var tokenRequest = URLRequest(url: URL(string: "\(authHost)/oauth/token")!)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedRedirect = redirectUri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectUri
        tokenRequest.httpBody = "code=\(code)&client_id=\(clientId)&client_secret=\(clientSecret)&grant_type=authorization_code&redirect_uri=\(encodedRedirect)".data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        let box = TokenResponseBox()
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: tokenRequest) { data, response, error in
            box.data = data
            box.error = error
            if let http = response as? HTTPURLResponse { box.status = http.statusCode }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        session.invalidateAndCancel()

        guard let respData = box.data,
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            let body = box.data.flatMap { String(data: $0, encoding: .utf8) } ?? "(empty)"
            HostBridge.shared.log(3, "ticktick: token exchange failed (HTTP \(box.status)): \(body)")
            return
        }

        HostBridge.shared.configSet("access_token", accessToken)
        if let expiresIn = json["expires_in"] as? Int {
            HostBridge.shared.configSet("token_expires_in", String(expiresIn))
        }
        HostBridge.shared.log(1, "ticktick: OAuth auto-connect succeeded, token stored")
    }
}

// MARK: - Entry points

/// v2 entry point: the host injects its API table here first, captured
/// into `HostBridge.shared`. New hosts try this symbol first.
@_cdecl("osaurus_plugin_entry_v2")
public func osaurus_plugin_entry_v2(_ host: UnsafeRawPointer?) -> UnsafeRawPointer? {
    PluginEntry.enterV2(host, api: &pluginAPI)
}

/// v1 entry point: legacy fallback for old Osaurus builds.
@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
    PluginEntry.enterV1(api: &pluginAPI)
}
