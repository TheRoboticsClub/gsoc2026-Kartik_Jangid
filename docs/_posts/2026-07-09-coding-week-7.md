---
layout: single
title: "Coding Week 7 — Dependency Fixes, First Podman Build"
date: 2026-07-09
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, optimization, multi-stage-build, ros2, postgresql, podman]
---

Half-week post — mentor review reopened two things in the split, and the rest went into a first Podman build test.

Mentor review on the split: 11.9GB to 10.7GB didn't justify the added complexity, and clean build time roughly doubled — 20 to 40 minutes — since `deps-final` keeps the full ROS toolchain, paying colcon's cost twice. Also flagged: the narrow `/usr/local` COPY from the size-regression fix had silently broken OMPL's Python bindings and `pg_dump`.

OMPL's bindings install via `install-ompl-ubuntu.sh --python` into `/usr/lib/python3/dist-packages/ompl/`, not `/usr/local`, so that COPY missed them — fixed with one more explicit COPY at `Dockerfile.dependencies_humble:598`. `pg_dump` was missing outright: `deps-final` only had `libpq5`, and the admin section's `save_exercise_db`/`save_universe_db` views call it directly. Added `postgresql-client-18` at line 463, pinned because the database container runs Postgres 18 and `pg_dump` won't dump a newer server than itself. That surfaced a second bug: `deps-final` had PGDG's source copied in before `ca-certificates` existed, so the HTTPS fetch to `apt.postgresql.org` failed. Fixed with a `ca-certificates`-only install at line 414, ahead of the PGDG COPY, matching `deps-builder`'s order.

Verified both directly: imported OMPL's bindings, ran `pg_dump` against a live Postgres 18 container. Net size: 9.55GB, up slightly from 9.49GB before these fixes, still under the 11.9GB baseline — not pushing size further for now.

## First Podman Build

Set up a `podman-compat-test` branch off `humble-devel` with the original Dockerfiles, kept separate from the refactor so results don't mix. First failure: `Dockerfile.dependencies_humble`'s `FROM` line — Podman needs a configured registry for unqualified image names; Docker just defaults to Docker Hub. Fixed with a one-time system config — added `docker.io` to `/etc/containers/registries.conf.d` — not a Dockerfile change.

After that, both Dockerfiles built clean under Podman unmodified — 26 workspace packages compiled. Running it standalone, GPU detection found nothing and fell back to CPU-only without crashing (no GPU needed for this pass), and Django plus the RAM manager's websocket server both started. The only error was Django failing to reach a nonexistent database host — expected in a standalone run, same as plain Docker with no DB present.

![podman run of the built dependencies image, showing a clean start with no GPU]({{ "/assets/images/week7/podman_run_1st.png" | relative_url }})

Next is the full compose stack under Podman. The compose file requests GPU reservations Podman can't interpret, so I'm preparing a GPU-free variant — then the goal is launching one exercise inside RA to confirm end-to-end compatibility.

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
