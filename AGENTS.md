# Huly workflow for Operation Long Haul

Use the configured `huly` MCP server when a user asks about live Huly work. The workspace is `Homelab`; the Tracker project identifier is `HOMEL`. Use the build documents in `docs/build/` and `huly/work-breakdown.md` for scope and acceptance criteria. Huly is the source of truth for current status, assignee, priority, and existing tickets.

## Model and naming

- In Huly Tracker, a milestone is a scheduling object and an issue is a ticket. Do not assume it is a parent issue.
- The work breakdown maps Tier to milestone and phase to epic. Preserve phase numbers in issue titles. Associate issues with the corresponding milestone and use issue parent links for story/task nesting where supported.
- The Classic Tracker project type now has Task, Story, Spike, and Bug task types, each using Backlog, Todo, In Progress, Done, and Canceled. Use these task types for corresponding tickets and avoid the default Issue type. Huly Cards `Types` are a different model. Check current Tracker configuration if a type write fails.
- Avoid creating Card, File, Document, Thread, Direct, Poll, or User profile objects for the task workflow.

## Planning and changes

- For "what next", read the relevant milestone or epic, all applicable open child issues, blockers, priorities, and acceptance criteria. Recommend a specific existing issue ID, explain its prerequisites and why it is ready, and say when the available data is insufficient.
- For new work, search Huly for existing titles and phase IDs first. Use the docs to draft concise scope and measurable acceptance criteria. Use Spike for a time-boxed investigation, Story for an independently verifiable outcome, and Task for a concrete step, subject to available Tracker task types.
- When the user asks to discuss tickets first, create the requested container and continue the discussion; create tickets when the user says to proceed. Otherwise perform requested ticket writes directly and report the created IDs. Do not require a separate review unless the user asks.
- Never place Huly credentials in this repository, Huly issue descriptions, or tool output.
