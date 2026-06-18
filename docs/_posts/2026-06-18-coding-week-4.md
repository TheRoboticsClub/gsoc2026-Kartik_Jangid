---
layout: single
title: "Coding Week 4 — Pre-Refactoring Audit: Mapping the Container Before Splitting It"
date: 2026-06-18
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, optimization, multi-stage-build, entrypoint, ros2]
---

Week 3 closed the PyTorch removal and merged PR [#3863](https://github.com/JdeRobot/RoboticsAcademy/pull/3863). Week 4 is different in character: before a single line of the multi-stage Dockerfile is written, I'm running a structured read-only audit of the existing image. There are eight steps, each feeding the stage-split decision that follows. This post records each step in order as the data comes in.

The split problem is simple to state and hard to get right: a multi-stage build divides one monolithic Dockerfile into a builder stage and a runtime stage. The runtime stage must contain everything the container needs at startup and nothing it doesn't. Getting that boundary wrong means either a broken container or a bloated one — which defeats the purpose entirely.

---

## Step 1 — Entrypoint and Startup Script Audit

The first question before any refactoring: what actually runs at container start, and what filesystem paths does it need?

### The Dockerfile Landscape

Three Dockerfiles are in scope:

| Dockerfile | Base image | ENTRYPOINT | Role |
|---|---|---|---|
| `Dockerfile.dependencies_humble` | `nvidia/opengl:1.2-glvnd-runtime-ubuntu22.04` | none | Builder; produces `jderobot/robotics-applications:dependencies-humble` |
| `Dockerfile.humble` | `jderobot/robotics-applications:dependencies-humble` | `["./entrypoint.sh"]` | Runtime image; `WORKDIR /` |
| `Dockerfile.database` | `postgres:18` | inherited | Populates init SQL only; no custom entrypoint |

Two other Dockerfiles in the repo (`tello_ros/Dockerfile`, `Dockerfile.turtlebot2`) are excluded — the first is a smoke-test image, the second is marked outdated.

One immediate finding: `Dockerfile.humble` declares `ENTRYPOINT ["./entrypoint.sh"]` — a CWD-relative path. It works only because `WORKDIR /` is set. The multi-stage rewrite should use the absolute path `/entrypoint.sh` to make it CWD-independent.

### Startup Script Inventory

Nine scripts are `mv`-ed from `RoboticsInfrastructure/scripts/` to `/` during the `Dockerfile.humble` build. All nine are required at runtime:

| Script | Invoked by | Purpose |
|---|---|---|
| `/entrypoint.sh` | `ENTRYPOINT` | Parses CLI flags; starts Django / BT Studio, RAM, and VNC |
| `/.env` | `ENV BASH_ENV=/.env` | Auto-sourced into every bash subshell; sets ROS/Gazebo/Python paths |
| `/set_dri_name.sh` | `source` inside entrypoint | Detects GPU vendor via `lspci`; exports `DRI_NAME` and `DRI_VENDOR` |
| `/check_ram_version.sh` | `source` inside entrypoint | Upgrades the RAM pip package if stale — makes a network call at container start |
| `/ram_entrypoint.py` | entrypoint fallback path | Inserts `/RoboticsApplicationManager` into `sys.path`; starts `Manager` class |
| `/start_vnc.sh` | RAM session launcher | CPU VNC: Xorg + x11vnc + noVNC proxy |
| `/start_vnc_gpu.sh` | RAM session launcher | GPU VNC: TurboVNC + VirtualGL + noVNC proxy |
| `/kill_all.sh` | External / RAM | Kills Gazebo, RViz, VNC, and Python processes |
| `/check_device.py` | External utility | Checks whether `/dev/dri/cardN` device node exists; exits 0/1 |
| `/etc/xdg/openbox/LXDE/rc.xml` | LXDE window manager | Window manager config; installed from a committed `rc.xml` |

The `BASH_ENV=/.env` mechanism deserves attention: every non-interactive bash subshell automatically sources `/.env`, which in turn sources five ROS workspaces and sets Gazebo paths. This means any `RUN bash -c "..."` instruction in the runtime stage will inherit this environment — a potential source of surprising behavior during the build.

### Path Classification

Every path referenced by the startup scripts was traced to one of four origins: APT-installed, built by `colcon`, provided by a host volume mount, or created at runtime.

**Paths sourced in `/.env`:**

| Path | Origin | Notes |
|---|---|---|
| `/opt/ros/humble/setup.bash` | APT | `ros-humble-ros-base` |
| `/usr/share/gazebo/setup.bash` | APT | `gazebo11` package |
| `/home/dev_ws/install/local_setup.bash` | **LIKELY DEAD** | No Dockerfile builds a workspace at `/home/dev_ws` |
| `/home/drones_ws/install/setup.bash` | BUILD | `colcon build` in `Dockerfile.dependencies_humble` |
| `/home/ws/install/setup.bash` | BUILD | `colcon build` in `Dockerfile.humble` |
| `/workspace/worlds/install/setup.bash` | HOST / VOLUME | Sourced with `&>/dev/null`; no Dockerfile creates this path |

The `/home/dev_ws` entry is the most notable find: `/.env` sources it unconditionally — no `&>/dev/null` guard — but no Dockerfile in the repo ever builds a workspace there. It is a stale reference that silently prints a `bash: /home/dev_ws/install/local_setup.bash: No such file or directory` error on every bash subshell startup.

**ENV variables that must be re-declared in the runtime stage:**

When a multi-stage build copies artifacts from a builder stage, `ENV` declarations do not transfer automatically. Every variable below must be explicitly re-declared in the runtime stage, or the container will start with a broken environment:

| Variable | Declared where | Risk if missing |
|---|---|---|
| `BASH_ENV=/.env` | `Dockerfile.humble` | `/.env` won't auto-source; all ROS paths missing |
| `ROS_DISTRO=humble` | `Dockerfile.dependencies_humble` | ROS tools fail to locate distro |
| `NVIDIA_DRIVER_CAPABILITIES=all` | `Dockerfile.dependencies_humble` | NVIDIA runtime won't expose GPU capabilities |
| `NVIDIA_VISIBLE_DEVICES=all` | `Dockerfile.dependencies_humble` — **`ARG`, not `ENV`** | GPU access not granted; `ARG` values do not persist into the final image |
| `PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python` | `Dockerfile.dependencies_humble` | Gazebo Harmonic protobuf crash returns (see Week 3) |
| `LANG` / `LANGUAGE` / `LC_ALL` | `Dockerfile.dependencies_humble` | Django requires a valid locale |

The `NVIDIA_VISIBLE_DEVICES` finding is the highest-priority item: it is declared as `ARG` rather than `ENV`, which means it is a build-time variable only and does not persist into the image environment at all. The NVIDIA container runtime reads this from the running container's environment. Without it, GPU access will not be granted regardless of the `--gpus` flag passed to `docker run`.

### Volume Mount Risks

`docker-compose.yaml` introduces two bind mounts that change entrypoint behavior in ways that affect the multi-stage split:

**`/RoboticsAcademy` — HIGH risk.** The entire host repo root is mounted over `/RoboticsAcademy`, completely shadowing the `git clone` baked into the image at build time. In compose-based development, the baked copy is invisible. In standalone `docker run` (CI, production), the baked copy is what runs. The entrypoint uses `ROBOTICS_ACADEMY_BASE=/RoboticsAcademy` for `manage.py`, `EXERCISES_STATIC_FILES`, and `PYTHONPATH` — all three are affected by this overlay. The runtime stage must still COPY the academy code, because not all users run via compose.

**`/RoboticsApplicationManager` — HIGH risk.** `entrypoint.sh` checks `if [ -d "/RoboticsApplicationManager" ]`. When the compose bind mount is active (`./src → /RoboticsApplicationManager`), the entrypoint takes the direct path and skips both `check_ram_version.sh` and `/ram_entrypoint.py`. Without the mount (standalone `docker run`), the fallback runs: it sources `check_ram_version.sh` (network call) and launches `/ram_entrypoint.py`, which does `sys.path.insert(0, "/RoboticsApplicationManager")` — a no-op since the directory doesn't exist in that case. The pip-installed `robotics_application_manager` package runs instead. These two code paths are functionally different and need to be tested independently during the refactor.

### Open Questions from Step 1

Ten open questions surfaced. The ones that must be resolved before the split can proceed:

1. **Dead workspace** — `/home/dev_ws/install/local_setup.bash` is sourced unconditionally but never built. Confirm it is dead and remove it from `/.env`.
2. **`NVIDIA_VISIBLE_DEVICES` as `ARG`** — Must become `ENV NVIDIA_VISIBLE_DEVICES=all` in the runtime stage, or GPU access will not be granted.
3. **Network call at container start** — `check_ram_version.sh` calls `pip index versions` over the network on every standalone startup. The multi-stage build should pin the RAM version at build time and remove this runtime upgrade check.
4. **`VGL_DISPLAY` hardcoded** — `start_vnc_gpu.sh` hardcodes `VGL_DISPLAY=/dev/dri/card0` and ignores `$DRI_NAME`. Multi-GPU systems will silently use the wrong device. Should use `$DRI_NAME` instead.
5. **CWD-relative `source` calls** — `source set_dri_name.sh` and `source check_ram_version.sh` rely on CWD being `/`. These should become `source /set_dri_name.sh` and `source /check_ram_version.sh` in the rewrite.
6. **`xorg.conf` download** — `Dockerfile.dependencies_humble` attempts `curl -L -o xorg.conf https://xpra.org/xorg.conf || echo "Download failed"` at build time. If the download failed silently, `xorg.conf` may be absent from `/`. Needs verification against a built image; the fallback should be replaced with a COPY of a committed file.

---

## Step 2 — .dockerignore Audit

**There is no `.dockerignore` anywhere in this repository.**

The current build is safe by accident: `build.sh` runs `docker build` with `scripts/RADI/` as context, which happens to be a 41 MB directory containing almost nothing but the files the Dockerfiles actually need. Any change that shifts the build context — including the planned multi-stage Dockerfile — risks sending **6.6 GB** to the Docker daemon if run from the repo root.

### Current Context (scripts/RADI/)

| File | Size | Needed by Dockerfile |
|---|---|---|
| `gpu/turbovnc_3.0.3_amd64.deb` | 39 MB | YES — `COPY`ed in `Dockerfile.dependencies_humble` |
| `gpu/virtualgl_3.1.4_amd64.deb` | 1.6 MB | YES |
| `gpu/virtualgl32_3.1.4_amd64.deb` | 788 KB | YES |
| `install-ompl-ubuntu.sh` | 8 KB | YES |
| `Dockerfile.*`, `build.sh`, `README.md` | ~36 KB | No |

Context total: ~41 MB. Waste: ~36 KB (0.09%). Adding a `.dockerignore` to `scripts/RADI/` today saves essentially nothing measurable — but the real problem is the future state.

### The Repo-Root Risk

The multi-stage Dockerfile will likely move closer to the repo root, or CI may run `docker build -f scripts/RADI/Dockerfile.humble .` from the root. Without a `.dockerignore` there, the daemon receives:

| Directory | Size | Needed? |
|---|---|---|
| `.git/` | **2.3 GB** | Never — git history has no place inside an image |
| `RoboticsInfrastructure/` | **3.2 GB** | No — both Dockerfiles git-clone it at build time already |
| `react_frontend/node_modules/` | **851 MB** | Never — the build runs `yarn install` inside the container |
| `exercises/` | ~231 MB | No — cloned via the `ROBOTICS_ACADEMY` ARG |
| `scripts/RADI/gpu/*.deb` | 41 MB | **Yes** — the only host files actually COPYed |

Without a `.dockerignore`: **~6.6 GB per build**. With one: **~41 MB**.

Neither `RoboticsInfrastructure/` nor `react_frontend/node_modules/` should ever be in the build context — the Dockerfiles clone or install those from scratch inside the container, so sending them from the host is pure waste.

### The .gitignore Overlap

The existing `.gitignore` already captures most of the right patterns (`node_modules/`, `__pycache__/`, `*.log`, `graphify-out/`, etc.) and can serve as the starting point. The entries `.gitignore` does **not** handle but `.dockerignore` must:

```dockerignore
.git/                   # .gitignore never excludes .git itself
RoboticsInfrastructure/ # submodule tracked by git, but 3.2 GB of binary assets
react_frontend/         # source is git-tracked; yarn runs inside the container
exercises/              # git-tracked; docker-clones from GitHub at build time
src/                    # RAM dev mount — runtime only, not a build-time COPY
```

One apparent conflict: `.gitignore` excludes `.env`. That is fine — `/.env` inside the container is generated from `RoboticsInfrastructure` scripts, not COPYed from the host repo root.

### What Needs to Exist Before the First Multi-Stage Build

Two files are required — one low-urgency, one critical:

**`scripts/RADI/.dockerignore`** (low urgency — saves ~36 KB today, establishes the habit):
```dockerignore
build.sh
README.md
Dockerfile.*
```

**`.dockerignore` at repo root** (required before any build run from outside `scripts/RADI/`):
```dockerignore
.git/
.gitignore
.gitmodules
RoboticsInfrastructure/
react_frontend/node_modules/
react_frontend/static/
exercises/
academy/
src/
graphify-out/
.vscode/
.idea/
__pycache__/
*.py[cod]
*.log
*.zip
.venv/
venv/
.github/
docker-compose.yaml
```

After writing either file, verify the `.deb` files are not accidentally excluded:
```bash
tar -czh . | wc -c   # run from scripts/RADI/ or repo root; expect ~41 MB
```

### Open Questions from Step 2

1. **Where does the multi-stage Dockerfile live?** If it moves to the repo root, the root `.dockerignore` is critical and must land before the first build attempt.
2. **git-clone vs. COPY pattern?** Both Dockerfiles currently git-clone `RoboticsAcademy` and `RoboticsInfrastructure` at build time. If the refactor switches to `COPY . /RoboticsAcademy`, then `exercises/` and `react_frontend/src/` must be kept in the context and the `.dockerignore` above needs updating.
3. **Commit the `.deb` files or download them?** The three files (41 MB total) are currently committed under `scripts/RADI/gpu/`. `RUN wget` inside the Dockerfile would eliminate the only meaningful build-context payload — at the cost of a CDN round-trip on every build.

---

## Step 3 — Choose Runtime Base Image

The current base for `Dockerfile.dependencies_humble` is `nvidia/opengl:1.2-glvnd-runtime-ubuntu22.04`. Changing it was the first thing to evaluate — a lighter base like `ubuntu:22.04` or `ros:humble-ros-base` is an obvious first instinct when trying to slim an image.

The instinct is wrong here.

The entire GPU VNC stack is load-bearing on this specific base:

- VirtualGL installs its OpenGL faker library (`/usr/lib/libvglfaker.so`) and sets `setuid` bits on it. Those bits rely on the OpenGL dispatch layer that `nvidia/opengl` provides. On a plain `ubuntu:22.04` base those libraries are absent and VirtualGL simply will not intercept OpenGL calls.
- TurboVNC (`/opt/TurboVNC/bin/vncserver`) works with VirtualGL through that same dispatch layer.
- The NVIDIA container runtime exposes GPU capabilities via `NVIDIA_DRIVER_CAPABILITIES=all`, which in turn requires the OpenGL runtime hooks that this base ships.

Attempting to reconstruct that stack on a different base would mean manually reinstalling the NVIDIA OpenGL dispatch layer, re-verifying `setuid` permissions survive the layer copy, and re-testing every GPU exercise — invasive work that touches the most fragile part of the image and would be a reasonable push-back from any maintainer reviewing the PR.

**The base image stays.** The win from multi-stage does not come from what the runtime stage sits on — it comes from what is not carried into the runtime stage. Build tools, intermediate colcon artifacts, apt lists, and pip caches are the targets. The base is not.

---

## Step 4 — apt and pip Build-vs-Runtime Split

This step classifies every package installed by `Dockerfile.dependencies_humble`, `Dockerfile.humble`, and `install-ompl-ubuntu.sh` into one of three buckets:

- **A — Build-only:** safe to exclude from the runtime stage entirely
- **B — Runtime confirmed:** traced to a specific path or import at container start
- **C — Ambiguous:** needs a second look before the split is made

### Priority Finding: ros-humble-ros-base Already Correct

The first thing to check was whether the monolithic Dockerfile was installing `ros-humble-desktop` instead of `ros-humble-ros-base`. Desktop pulls in RViz, RQt, tutorials, and a collection of demo packages that add ~2.2 GB and are never needed in a headless server container. It does not — line 57 of `Dockerfile.dependencies_humble` already uses `ros-humble-ros-base`. That saving has already been taken.

A smaller follow-on: `ros-humble-ros-base` transitively pulls in `python3-colcon-common-extensions` and `python3-rosdep` — build-only tools. The runtime stage could use `ros-humble-ros-core` instead, which skips them. Worth confirming no runtime path depends on colcon or rosdep being present.

### Build-Only (A) — Safe to Drop from Runtime Stage

The packages safe to exclude fall into clear categories:

**Compilers and build systems:** `build-essential`, `cmake`, `python3-colcon-common-extensions`, `python3-colcon-mixin`, `python3-rosdep`, `python3-vcstool`, `ros-dev-tools`, and the full `ros-humble-ament-cmake-*` and `ros-humble-ament-lint-*` families. None of these are invoked after the `colcon build` steps complete.

**Linting and testing:** `python3-flake8` and all its plugins, `python3-pytest`, `cppcheck`, `lcov`, `ros-humble-ros-testing`, `pylint`, `coverage`, `cpplint`, `cmakelint`. These exist entirely for CI.

**Frontend build:** `nodejs` and `yarn` are only needed to run `yarn install && yarn run build` inside the container. Django serves the pre-built static files at runtime — neither Node nor Yarn is invoked again after the build step.

**Repo and download tools:** `git`, `curl`, `wget`, `gnupg`, `lsb-release`, `software-properties-common`, `apt-utils`. These are used to add apt repositories and clone source code during the build. The runtime stage has no repositories to add and no code to clone.

**OMPL generator tools:** `castxml`, `pyplusplus`, `pygccxml` (all pip). These generate the OMPL Python bindings at compile time. Once the `.so` is built, they are never called again.

**pip stubs:** `asyncio==3.4.3` is a no-op on Python 3.10 — `asyncio` is stdlib. `argparse==1.4.0` is the same. Both can be removed from builder and runtime alike. `six==1.16.0` is a Python 2/3 compatibility shim that nothing in RADI uses.

### Runtime Confirmed (B)

The full runtime dependency set traces to concrete paths from Step 1. Highlights:

| Category | Key packages |
|---|---|
| ROS 2 core | `ros-humble-ros-base`, `ros-humble-rmw-cyclonedds-cpp` (active RMW in `.bashrc`) |
| ROS 2 messages | `geometry_msgs`, `sensor_msgs`, `nav_msgs`, `tf2`, `cv_bridge` (confirmed in HAL files) |
| ROS 2 tools | `rviz2`, `moveit`, `ros2-control`, `ros2-controllers`, `ros-humble-ur` |
| Gazebo | `gazebo11` (`/.env` sources `/usr/share/gazebo/setup.bash`), `gz-harmonic`, both ROS bridges |
| GStreamer | All four plugin sets — Gazebo camera plugins require GStreamer codecs to publish image topics |
| VNC/X11 | `x11vnc`, `xserver-xorg-video-dummy`, `lxde-common`, VirtualGL 32/64-bit runtime libs |
| GPU detection | `pciutils` — `set_dri_name.sh` calls `lspci` at every container start |
| Python | `numpy`, `opencv-python`, `Pillow`, `pyyaml`, `psutil`, `watchdog`, `websocket_server` |
| NVIDIA CUDA | All seven pinned wheels from Week 3 (`nvidia-cuda-runtime-cu12` through `nvidia-cufft-cu12`) |
| Django | `django==4.1.7`, `djangorestframework`, `django-webpack-loader`, `django-cors-headers` |
| RAM | `robotics_application_manager`, `transitions`, `websockets`, `posix-ipc` |

### Ambiguous (C) — Ten Items Flagged

**`postgresql-18` — full server installed in the wrong container.** Django connects to the `my-postgres` container via psycopg2. The RADI container only needs the PostgreSQL client libraries to open that connection — not the server. `postgresql-18` installs the full server binaries (~50 MB) that are never invoked. If psycopg2's pip wheel bundles its own `libpq.so` (common with the binary wheel), `postgresql-18` can be dropped entirely from RADI. If it requires the system library, only `libpq5` (< 1 MB) is needed.

**`-dev` packages with bundled `.so` files.** Seven packages are installed as `-dev` variants when only the runtime shared library is needed. The split table:

| Installed (builder) | Runtime stage should use instead |
|---|---|
| `libgeographic-dev` | `libgeographic23` |
| `libncurses-dev` | `libncurses6` |
| `libyaml-cpp-dev` | `libyaml-cpp0.7` |
| `libpoco-dev` | `libpoco-foundation83 libpoco-net83 libpoco-util83` |
| `libpcl-dev` | `libpcl-common1.12 libpcl-io1.12` |
| `libboost-*-dev` | `libboost-*1.74.0` |
| `libfcl-dev` | `libfcl0.6` |
| `libgstreamer-plugins-base1.0-dev` | `libgstreamer-plugins-base1.0-0` |

**`tmux` and `tmuxinator`.** Aerostack2 uses tmuxinator configuration files to launch multi-process drone exercises. If any drone exercise calls `tmuxinator start` at runtime, both are runtime required. `kill_all.sh` does not kill tmux processes, which hints they may not be actively used — but this needs verification by running a drone exercise.

**`python3-pip` at runtime.** `check_ram_version.sh` calls `pip show` and potentially `pip install --upgrade robotics_application_manager` at every container start in standalone mode. This makes pip a runtime dependency solely because of that upgrade check. Removing the check (flagged in Step 1, Open Question #8) would make pip build-only.

**`python3-pydantic` (apt) vs `pydantic==2.4.2` (pip).** The apt package installs pydantic 1.x; the pip package installs 2.4.2. These have breaking API differences. The pip version takes precedence, making the apt package a silent redundancy and a potential confusion vector. Only the pip version should be in the runtime stage.

### What the Classification Enables

The build-only list above is the set of packages that are candidates to vanish from the runtime stage entirely. The `-dev` → non-`-dev` replacements are a second class of reduction — not eliminating packages but replacing them with their stripped-down equivalents. The ambiguous items are where the remaining risk sits and where Steps 5 and 6 (`ldd` audit and `strace` open-file audit) will give ground truth answers.

---

## Step 5 — ldd and Dynamic Linker Audit

`ldd` reads the ELF headers of a compiled binary or shared library and prints every shared object it must find at runtime. Running it against the key binaries inside the existing monolithic image converts the Category C ambiguities from Step 4 — packages marked as "needs a `.so` but unclear which" — into confirmed package names. What `ldd` cannot see is files opened at runtime via `open()` rather than linked at load time: configuration files, plugin directories, model paths. That is Step 6's job.

All commands were run as:
```bash
docker run --rm --entrypoint bash jderobot/robotics-academy:test -c "ldd <path>"
```

### Definitive Resolutions

**`postgresql-18` — drop entirely, replace with `libpq5`.**
Two independent paths confirmed this. First: `ldd` on psycopg2's C extension (`psycopg2/_psycopg.cpython-310.so`) showed it links against `/lib/x86_64-linux-gnu/libpq.so.5`. `dpkg -S` confirmed that file is owned by the standalone `libpq5` package — not `postgresql-18`. Second: the cv_bridge chain (described below) also resolves to `libpq.so.5` through a completely separate route. The full PostgreSQL server (`postgresql-18`), its client tools, and all `postgresql-*` meta-packages are dead weight in the RADI container. Only `libpq5` is needed.

**`libboost-all-dev` → two packages only.**
`ldd /usr/local/lib/libompl.so.18` showed exactly two Boost runtime libraries:
```
libboost_filesystem.so.1.74.0    → /lib/x86_64-linux-gnu/libboost_filesystem.so.1.74.0
libboost_serialization.so.1.74.0 → /lib/x86_64-linux-gnu/libboost_serialization.so.1.74.0
```
`libboost-all-dev` is a meta-package that pulls in over 80 packages. The runtime stage needs exactly `libboost-filesystem1.74.0` and `libboost-serialization1.74.0`.

**`libfcl-dev` → `libfcl0.7`.**
Both `move_group` and `libmoveit_move_group_default_capabilities.so` showed `libfcl.so.0.7 → /lib/x86_64-linux-gnu/libfcl.so.0.7`. The `-dev` headers are not linked by any runtime binary.

**`sudo`, `net-tools`, `tmux`, `tmuxinator`, `libimage-exiftool-perl` — all drop.**
None of these produced a match across startup scripts, exercise launchers, and HAL files:
- `grep -r "sudo"` across exercise and academy Python returned only README files (host setup docs, not container code).
- `grep -rE "ifconfig|netstat|arp"` across all Python returned zero matches.
- All aerostack2 `.yml`/`.yaml` launcher files were checked — no exercise invokes `tmuxinator start` or calls `tmux` directly.
- The only mention of `exiftool` in the codebase is a comment in a React `node_modules` TypeScript declaration — not a call.

**All `-dev` packages confirmed replaceable.** The `dpkg -l` audit inside the container showed that every `-dev` package listed in Step 4's swap table already has its non-dev runtime counterpart installed as a transitive dependency. The runtime stage can install the non-dev versions directly:

| Drop from runtime | Install instead |
|---|---|
| `libgeographic-dev` | `libgeographic19` |
| `libncurses-dev` | `libncurses6`, `libncursesw6` |
| `libyaml-cpp-dev` | `libyaml-cpp0.7` |
| `libpoco-dev` | `libpocofoundation80 libpocoutil80 libpoconet80 libpocoxml80 libpocojson80` |
| `libpcl-dev` | `libpcl-common1.12 libpcl-io1.12 libpcl-filters1.12 libpcl-search1.12 libpcl-kdtree1.12` |
| `libboost-all-dev` | `libboost-filesystem1.74.0 libboost-serialization1.74.0` |
| `libfcl-dev` | `libfcl0.7` |
| `libgstreamer-plugins-base1.0-dev` | `libgstreamer-plugins-base1.0-0` |

### Surprise Finding — libgdal30

`ldd /opt/ros/humble/lib/libcv_bridge.so` produced an unexpected chain:

```
libopencv_imgcodecs.so.4.5d → system OpenCV (apt, compiled against Ubuntu 22.04 libs)
libgdal.so.30               → /lib/libgdal.so.30     ← not in any Dockerfile apt install
libpq.so.5                  → /lib/x86_64-linux-gnu/libpq.so.5
```

`ros-humble-cv-bridge` was compiled against the Ubuntu 22.04 system OpenCV (4.5d). That system OpenCV's image codec support links against GDAL — the Geospatial Data Abstraction Library — which in turn has PostgreSQL raster support compiled in and links against `libpq.so.5`. None of this is visible from reading the Dockerfiles or the Python source.

The owning package is `libgdal30`, installed as a transitive dependency of `ros-humble-cv-bridge`. It is not explicitly mentioned anywhere in the Dockerfiles and would not appear on a manual audit of apt install blocks. Without the `ldd` step, the runtime stage could have been built without GDAL, and any exercise using `cv_bridge` would have failed at the dynamic linker stage with a missing `libgdal.so.30` — the kind of error that is easy to misdiagnose. Because `libgdal30` is a transitive dependency of `ros-humble-cv-bridge`, it will auto-install in the runtime stage as long as cv_bridge is included. The explicit knowledge is what matters: it must appear in the confirmed runtime package list.

The same audit also surfaced a dual OpenCV situation: the container has `libopencv_core.so.4.5d` (system apt, used by cv_bridge) and `opencv-python==4.5.5.64` (pip, used by Python HAL `import cv2`). Both are needed and cannot be consolidated — cv_bridge cannot be relinked against the pip version. No action required, but it explains the GDAL chain.

### Open Questions Remaining After ldd

1. **`libpoco-dev` exact subset** — Poco was not found in `ldd` output for rclcpp, class_loader, or controller_manager. The exact Poco `.so` files needed depend on which ROS 2 packages have Poco compiled in; needs `ldd` on the Poco-consuming binaries specifically.
2. **`libpcl-dev` exact subset** — The minimal `libpcl-*1.12` set for `ros-humble-pcl-ros` needs `ldd /opt/ros/humble/lib/libpcl_ros_tf.so` (or equivalent) in the runtime stage to confirm.
3. **`libgdal30` owning package path** — `ldd` resolved `libgdal.so.30` at `/lib/libgdal.so.30` (not the standard `/lib/x86_64-linux-gnu/` path). Needs `dpkg -S /lib/libgdal.so.30` to confirm the owning package name for the explicit runtime apt install list.
4. **`PySimpleGUI-4-foss`** — Still unresolved. No aerostack2 launcher file was found calling it; if drone exercises run headlessly this package is unused. Default: include it, flag for human confirmation.
5. **`libassimp5`** — Seen in the gz_ros2_control `ldd` output; it is a transitive dep of `gz-harmonic` and will auto-install. No explicit install needed, but needs confirmation once the runtime stage Dockerfile is written.
6. **OMPL Boost Python bindings** — `ldd /usr/local/lib/libompl.so.18` did not show `libboost_python`, suggesting the Python bindings live in a separate `.so`. If no exercise does `import ompl` directly (all OMPL access goes through MoveIt's C++ planners), `libboost-python1.74.0` is not needed at runtime.

### Open Questions Resolved

**Q1 — Poco: drop everything.**
A scan across 500+ ROS `.so` files, all three custom workspaces, MoveIt, and Gazebo found zero Poco linkage:
```bash
find /opt/ros/humble/lib -name '*.so' | xargs -I{} sh -c \
  'ldd "{}" 2>/dev/null | grep -qi PocoFoundation && echo "{}"'
# (empty)
```
`apt-cache rdepends --installed libpocofoundation80` listed only other Poco packages and `libpoco-dev` itself. No installed runtime package depends on Poco. All five `libpoco*80` packages proposed in Step 5 are dropped. `libpoco-dev` was a build-only header install that left no runtime `.so` consumers.

**Q2 — PCL: `libpcl-common1.12` and `libpcl-io1.12` only.**
`ros-humble-pcl-ros` ships exactly one system-PCL-linked library. `ldd` on it revealed:
```bash
ldd /opt/ros/humble/lib/libpcd_to_pointcloud_lib.so | grep 'libpcl_'
# libpcl_io.so.1.12       → /lib/x86_64-linux-gnu/libpcl_io.so.1.12
# libpcl_common.so.1.12   → /lib/x86_64-linux-gnu/libpcl_common.so.1.12
# libpcl_io_ply.so.1.12   → /lib/x86_64-linux-gnu/libpcl_io_ply.so.1.12
```
All three `.so` files are owned by `libpcl-io1.12` and `libpcl-common1.12`. `filters`, `search`, `kdtree`, and `octree` did not appear in any ldd output. `ros-humble-pcl-conversions` is a header-only bridge and installs no system-PCL-linked `.so`. Install the confirmed minimum; the broader set gets added only if a missing-lib error is observed at runtime.

**Q3 — `libgdal30`: auto-installed, remove from explicit list.**
```bash
dpkg -S /lib/libgdal.so.30
# libgdal30: /usr/lib/libgdal.so.30
```
`libgdal30` is already a transitive dependency of `ros-humble-cv-bridge` → system OpenCV. It auto-installs in the runtime stage when cv_bridge is included. No explicit listing needed.

**Q4 — `PySimpleGUI-4-foss`: drop.**
```bash
grep -r 'PySimpleGUI\|pysimplegui' \
  /RoboticsAcademy/exercises/ /RoboticsInfrastructure/ /RoboticsAcademy/academy/
# (empty)
```
Zero matches across all exercise, academy, and infrastructure code. Drop from the runtime stage.

**Q5 — `libassimp5`: confirmed transitive, no action needed.**
`libassimp.so.5` is a transitive dependency of `gz-harmonic`. It auto-installs when `gz-harmonic` is included. No explicit listing required.

**Q6 — OMPL Boost Python: `libboost-python1.74.0` and `libboost-numpy1.74.0` both required.**
Step 5 ran `ldd` on `libompl.so.18` (the C++ library) and saw no Boost Python — the Python bindings are separate `.so` files that Step 5 missed entirely:
```bash
for f in /usr/lib/python3/dist-packages/ompl/base/_base.so \
          /usr/lib/python3/dist-packages/ompl/geometric/_geometric.so \
          /usr/lib/python3/dist-packages/ompl/control/_control.so; do
  ldd "$f" | grep -i boost
done
# all three: libboost_python310.so.1.74.0
# _base.so additionally: libboost_numpy310.so.1.74.0
```
`dpkg -S libboost_python310.so.1.74.0` confirmed: the unversioned symlink is owned by `libboost-python1.74-dev`; the versioned `.so.1.74.0` is owned by `libboost-python1.74.0`. The runtime stage needs the non-dev package. Both `libboost-python1.74.0` and `libboost-numpy1.74.0` are required.

### Final Confirmed Runtime apt Additions from Steps 5 and 6

Every entry below has at least one `ldd` or `dpkg` confirmation trace:

| Package | Evidence |
|---|---|
| `libpq5` | psycopg2 `ldd` + cv_bridge → libgdal → libpq chain |
| `libfcl0.7` | MoveIt `move_group` ldd |
| `libboost-filesystem1.74.0` | OMPL `libompl.so.18` ldd |
| `libboost-serialization1.74.0` | OMPL `libompl.so.18` ldd |
| `libboost-python1.74.0` | OMPL Python extension ldd (all three modules) |
| `libboost-numpy1.74.0` | OMPL `_base.so` ldd |
| `libpcl-common1.12` | `libpcd_to_pointcloud_lib.so` ldd |
| `libpcl-io1.12` | `libpcd_to_pointcloud_lib.so` ldd |
| `libgeographic19` | dpkg split from `libgeographic-dev` |
| `libncurses6`, `libncursesw6` | dpkg split from `libncurses-dev` |
| `libyaml-cpp0.7` | dpkg split from `libyaml-cpp-dev` |
| `libgstreamer-plugins-base1.0-0` | replaces `-dev` variant |
| `pciutils` | `set_dri_name.sh` calls `lspci` (grep confirmed) |
| `python3-pip` | `check_ram_version.sh` calls `pip` at startup (grep confirmed) |

Confirmed not needed in the runtime stage: all five `libpoco*80` packages, `libgdal30` (transitive), `libassimp5` (transitive), `PySimpleGUI-4-foss`, `postgresql-18` and all `postgresql-*` meta-packages, and the four unconfirmed PCL sub-packages (`filters`, `search`, `kdtree`, `octree`).

---

## Step 6 — strace Open-File Audit

`ldd` maps shared library linkage at load time; it sees nothing that a process opens via `open()` or `openat()` at runtime — config files, ament resource index markers, launch scripts, URDF and SDF models, parameter YAML files. Without auditing these, the runtime stage could have the right `.so` files and still crash the moment it tries to read a file that was only present in the builder. All four `strace --cap-add SYS_PTRACE` invocations returned empty output due to Docker 20.10's kernel-level seccomp profile blocking `ptrace(PTRACE_ATTACH)` even with the capability granted. The audit fell back to `bash -x` tracing of `source /.env` and direct directory inspection of every path in the startup chain.

### Critical Finding — Symlink-Install Bomb

Both colcon workspaces were built with `--symlink-install`:

```dockerfile
# Dockerfile.dependencies_humble
RUN colcon build --symlink-install ...   # /home/drones_ws

# Dockerfile.humble
RUN colcon build --symlink-install ...   # /home/ws
```

`--symlink-install` means that every Python script, launch file, YAML parameter file, URDF, XACRO, and SDF in `install/` is a symbolic link pointing back into `src/`. Confirmed inside the container:

```
lrwxrwxrwx root root  48 Jun 11  f1.launch.py -> /home/ws/src/CustomRobots/f1/launch/f1.launch.py
lrwxrwxrwx root root 106 Jun 11  controller_moveit2.yaml -> /home/ws/src/Industrial/.../config/controller_moveit2.yaml
```

**`COPY --from=builder /home/ws/install /home/ws/install` copies symlinks verbatim.** The targets (`/home/ws/src/`) are never copied to the runtime stage. Every copied symlink becomes a dangling pointer. The runtime image would pass a casual inspection — the `install/` directory is present and all the expected files are listed — and then crash on the first exercise that loads a launch file, reads a YAML parameter, or parses a URDF.

This is the kind of failure that survives code review and only surfaces at runtime, after the multi-stage build appears to succeed.

**Fix:** Remove `--symlink-install` from both `colcon build` commands in the multi-stage Dockerfile. The builder stage compiles from source; the normal (non-symlink) install produces real copies. The runtime stage then gets `install/` with all files intact. The compiled `.so` files in `lib/` are already real files under `--symlink-install` — only the non-binary content is affected. No source code behaviour changes; this is a production-install vs development-install distinction.

### ament Resource Index

ROS 2 nodes discover packages, plugins, and typesupport at startup by reading marker files under `resource_index/`. `/opt/ros/humble/share/ament_index/` is owned by apt and will be present automatically in the runtime stage when the `ros-humble-*` packages are installed. The two workspace ament_index directories (`/home/drones_ws/install/share/ament_index/` and `/home/ws/install/share/ament_index/`) are colcon build artifacts and are covered by the `install/` COPY once `--symlink-install` is removed.

### Gazebo Resource Paths

Four of the eight paths in `GAZEBO_RESOURCE_PATH`, `GAZEBO_MODEL_PATH`, and `GZ_SIM_RESOURCE_PATH` are apt-owned and auto-present. The remaining four are build artifacts:

| Path | Origin | Action |
|---|---|---|
| `/usr/share/gazebo-11` and subdirs | `gazebo11` apt | None — auto-present |
| `/usr/lib/x86_64-linux-gnu/gazebo-11/plugins` | `gazebo11` apt | None — auto-present |
| `/opt/jderobot/Worlds` | `git clone RoboticsInfrastructure` in builder | **COPY from builder** |
| `/home/ws/install/custom_robots/share/` | colcon build | Covered by `install/` COPY |
| `/home/drones_ws/install/as2_gazebo_assets/share/` | colcon build | Covered by `install/` COPY |
| `/home/drones_ws/install/as2_gazebo_assets/lib/` | colcon build (Gazebo system plugins) | Covered by `install/` COPY |

`/opt/jderobot/Worlds` is the only Gazebo resource path that requires its own explicit `COPY` line — it comes from the `RoboticsInfrastructure` git clone and sits outside any colcon workspace.

### Dead Paths (ENOENT)

Two paths in `/.env` are sourced or exported at every container start but do not exist in the image:

| Path | Referenced in | Guard | Recommendation |
|---|---|---|---|
| `/workspace/worlds/install/setup.bash` | `/.env` line 7 | `&>/dev/null` | Remove from `/.env` — dead volume-mount scaffolding |
| `/workspace/code/libs` | `/.env` LD_LIBRARY_PATH | none | Remove from `/.env` — no `.so` files to search |

This is the same pattern as the `/home/dev_ws/install/local_setup.bash` dead reference found in Step 1. All three are accumulated cruft in `/.env` from workspace layouts that no longer exist. The refactor is the right time to remove them — they add noise to every bash subshell startup and would make the ENOENT behaviour permanent in the runtime stage.

### Complete COPY --from=builder List

Every path that must cross the stage boundary. Paths not listed here are either reinstalled from apt or re-created by a `RUN` command in the runtime stage.

```dockerfile
# Prerequisite: both colcon builds must omit --symlink-install
COPY --from=builder /home/drones_ws/install/   /home/drones_ws/install/
COPY --from=builder /home/ws/install/          /home/ws/install/

# RoboticsInfrastructure artifacts — outside any colcon workspace
COPY --from=builder /opt/jderobot/Launchers    /opt/jderobot/Launchers
COPY --from=builder /opt/jderobot/Worlds       /opt/jderobot/Worlds
COPY --from=builder /resources                 /resources

# RoboticsAcademy (Django + exercise code)
COPY --from=builder /RoboticsAcademy           /RoboticsAcademy

# Startup scripts (mv'd from RoboticsInfrastructure/scripts/ in builder)
COPY --from=builder /entrypoint.sh             /entrypoint.sh
COPY --from=builder /.env                      /.env
COPY --from=builder /ram_entrypoint.py         /ram_entrypoint.py
COPY --from=builder /start_vnc.sh              /start_vnc.sh
COPY --from=builder /start_vnc_gpu.sh          /start_vnc_gpu.sh
COPY --from=builder /kill_all.sh               /kill_all.sh
COPY --from=builder /set_dri_name.sh           /set_dri_name.sh
COPY --from=builder /check_ram_version.sh      /check_ram_version.sh
COPY --from=builder /check_device.py           /check_device.py

# Config files (not apt-owned; downloaded or mv'd during build)
COPY --from=builder /xorg.conf                                   /xorg.conf
COPY --from=builder /etc/xdg/openbox/LXDE/rc.xml                /etc/xdg/openbox/LXDE/rc.xml
COPY --from=builder /etc/ld.so.conf.d/nvidia-pip.conf           /etc/ld.so.conf.d/nvidia-pip.conf

# OMPL (built from source by install-ompl-ubuntu.sh)
COPY --from=builder /usr/local/lib/libompl.so.1.7.0             /usr/local/lib/libompl.so.1.7.0
COPY --from=builder /usr/local/lib/libompl.so.18                /usr/local/lib/libompl.so.18
COPY --from=builder /usr/local/lib/libompl.so                   /usr/local/lib/libompl.so
COPY --from=builder /usr/lib/python3/dist-packages/ompl/        /usr/lib/python3/dist-packages/ompl/

# ONNX Runtime C++ (installed by wget + tar in builder)
COPY --from=builder /usr/local/lib/libonnxruntime.so.1.22.0             /usr/local/lib/
COPY --from=builder /usr/local/lib/libonnxruntime.so.1                  /usr/local/lib/
COPY --from=builder /usr/local/lib/libonnxruntime.so                    /usr/local/lib/
COPY --from=builder /usr/local/lib/libonnxruntime_providers_shared.so   /usr/local/lib/

# noVNC (git clone in builder)
COPY --from=builder /noVNC                     /noVNC

# Trivial files re-created in runtime stage (no COPY needed)
RUN mkdir -p /root/.gazebo && touch /root/.gazebo/gui.ini \
 && mkdir -p /root/.roboticsacademy/log \
 && ldconfig
```

---

*More steps to follow as the audit progresses.*

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
