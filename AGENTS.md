# Project workflow for Operation Long Haul

Project tracking uses YouTrack Cloud: project `Homelab`, issue prefix `HOMELAB`. The YouTrack MCP integration is connected. Use its tools to read live project data and perform authorized issue updates. If the connection is unavailable, say so explicitly and do not treat local docs as current tracker state. Use `docs/build/` and `docs/build/work-breakdown.md` for scope and acceptance criteria. The tracker is the source of truth for status, assignee, priority, and existing tickets.

## Model and naming

- Preserve phase numbers in epic and issue titles.
- Issue types are Epic, Story, Task, Spike, and Bug. Link children to their parent epic or story. Tier grouping and workflow statuses must be checked against the live project before writing.
- Use Spike for a time-boxed investigation, Story for an independently verifiable outcome, and Task for a concrete step.
- The workflow field is `Stage` (not `State`). Verified values are Backlog, Ready, In Progress, In Review, Blocked, and Done; priorities are Expedited, Important, Standard, and Unspecified. Refresh the live project field schema before writing; these values may change.

## Planning and changes

- For "what next", read the relevant epic, applicable open children, blockers, priorities, and acceptance criteria. Recommend a specific existing issue ID and explain its prerequisites and readiness. Say when live data is unavailable.
- Before creating work, search the tracker for existing titles and phase IDs. Draft concise scope and measurable acceptance criteria from the docs.
- When the user asks to discuss tickets first, create the requested container and continue the discussion; create tickets when the user says to proceed. Otherwise perform requested ticket writes directly and report their IDs.
- Never place credentials in this repository, issue descriptions, or tool output.
