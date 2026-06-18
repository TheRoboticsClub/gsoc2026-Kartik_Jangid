---
layout: single
title: "Coding Week 4 — Pre-Refactoring Audit"
date: 2026-06-18
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, optimization, multi-stage-build, entrypoint, ros2]
---

## Week 4 — Pre-Refactoring Audit

Before writing a single line of the multi-stage Dockerfile, I ran a structured read-only audit of the existing image across six steps.

**What I found that matters:**

- `NVIDIA_VISIBLE_DEVICES` is declared as `ARG` not `ENV` in `Dockerfile.dependencies_humble`. The NVIDIA container runtime reads this from the running container's environment — an `ARG` does not persist into the image, so GPU access is silently unavailable regardless of `--gpus` flags passed at runtime.

- `/.env` unconditionally sources `/home/dev_ws/install/local_setup.bash`, a workspace no Dockerfile ever builds. Every bash subshell startup prints a silent `No such file or directory` error; this path and two others (`/workspace/worlds/install/setup.bash`, `/workspace/code/libs`) are accumulated cruft to remove in the refactor.

- There is no `.dockerignore` anywhere in the repository. The current build is safe only because `build.sh` uses `scripts/RADI/` (41 MB) as context. Running `docker build` from the repo root without one sends 6.6 GB to the daemon — `.git/` is 2.3 GB, `RoboticsInfrastructure/` is 3.2 GB, `react_frontend/node_modules/` is 851 MB — all sent, none needed.

- `postgresql-18` (full server) is installed in the RADI container, which only ever connects to the database via psycopg2. `ldd` on psycopg2's C extension confirmed it links `/lib/x86_64-linux-gnu/libpq.so.5`, owned by the standalone `libpq5` package. The server, its client tools, and all `postgresql-*` meta-packages are dead weight.

- Both colcon workspaces were built with `--symlink-install`. Every launch file, YAML, URDF, and Python script in `install/` is a symlink back into `src/`. A `COPY --from=builder /home/ws/install /home/ws/install` copies the symlinks verbatim — `src/` is never copied — leaving thousands of dangling pointers in a runtime image that looks correct but crashes on the first exercise load.

- Poco libraries have zero runtime linkage across 500+ `.so` files in the ROS humble installation, all three custom workspaces, MoveIt, and Gazebo. `apt-cache rdepends --installed libpocofoundation80` showed only other Poco packages as dependents. All five `libpoco*80` packages are dropped from the runtime stage entirely.

**Next:** Steps 7 and 8 (cache wall mapping, user and permissions audit), then the Dockerfile.

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
