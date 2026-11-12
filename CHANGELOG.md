# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with versions numbered
`<major>.<minor>` and a two-digit minor (v1.00, v1.01 ... v1.10) to match the exe file names.

## [Unreleased]

## [1.01] - 2026-11-12

### Added
- **Configure** window for each container (button, right-click menu or Ctrl+E):
  - lists its environment variables and where each value is kept (`.env`, the compose
    file or this PC), with passwords and keys hidden until you tick **Show**,
  - changes values: those from `.env` are saved in `.env` (with a note when other services
    share the same variable), values written in the compose file are changed in place,
  - **Move to .env** takes a value out of the compose file, stores it in `.env` and puts a
    `${NAME}` reference in its place,
  - **Add variable** adds a new one, with its value in `.env`,
  - new `.env` values can also be added to the `Env_*` templates next to the compose file,
  - **Save and recreate** recreates the container so it uses the new values,
  - **Folders** opens any of its host folders, **Shell** opens a command prompt inside the
    running container, plus **Web page** and **Logs**.
- Backups of the compose file and `.env` are saved in
  `%APPDATA%\Docker Container Manager\Backups\<project>\` before each change.

### Changed
- The app now changes the compose file and `.env` when you save in a Configure window.
  Nothing else edits them.

## [1.00] - 2026-11-11
First release.

### Added
- One window that lists every service in a Docker Compose file with its live state
  (running, healthy, unhealthy, stopped, exited with an error, not created), how long
  it has been up, its web page, its image and a note when something needs doing.
- Reads the compose file through `docker compose config`, so `.env` values, anchors and
  overrides are applied the way Docker applies them. The app never edits the file.
- **Groups** from a label on each service (`home.group=Music`), shown in a Groups pane
  with running/total counts and a red dot when something in the group has a problem.
  Services without the label are listed under **Ungrouped**.
- **Start, Stop, Restart, Update and Recreate** for the selected containers, and Start,
  Stop and Update for a whole group or everything. Update pulls the newest images,
  recreates the containers that changed (stopped ones stay stopped) and can remove
  unused images afterwards.
- **Follows the compose file as it changes.** Saving it (or `.env`) re-reads it: new
  services appear, removed services that still have a container are listed under
  **Not in compose file** with Stop and Remove, and edited services are marked
  "Changed" until **Apply changes** recreates them.
- Web page link for each container, from its first published port or a `home.url`
  label (`home.url=none` hides it). `home.description` sets a tooltip.
- **Logs window** per container: last 100 to 5,000 lines or all, follow, timestamps,
  search, wrap, copy and save.
- **Check compose file**: reads the file as text (so it works even when Docker rejects
  it) and lists errors, warnings and suggestions: broken `${...}` variables, tabs, uneven
  or wrong indents, missing spaces after `:` or `-`, host ports used twice, duplicate
  service or container names, unknown settings, `depends_on` naming a missing service,
  variables missing from `.env`, missing host folders, services without a group,
  unpinned images and passwords written in the file. Double-click a result to open the
  file at that line in VS Code, Notepad++ or Sublime Text. The header button shows the
  number of errors and warnings, updated whenever the file is saved.
- **Activity log** with every docker command and its output, and Cancel for the one
  running.
- Banners when Docker isn't running (with **Start Docker Desktop**), when the compose
  file has an error (the last good list stays), and when a folder has `Env_*` templates
  but no `.env` (**Create .env** copies the one you pick).
- Recent compose files list to switch between projects, and **Edit**, **.env** and
  **Folder** buttons.
- Tray icon with Start and Stop for each group, optional minimise to tray, and a notification
  when a job finishes while the window is hidden.
- Search (Ctrl+F), state filter (running, stopped, problems, changed), F5 refresh,
  Ctrl+L logs, Enter or double-click to open the web page.
- Settings for the label prefix, status refresh interval, editor, image prune after
  Update, asking before stopping a group and minimise to tray, saved in
  `%APPDATA%\Docker Container Manager\settings.json`.
- About box with what's new, Docker and Compose versions and the settings path.
- `-ComposeFile <path>` to open a particular compose file.
- `Build-Exe.cmd` builds a self-contained `Docker Container Manager v1.00.exe` with the
  icon and logo built in.
- Demo compose project in `docs\demo\` for trying the app.
- Docker Container Manager icon (three stacked shipping containers).
