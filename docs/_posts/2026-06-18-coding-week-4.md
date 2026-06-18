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

*More steps to follow as the audit progresses.*

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
