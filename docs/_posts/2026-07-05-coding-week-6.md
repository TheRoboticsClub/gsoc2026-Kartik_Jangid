---
layout: single
title: "Coding Week 6 — First Multi-Stage Build, First Regression"
date: 2026-07-05
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, optimization, multi-stage-build, ros2]
---

The goal this week was to actually build the multi-stage split I designed last week: turn `Dockerfile.dependencies_humble` into a `deps-builder` stage and a `deps-final` stage (`Dockerfile.dependencies_humble.multistage:1` and `:393`), without changing how either ROS workspace compiles — no touching colcon invocations, no touching `--symlink-install`.

## Skeleton First

First pass had `deps-final` do a wholesale `COPY --from=deps-builder / /`. I checked every `ENV`, `WORKDIR`, and `ARG` against the builder stage line by line — all carried across correctly. Then I built `Dockerfile.humble` unedited on top of it and ran the full smoke test: Django, the RAM websocket, noVNC after launching an exercise, and an `ldd` sweep across the compiled workspace libraries. All clean, so the boundary itself was sound before I started trimming anything.

## The Toolchain Question

`Dockerfile.humble:68` runs its own `colcon build` on top of this image, compiling `CustomRobots`, `jderobot_drones`, `Industrial`, and `common_interfaces_cpp` (moved into `/home/ws/src/` at line 27). That means `deps-final` can't be pure runtime — it has to keep the full ROS build toolchain. I confirmed that with the mentor before dropping anything.

So instead of stripping the toolchain, I went looking for what was genuinely dead weight. A boot/launch call-graph trace through `entrypoint.sh`, `manager.py`, and the launcher scripts found `tmux`/`tmuxinator` had zero invocations anywhere — just a bash-completion stub. `postgresql-18` (line 135 in the original) became `libpq5` at line 482, once I confirmed the Postgres server binary is never started in this image; only `psycopg2` links against the client library.

The harder cases needed evidence, not assumptions. I ran `ldd` across every compiled binary and mapped each shared library back to its owning apt package with `dpkg -S`, then cross-referenced every pip package against actual `import` statements in the codebase. Two results went against what I expected going in: `onnxruntime-gpu` and its CUDA wheels showed zero `ldd`/import evidence, but three exercise templates compile against onnxruntime's C++ API at exercise-load time — invisible to static analysis, so it stays. And `pylint`, `black`, and `jedi` turned out to be declared runtime dependencies of the RAM's web IDE in `pyproject.toml`, not leftover dev tooling like I'd assumed.

## The Regression

The first complete `deps-final` build came out larger than the original single-stage image — the opposite of the point of doing this. `docker history` plus `dive`'s wasted-space report traced it to a blanket `COPY --from=deps-builder /usr/local/ /usr/local/` duplicating about 3.5GB that five separate pip `RUN` blocks in the same stage were already reinstalling fresh. I replaced it with narrow, explicit `COPY` lines (615–626) for the only non-pip content actually under `/usr/local`: OMPL and onnxruntime's compiled C++ libraries, about 40MB total.

Separately, the downstream build broke: pulling `lxde-common` into a consolidated `--no-install-recommends` block silently dropped its auto-pulled companions, `lxde-core` and `openbox-lxde-session`, which `Dockerfile.humble` needs to place `rc.xml` into a directory only those packages create. Fixed by installing `lxde-common` on its own unflagged line (540), matching how the original file already had it.

## Where This Landed

Same-day rebuild of both versions for a fair comparison: the original single-stage image is 11.9GB, `deps-final` is 10.7GB — confirmed with `docker history`, a full `ldd` sweep across both workspaces, and an endpoint test through `docker compose` covering Django routes, DB-backed queries, the RAM websocket handshake, and clean shutdown. The split works and is smaller, which was the point of the week.

## Still Open

Loading an exercise through `docker compose` returns `relation "exercises" does not exist`, even with Postgres reporting healthy. Not yet clear whether this is a stale data volume from earlier test runs or an issue with how the init SQL files load — tracking that down next.

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
