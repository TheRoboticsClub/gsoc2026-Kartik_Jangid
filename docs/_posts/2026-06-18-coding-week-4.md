---
layout: single
title: "Coding Week 4 — Pre-Refactoring Audit"
date: 2026-06-18
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, optimization, multi-stage-build, entrypoint, ros2]
---

## Week 4 — Pre-Refactoring Audit

Before touching the Dockerfile, I spent this week doing a read-only audit of the existing RADI image. The goal was to understand exactly what the current build produces before splitting it — the kind of thing where if you skip it, you spend two days debugging a runtime image that looks right but isn't.

A few things came up that directly affect how the multi-stage split needs to work.

The GPU issue is a correctness bug: `NVIDIA_VISIBLE_DEVICES` is declared as `ARG` in `Dockerfile.dependencies_humble`, not `ENV`. The NVIDIA container runtime reads this variable from the running container's environment — an `ARG` exists only during the build and doesn't persist into the image. So even with `--gpus all` at runtime, the container never sees it. This needs to be fixed in the runtime stage.

Before the first build from the new Dockerfile, I also need to add a `.dockerignore` at the repo root. There isn't one. The current build is safe only because `build.sh` points Docker at a 41 MB subdirectory as its context — but once the multi-stage Dockerfile lives at the repo root, running `docker build .` without `.dockerignore` sends 6.6 GB to the daemon: `.git/` alone is 2.3 GB.

On the package side: the full `postgresql-18` server is installed in RADI, but the container only ever connects to the database via psycopg2. I ran `ldd` on psycopg2's C extension — it links `libpq.so.5`, which belongs to the standalone `libpq5` package. The full server, client tools, and all the `postgresql-*` meta-packages are dead weight in the runtime stage, and swapping them out is a meaningful size reduction.

The other thing that would silently break the runtime image: both colcon workspaces were built with `--symlink-install`. In that mode, every launch file, YAML, and Python script in `install/` is a symlink back into `src/`. A `COPY --from=builder` of the install directory copies those symlinks verbatim — `src/` never comes across — so the runtime image ends up with thousands of dangling pointers. I need to drop `--symlink-install` from both colcon builds in the builder stage.

Still working through the remaining audit steps before writing the Dockerfile.

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
