# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with versions numbered
`<major>.<minor>` and a two-digit minor (v1.00, v1.01 ... v1.10) to match the exe file names.

## [Unreleased]

## [1.09] - 2026-11-13

### Changed
- **Compose file** list in the header: the last entry, **Other compose file...**, opens the same picker as the **Compose file...**
  button (cancel goes back to the file you had). Right-click any other entry for **Remove from list**, which only takes it off the
  list in settings.json and never touches the file. The current file is shown in bold.
- **Settings**: the editor **Check** no longer only looks in the two usual VS Code folders. It also uses where Windows says VS Code
  and Notepad++ are installed (App Paths, the installed programs list) and VS Code's `code` command on the PATH.

### Added
- **Settings**: under the editor **Check** result, **Choose another editor...** opens a file picker for any program, wherever it is.
  **Browse...** and the link both start in the folder of the current or suggested editor.
- **Group automatically**: **Save groups** opens a small **Saving groups** box with a progress bar and a line for each step:
  adding the group labels (n of N), checking a test copy with Docker, making the backup, writing the compose file, reading it back
  to check it, and reloading the list. The app keeps responding while it works. When it's done the box closes and the Finished box
  says so. If a step fails, the box says why, with a **Close** button, and the compose file is left as it was (if the saved file
  doesn't read back right, the original is put back from the backup).

## [1.08] - 2026-11-13

### Added
- **Settings**: a **Check** button beside the editor path. It says whether the program is there (with its name and version) or what's wrong
  (nothing there, a folder, not an .exe, .cmd or .bat). When it isn't right it offers the first editor found: Visual Studio Code
  (Program Files or your user folder), Notepad++, then Notepad. **Use ...** fills the box; it's saved when you press **Save**.
  `%VARIABLES%` such as `%LOCALAPPDATA%` now work in the editor path.

### Changed
- **Disk usage**: the clean-up buttons are smaller, with an icon and a short label, and sit in each card under the space they free:
  **Clean unnamed** and **Clean unused...** (Images), **Remove unused...** (Volumes, in red because it deletes data) and
  **Clean build cache**; **Clean unused networks** stays at the bottom. Each is off when there's nothing to free, and the
  tooltip says exactly which docker command it runs. The questions before each one are unchanged (volumes still asks twice).
  The window's smallest width is now 780 so the buttons always fit.
- **About** is split into sections that open and close with a click, in the same style as the group headers: **About** (open),
  **What's new** with a section per version showing its number of changes (only the newest open), **This PC** and
  **Keyboard shortcuts** (one per line, now including F1). The window moves up if an opened section would push it off the screen.

### Fixed
- **About**: the window could grow taller than the screen as the What's new list got longer, hiding the **Close** button.
  It's now no taller than 85% of the screen's work area; the middle part scrolls (with the app's light or dark scroll bar),
  while the header and the bottom row (link, copyright, **Close**) stay in view.

## [1.07] - 2026-11-13

### Fixed
- Export: the **Light / dark** switch was small and hard to see above the header. It's now bigger and sits in the
  blue header at the top right of the page.

## [1.06] - 2026-11-13

### Added
- **Source page** for each container (**Source** button, right-click menu): opens its project page from a `home.source` label,
  your own source links file (`source-links.txt` in the settings folder, kept on this PC), the image's own source label or a
  guess from the image name (GitHub, GitLab, Docker Hub). The tooltip shows the page. **Edit source links...** in the menu and Settings.
- **Export...**: saves the list as one self-contained web page (HTML) with icons, states, web pages, source pages and notes,
  in the app's light or dark theme (with a switch at the top of the page) and ready to print. It can save only the containers shown.
- **Help** (button and F1): a guide to the whole app, with selectable text and a link to the README.

## [1.05] - 2026-11-13

### Added
- **Group automatically (n)...** in the bar above the list when some services have no group label. It suggests a group for each
  from its image and service name, reusing the groups already in the file, and shows the list to change before anything is saved.
  Save adds one group label to each of those services (list or map style, as in the file), checks the result with Docker,
  backs up the compose file and saves it. Services that already have a group are never touched.
- **Portainer** button: opens Portainer on the chosen machine, starts it when it's stopped, or installs it
  (portainer/portainer-ee on ports 8000 and 9000) after showing the docker run line. Right-click it to update Portainer
  (keeping the data folder it uses now) or change its data folder.
- **Portainer data** folder for each machine in the Machines window (and for This PC in the settings). Portainer Business asks
  for its licence key in its own page; the app never stores it.
- **Finished** box: when Docker has finished and the progress window isn't showing (you pressed **Hide**, or it's turned
  off), a box in the bottom-right corner of the screen says Done or Didn't work, with the last thing Docker said and
  **Show log** for failures. It stays on top without taking the focus, closes itself after 10 seconds on success, and can be
  turned off in Settings.

### Fixed
- The **Stop group** question didn't name the group (it read "in ?").
- A service with a single label in list form had its labels read wrongly when the app checked a changed file.

## [1.04] - 2026-11-13

### Changed
- Each machine remembers its own compose file on this PC, so picking a machine also picks the file
  you use with it.
- With another machine picked, the compose file box reads **Send from:**, with a tooltip saying that
  machine runs its own copy and this file is what Send copies there.
- Captions above the two lists at the top: **Containers on** (the machine) and **Compose file**, which
  becomes **Master copy here, sent to NAS** when another machine is picked.
- The selected container's row is highlighted more strongly (the line at its start stays).
- The **Send** button sits right next to the compose file list it sends from.
- The Image column has more room (State and Since are a little narrower), and hovering over an image shows its full name.
- The compose file path and the project each have their own line under the title, wide enough for a NAS path.

### Fixed
- Settings window: the **Show app icons** option and the editor path were cut off. The window is
  wider and the option text is shorter.
- The project name under the title was cut off. It now has its own line under the compose file path.
- Selected and hovered rows weren't highlighted in the container list and the Configure, Check and Disk lists; they now are.
- The Note column was too narrow for "Changed: recreate to apply"; it's wider and shows the full note as a tooltip.
- In the container list, the Image column now fills the spare width (it was stuck at its narrowest), so full image names show; the other columns no longer start squeezed.

## [1.03] - 2026-11-12

### Added
- **Machines.** A list at the top left switches between This PC and other machines that run the
  same compose file (a Linux laptop, a VM, a Synology NAS). The app reaches them with Windows'
  own `ssh.exe` and an SSH key, and runs every docker command there: status, start, stop,
  update, logs, shell and disk usage. Web pages open on that machine's address.
- **Machines window** to add, change and remove machines, with **Test connection** and
  **SSH key help**.
- **Progress window** while Docker starts, stops, updates or sends: the steps, a progress bar and
  Docker's output, with Cancel. It closes itself 10 seconds after success (the Close button counts down) and stays open on
  failure. Can be turned off in Settings.
- **Project** name per machine, for stacks started under another name (Synology Container
  Manager uses the project's name). Test connection lists the running projects.
- **Send** copies the compose file and the machine's `Env_` file (as `.env`) to the machine,
  after keeping dated `.bak` copies of the files already there. Nothing is restarted.

### Changed
- Works with Docker Compose before 2.24 (as on Synology), which lacks `--no-env-resolution`.
- With another machine picked, Configure and the **.env** button use that machine's `Env_` file,
  and **Save and recreate** sends it before recreating.

## [1.02] - 2026-11-12

### Added
- **Dark mode.** Settings > Theme: System (follows the Windows app setting), Light or Dark.
  Dark mode includes dark text boxes, drop-down lists, menus, scroll bars and title bars.
  A change applies the next time the app starts.
- **Card view.** The **Cards** button (or Ctrl+T) switches between the list and cards. Each card
  shows the icon, state, uptime, note and web page, with Start or Stop, Configure and Logs
  buttons. The choice is remembered.
- **App icons** next to each container. They're found from the image name (for example
  `lscr.io/linuxserver/sonarr` gives `sonarr`), downloaded once from the
  [dashboard-icons](https://github.com/homarr-labs/dashboard-icons) project and kept in
  `%LOCALAPPDATA%\Docker Container Manager\Icons`. Containers without one get a letter in
  their group colour. A `home.icon` label picks another icon (a name, a web address or a
  picture file). Can be turned off in Settings.
- **Group colours** in the Groups pane, the list's group headings and the cards. A `home.color`
  label on any service of a group sets that group's colour.
- **Check for updates** in the group bar. It asks each image's registry (Docker Hub, GHCR,
  lscr.io and others) for the newest digest of the tag and compares it with the image on this
  PC, without downloading anything. Containers with a newer image show **Update available**,
  and the state list has an **Updates available** filter. It also runs when the app starts,
  at most every 12 hours (can be turned off in Settings).
- **Disk usage** window (header button): space used by images, containers, volumes and the
  build cache, every image with its size and which containers use it, and buttons to remove
  unnamed images, remove unused images, clear the build cache, remove unused networks and remove unused
  volumes (it lists the volumes and asks twice, because their data is deleted for good).
- **Tidy spacing** in the Check window re-indents the compose file to two spaces per level.
  It is only saved when `docker compose config` reads the tidied file exactly the same as the
  original, and a backup is kept first.

### Changed
- The list's group headings have a colour bar and a simpler expand arrow.
- The window opens wide enough for the header buttons to fit on one line (when the screen allows).
- The window opens at 1650 x 1080 by default, and the Activity log starts taller (221).
- The Activity log's height is remembered when you drag the divider, like the window size.

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
