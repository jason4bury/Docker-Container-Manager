<p align="center">
  <img src="assets/Docker-Container-Manager.png" alt="Docker Container Manager icon" width="128">
</p>

# Docker Container Manager

Run and organise the containers in your Docker Compose file, in groups, from one Windows window.

![Version](https://img.shields.io/badge/version-v1.11-blue) ![Platform](https://img.shields.io/badge/platform-Windows-0078D6) ![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE) ![Licence](https://img.shields.io/badge/licence-MIT-green) ![Last commit](https://img.shields.io/github/last-commit/jason4bury/Docker-Container-Manager)

## ✨ Features

A PowerShell/WPF front end for `docker compose`, made for compose files with dozens or hundreds of services.

- **Every service at a glance**: live state (running, healthy, unhealthy, stopped, exited with an error, not created), how long it's been up, its web page, its image and a note when something needs doing. The list refreshes every few seconds.
- **Groups that live in the compose file.** Add a `home.group` label to a service and it's listed under that group, with running/total counts and a red dot when something in the group has a problem. The labels travel with the file, so every machine you copy it to shows the same groups.
- **Group automatically**: suggests a group for every service that has none, from its image name (sonarr and radarr under Downloads, postgres under Databases, and so on), reusing the groups already in the file, and your own **My groups** list first. You check and change the list before anything is saved, and a **Saving groups** box shows each step of the save.
- **Start, Stop, Restart, Update and Recreate** for one container, a selection, a whole group or everything. Update pulls the newest images and recreates what changed, keeps stopped containers stopped, and can tidy away unused images afterwards.
- **Keeps up with the compose file.** Save the file (or `.env`) and it's read again straight away:
  - new services appear,
  - removed services that still have a container are listed under **Not in compose file**, ready to stop or remove,
  - edited services are marked **Changed** until you press **Apply changes**.
- **One click to a container's web page**, from its first published port or a `home.url` label.
- **Logs window** with follow, timestamps, search, copy and save.
- **Check compose file**: finds broken `${...}` variables, spacing mistakes (tabs, uneven indents, a setting indented into the wrong section, a missing space after `:` or `-`), host ports used twice, duplicate names, `depends_on` pointing at nothing, values missing from `.env`, missing folders, services without a group, unpinned images and passwords written in the file. Double-click a result to open the file at that line. The header button shows how many errors and warnings there are.
- **Activity log** showing every docker command it runs and what Docker said, with Cancel.
- **Progress window** while containers start, stop or update, with Docker's output as it happens. It closes itself 10 seconds after the work succeeds, counting down on its Close button.
- **Finished box**: if you pressed **Hide** on the progress window (or turned it off), a box in the bottom-right corner says when Docker has finished. Success closes itself after 10 seconds; a failure shows what Docker said, with **Show log**, and stays until closed.
- **Tray icon** with Start and Stop for each group.
- **Helpful banners** when Docker isn't running (with **Start Docker Desktop**), when the compose file has an error (the last good list stays), or when a folder has `Env_*` templates but no `.env` yet.
- **Configure** a container: change its environment variables, API keys and passwords, move values written in the compose file into `.env`, add new variables, and open its host folders, a shell inside it, its web page or logs. **Save and recreate** restarts it with the new values.
- **Check for updates**: shows which containers have a newer image on Docker Hub, GHCR, lscr.io and other registries, without downloading anything. It also checks on its own when the app starts (at most every 12 hours).
- **Disk usage**: how much space images, containers, volumes and the build cache take, which containers use each image, and a small clean-up button in each card next to the space it frees (old or unused images, the build cache, unused networks and, in red, after listing them and asking twice, unused volumes). Each button is off when there's nothing to free, and its tooltip says exactly what it runs.
- **Tidy spacing**: re-indents the compose file to two spaces per level, and only saves it when Docker reads the result exactly the same as before.
- **List or cards**, **dark mode**, **app icons** and a **colour for each group**.
- **Source page**: right-click a container (or press **Source**) to open its project page on GitHub, GitLab or Docker Hub, from a label, your own list of links, the image itself or a guess from its name.
- **My groups**: your own list of which group each container goes in, kept on your PC and ready from the start, so a new compose file gets the groups you always use.
- **Export**: saves the list as one web page (HTML) to keep, print or send, in light or dark with a switch at the top.
- **Help** (F1): a guide to every part of the app inside it.
- **About**: the version, what's new in each version (in sections that open and close), this PC's Docker and Compose versions and the keys.
- **Portainer**: one button opens Portainer on the chosen machine, starts it when it's stopped, or installs it after showing the `docker run` line.
- **Other machines**: manage the same compose file on a Linux laptop, a VM or a Synology NAS over SSH, from the machine list at the top. **Send** copies the compose file and that machine's `Env_` file (as `.env`) across.
- Only changes the compose file or `.env` when you save in a Configure window, tidy the spacing or save groups, and backs both up first. Nothing is installed; settings are in `%APPDATA%`. The exe is self-contained.

## 🖼️ Screenshots

![Docker Container Manager main window](docs/screenshots/main-window.png)

The screenshot uses the demo project in [`docs/demo/`](docs/demo/docker-compose.yml).

## 📋 Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (or PowerShell 7).
- For other machines: the Windows OpenSSH Client (installed by default on Windows 10 1809 and later) and Docker with Compose v2 on the machine.
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (or another Docker engine that `docker.exe` can reach) with Compose v2.20 or later.
- A `docker-compose.yml` (or `compose.yaml`).

## 📦 Installation

**Exe:** download `Docker Container Manager v1.11.exe` from the [latest release](../../releases/latest) and run it. Put it in `Home\Docker-Container-Manager\Builds\` and the Home Launcher lists it under Windows.

**Script:** clone this repo and run `Start Docker Container Manager.cmd`. It starts `src\Docker-Container-Manager.ps1` with the execution policy bypassed for that run only.

### Build the exe

Double-click `Build-Exe.cmd`. It checks the version in the script matches the newest CHANGELOG entry, runs PSScriptAnalyzer (if installed), pastes the icon and logo into the script and compiles it with [ps2exe](https://github.com/MScholtes/PS2EXE) (`-STA -noConsole`). The result is saved to the project's `Builds\` folder, outside the repo, as `Docker Container Manager v<version>.exe`. It installs ps2exe for your user the first time and logs to `Build-Exe.log`.

The exe is not signed by this script. Once `E:\Created\_shared\Build-Tool.ps1` is in place it replaces `Build-Exe.cmd` and signs the exe:

```powershell
E:\Created\_shared\Build-Tool.ps1 -Project "E:\Created\Home\Docker-Container-Manager"
```

## 🚀 Usage

1. Start the app and press **Compose file...** to pick your `docker-compose.yml`. Next time it opens the same file; the list at the top switches between files you've used. Its last entry, **Other compose file...**, picks another one, and right-clicking an entry offers **Remove from list** (the file itself is never touched).
2. Pick a group on the left, or **All containers**.
3. Select one or more containers (Ctrl+click, Shift+click or Ctrl+A) and press **Start**, **Stop**, **Restart**, **Update** or **Logs**, or right-click for **Recreate**, **Copy name** and **Remove container...**.
4. Use **Start all**, **Stop all** and **Update all** in the bar above the list for the whole group. With **All containers** picked they act on everything, after asking.
5. Press **Edit** to change the compose file. When you save, the list updates, and anything that needs recreating shows **Apply changes**.

To try it without your own containers, open `docs\demo\docker-compose.yml` and press **Start all**. `docker compose down` in that folder removes the demo again.

| Key | Does |
| --- | --- |
| F1 | Help |
| F5 | Read the compose file and status again |
| Ctrl+F | Search by name, image, group or port |
| Ctrl+E | Configure the selected container |
| Ctrl+T | Switch between the list and cards |
| Ctrl+L | Logs of the selected container |
| Enter, double-click | Open the selected container's web page (double-click opens the logs if it has none) |
| Ctrl+A | Select everything in the list |
| Esc | Clear the search |

What each action runs:

| Button | Docker command |
| --- | --- |
| Start | `docker compose up -d <services>` (creates them if needed, and starts what they depend on) |
| Stop | `docker compose stop <services>` |
| Restart | `docker compose restart <services>` |
| Update | `docker compose pull`, then `up -d --no-deps` for running ones and `up --no-start --no-deps` for stopped ones, then `docker image prune -f` (optional) |
| Apply changes, Recreate | The same as Update without the pull (Recreate adds `--force-recreate`) |
| Remove container | `docker rm -f <container>` (images, volumes and data folders are kept) |

## ⚙️ Configuration

### Labels in the compose file

Groups and links come from labels on each service. The `home` prefix can be changed in Settings.

```yaml
services:
  navidrome:
    image: deluan/navidrome
    container_name: navidrome
    labels:
      - home.group=Music
      - home.url=http://localhost:8090/app
      - home.description=Music streaming server
    ports:
      - 8090:4533
```

| Label | Does |
| --- | --- |
| `home.group` | The group the service is listed under. Services without it are under **Ungrouped**. |
| `home.url` | The container's web page. Without it the app uses `http://localhost:<first published port>`. `home.url=none` hides the link. |
| `home.description` | Tooltip for the service in the list. |
| `home.icon` | The service's icon: a name from [dashboard-icons](https://github.com/homarr-labs/dashboard-icons) (`home.icon=jellyfin`), a web address of a PNG, or a picture file (relative to the compose file). Without it the icon is found from the image name. |
| `home.color` | The colour of the service's group, as `#RRGGBB` or a colour name (`home.color=#2DA44E`). One service per group is enough. |
| `home.source` | The service's source page (`home.source=https://github.com/...`), opened by **Source**. `home.source=none` hides it. |

Adding or changing a label counts as a change to the service, so the app marks it **Changed** and **Apply changes** recreates it once.

### Group automatically

When some services have no `home.group` label, the bar above the list shows **Group automatically (n)...**. It lists those services with a suggested group for each, worked out from the image and service name. Groups already in the file are reused: if radarr is already under `Arr`, sonarr is suggested for `Arr` too. Services it doesn't recognise are left empty.

Change any group, type a new one, or clear it to leave that service ungrouped, then press **Save groups**. The app:

1. adds one `home.group` line to each of those services (in the same list or map style as the rest of the file, adding `labels:` where a service has none) and changes nothing else,
2. has Docker read a test copy first to make sure each service gets exactly that group,
3. backs up the compose file to `%APPDATA%\Docker Container Manager\Backups` and saves it,
4. reads the saved file back to check it, and reloads the list.

A small **Saving groups** box shows each step as it happens, with a progress bar. If a step fails, it says why and the compose file is left as it was; when everything worked it closes and the Finished box says so.

Services that already have a group are never touched. The grouped services show **Changed** until you press **Apply changes**; with another machine picked, press **Send** first.

### My groups

If you use the same containers in more than one compose file, keep your own list of which group each one goes in. **My groups...** (in Group automatically, or the link in Settings) opens it: a sortable list of containers and groups that you can filter, add to, change and remove from. **Update from current compose file** reads the group labels in the compose file that's open (without changing it), adds the containers that aren't in the list and asks before changing any group that's already there. **Open in editor** and **Open folder** show the file itself.

Group automatically uses My groups first and only guesses the containers that aren't in it; the **From** column says which. **Also add the new groups to My groups** (ticked to start with) adds the groups you save there that aren't in the list yet, so next time they're used first. You don't have to make the list yourself. The build can include your own groups list: the `my-groups.txt` next to `Build-Exe.cmd` is put into the exe (edit it, or remove it for an exe without a built-in list). On a PC with no list yet, the app starts with that built-in list; without one, it makes the list from the group labels of the first compose file it loads. The Activity log says which, and an existing list is never replaced. **Reset to built-in list...** in the My groups window goes back to the built-in list (it asks first and keeps a backup).

The list is a text file, `%APPDATA%\Docker Container Manager\my-groups.txt`, one `service | Group` per line (lines starting with `#` are ignored, and capitals and spaces around the `|` don't matter). It stays on your PC and is never sent anywhere. The list from before each save is kept as `my-groups.bak.txt`.

### Settings

**Settings** in the header sets the label prefix, how often the status is checked (15 seconds by default, 30 when the window is in the tray), the editor for **Edit** and **.env** (Visual Studio Code at `C:\Program Files\Microsoft VS Code\code.exe` by default, Notepad when it's empty or not found; **Check** beside it says whether the program is there and offers Visual Studio Code, Notepad++ or Notepad when it isn't, looking wherever Windows says they're installed, and **Choose another editor...** picks any other program; `%VARIABLES%` such as `%LOCALAPPDATA%` work in the path), whether Update removes unused images, whether stopping a group asks first, whether minimising hides the window in the tray instead of the taskbar (off by default), the theme (System, Light or Dark), whether app icons are shown, whether to check for newer images when the app starts, whether to show the progress window, and whether to show a Finished box when the progress window was hidden.

Downloaded icons are kept in `%LOCALAPPDATA%\Docker Container Manager\Icons` and the last update check in `%APPDATA%\Docker Container Manager\updates.json`. Icon downloads send only the icon name (for example `sonarr.png`) to the jsDelivr CDN; turn icons off in Settings if you'd rather not.

They are saved in `%APPDATA%\Docker Container Manager\settings.json`, together with the compose file in use, the recent files list and the window size. Delete the file to start again.

Start the exe (or the script) with `-ComposeFile "<path>"` to open a particular compose file.

### Other machines

The list at the top left switches between **This PC** and other machines that run the same compose file. Pick **Machines...** in it to add one:

| Field | Meaning |
| --- | --- |
| Name | What the list shows, for example `NAS`. |
| SSH login and port | `user@address`, and the SSH port if it isn't 22. |
| Compose folder | The folder on that machine that holds the compose file and `.env`, for example `/volume1/docker`. |
| .env comes from | The `Env_` file next to your compose file that **Send** copies there as `.env` (for example `Env_Synology`). |
| Project | The compose project name the containers were started with on that machine, if it isn't the folder's name (Synology Container Manager uses the project's name). **Test connection** lists the running projects. |
| Docker command | Usually `docker`. The app also looks in `/usr/local/bin`, where Synology keeps it. |
| Web pages on | The address used instead of `localhost` for web pages (the SSH address if empty). |
| Portainer data | The folder on that machine where Portainer keeps its data, for example `/volume1/docker/portainer`. Asked for the first time you install Portainer there. |

The two lists at the top are captioned **Containers on** (which machine's Docker the app shows and controls) and **Compose file**. Each machine remembers the compose file on this PC you last used with it. With another machine picked, the compose file box reads **Send from:**, because that machine runs its own copy of the file (in its compose folder); the file on this PC is what **Send** copies there and what **Configure** edits. The usual routine for a NAS: pick it in **Containers on**, edit the master copy (**Edit** or **Configure**), press **Send**, then **Apply changes**.

The app uses Windows' own `ssh.exe` with an SSH key, so it never asks for or stores a password. **SSH key help** in the Machines window shows the one-time setup, and **Test connection** checks it.

With a machine picked, every docker command (status, start, stop, update, logs, shell, disk usage) runs on that machine, against the compose file in its folder. The compose file on this PC stays the master:

- **Send** backs up the compose file and `.env` on the machine (as dated `.bak` copies), then copies your compose file and the machine's `Env_` file there. Nothing is restarted; services whose settings changed show **Changed**, and **Apply changes** recreates them.
- **Configure** saves values to the machine's `Env_` file on this PC, and **Save and recreate** sends it before recreating.
- **Tidy spacing** and **Check** work on the file on this PC.

### Source pages

**Source** (and **Source page** in the right-click menu) opens the selected container's project page. The app looks, in order, at:

1. a `home.source` label on the service (`none` hides the page),
2. your own source links: `%APPDATA%\Docker Container Manager\source-links.txt`, a text file that stays on your PC. **Edit source links...** (right-click menu, or Settings) opens it,
3. the address the image itself gives (its `org.opencontainers.image.source` label, asked once per image on the machine you picked),
4. a guess from the image name: `ghcr.io/owner/name` on GitHub, `registry.gitlab.com/group/name` on GitLab, linuxserver images on GitHub, anything else on Docker Hub.

The source links file has one page per line, a name, a `|` and the address:

```text
Sonarr | https://github.com/Sonarr/Sonarr
Uptime Kuma | https://github.com/louislam/uptime-kuma
```

The name (or the project name in a GitHub or GitLab address) is matched to the image, service or container name; capitals, spaces, dashes, dots and underscores don't matter. The button's tooltip shows the page it will open, and the Activity log says where it came from.

### Export

**Export...** in the bar above the list saves the list as one web page: a section for each group with its colour, and for each container its icon, state, how long, web page, image, source page and note. When a group, filter or search is picked, it asks whether to save only the containers shown. The page uses the app's theme (Light or Dark; with System it follows the browser), with a **Light / dark** switch at the top. It prints in light and has no scripts or other files, so it can be kept or sent as it is.

### Help

**Help** in the header (or F1) opens a guide inside the app: the lists at the top, groups and labels, the list and cards, the right-click menu, Configure, Check, Disk, Logs, other machines, Group automatically and My groups, Portainer, source pages, export, the keys and where the files are kept. The text can be selected and copied.

### Portainer

**Portainer**, next to **Cards** above the list, works on the machine picked in **Containers on**:

- **Running**: opens Portainer's web page on port 9000 (on the machine's address for other machines).
- **Stopped**: starts it (`docker start portainer`), then opens it.
- **Not installed**: asks where Portainer should keep its data, shows the full command and asks before running it:

  ```text
  docker run -d -p 8000:8000 -p 9000:9000 --name portainer --restart=unless-stopped -v /var/run/docker.sock:/var/run/docker.sock -v <data folder>:/data portainer/portainer-ee
  ```

Right-click the button for **Update Portainer...** (pulls the newest image and makes the container again with the data folder it uses now, so settings, users and the licence are kept) and **Change data folder...**.

The data folder is kept for each machine: the **Portainer data** field in the Machines window, and the settings file for This PC. The first suggestion is `docker_configs\portainer` next to the compose file on this PC, `/volume1/docker/portainer` on a Synology, and `/home/<user>/docker_configs/portainer` on other Linux machines.

Portainer Business asks for its licence key in its own web page the first time you open it, and keeps it in its data folder. The app never asks for, sees or stores the key. Portainer controls Docker on its machine through the Docker socket, so it is only installed or started when you press the button.

## 📝 Changelog

See [CHANGELOG.md](CHANGELOG.md).

## 📄 Licence

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 Jason Rhodes.

Docker and Docker Compose are trademarks of Docker, Inc. This project is not affiliated with or endorsed by Docker, Inc.
