---
layout: single
title: "Coding Week 6 — First Multi-Stage Build, First Regression"
date: 2026-07-05
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, optimization, multi-stage-build, ros2]
---

The goal this week was to actually build the multi-stage split I designed last week: turn `Dockerfile.dependencies_humble` into two stages, a `deps-builder` and a `deps-final`, without changing how either ROS workspace compiles. No touching colcon invocations, no touching `--symlink-install`.

I worked in a .multistage copy of the file the entire time, leaving Dockerfile.dependencies_humble itself untouched until the split was fully verified — safer to break a throwaway file fifty times over than the one file everyone else's builds actually depend on.

## Skeleton First

First pass was just the skeleton. `deps-final` did a wholesale `COPY --from=deps-builder / /`, and I went through every `ENV`, `WORKDIR`, and `ARG` by hand to make sure each one carried across the stage boundary correctly. It did. Then I built `Dockerfile.humble` unedited on top of that image and ran it through the full smoke test — Django, the RAM websocket, noVNC once an exercise launches, an `ldd` sweep across the compiled workspace libraries. Everything came back clean, so the boundary itself wasn't the problem, which was a good place to start before touching anything else.

## The Toolchain Question

`Dockerfile.humble` runs its own `colcon build` on top of this image to compile `CustomRobots`, `jderobot_drones`, `Industrial`, and `common_interfaces_cpp`, which get moved into `/home/ws/src/` a few lines earlier. That one call site means `deps-final` can't be a stripped-down runtime image — it has to keep the full ROS build toolchain. I ran that by the mentor before dropping anything, since getting it wrong would mean a broken downstream build with a confusing error months from now.

So the trimming ended up narrower than I'd planned. Tracing through `entrypoint.sh`, `manager.py`, and the launcher scripts for anything that actually runs at boot or exercise-launch time turned up `tmux` and `tmuxinator` with zero invocations anywhere, just a leftover bash-completion stub. `postgresql-18` became `libpq5` once I confirmed the Postgres server binary itself never starts inside this image — only `psycopg2` needs the client library to link against.

The harder calls needed more than a grep. I ran `ldd` across every compiled binary in the image, matched each shared library back to its apt package with `dpkg -S`, and checked every pip package against real `import` statements in the codebase. Two of those checks went against what I expected going in. `onnxruntime-gpu` and its CUDA wheels showed no `ldd` or import evidence anywhere, but three exercise templates compile against onnxruntime's C++ API at load time — nothing static analysis would ever catch, so it stays. And `pylint`, `black`, and `jedi`, which I'd have called dev tooling on sight, turned out to be declared runtime dependencies of the RAM's web IDE in its `pyproject.toml`.

## The Regression

The first full `deps-final` build came out bigger than the original single-stage image, which is the opposite of the entire point. `docker history` and `dive`'s wasted-space report pointed at a blanket `COPY --from=deps-builder /usr/local/ /usr/local/` — it was dragging across roughly 3.5GB that five separate pip `RUN` blocks in that same stage were already reinstalling from scratch. I swapped it for a handful of explicit `COPY` lines that only pull the non-pip content actually living under `/usr/local`: OMPL and onnxruntime's compiled C++ libraries, about 40MB total.

A second, unrelated break showed up downstream. Folding `lxde-common` into a consolidated `--no-install-recommends` apt block silently dropped the two packages it normally pulls in with it, `lxde-core` and `openbox-lxde-session` — and `Dockerfile.humble` needs those to place `rc.xml` into a directory only they create. Putting `lxde-common` back on its own unflagged line, the way the original file already had it, fixed the build.

## Where This Landed

I rebuilt both versions the same day for a fair comparison: the original single-stage image is 11.9GB, `deps-final` comes in at 10.7GB. Checked that with `docker history`, another `ldd` sweep across both workspaces, and a full pass through `docker compose` — Django routes, DB-backed queries, the RAM websocket handshake, clean shutdown. The split holds together and it's smaller, which was the actual goal for the week.

## Still Open

Loading an exercise through `docker compose` throws `relation "exercises" does not exist`, even though Postgres itself reports healthy. I don't yet know if that's a stale data volume left over from earlier test runs or something in how the init SQL files get loaded — that's what I'm chasing next.

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
