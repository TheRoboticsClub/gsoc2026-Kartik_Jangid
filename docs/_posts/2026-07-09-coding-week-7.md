---
layout: single
title: "Coding Week 7 — Two Regressions from the Size Fix"
date: 2026-07-09
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, optimization, multi-stage-build, ros2, postgresql]
---

Short update - the back half of the week goes toward starting Podman testing, so there isn't a full week of Dockerfile work here.

Had a mentor review on the multi-stage split. Feedback: 11.9GB to 10.7GB wasn't enough of a cut to justify the added Dockerfile complexity on its own, and clean build time roughly doubled, 20 minutes to 40, since keeping the full ROS toolchain in `deps-final` means paying colcon's build cost twice. Also flagged: the narrow `/usr/local` COPY from the size-regression fix had silently broken OMPL's Python bindings and `pg_dump`.

The OMPL gap traced to `install-ompl-ubuntu.sh --python`, which installs the SWIG-generated bindings into `/usr/lib/python3/dist-packages/ompl/`, not under `/usr/local` — outside what that COPY was scoped to. Fixed with one more explicit COPY line, at `Dockerfile.dependencies_humble:598`, for that exact path.

The `pg_dump` gap was a missing binary — `deps-final` only had `libpq5`, the C library `psycopg2` links against, no client tool, and the admin section's `save_exercise_db`/`save_universe_db` views call `pg_dump` directly. Added `postgresql-client-18` at line 463, pinned to that version because the database container runs Postgres 18 and `pg_dump` refuses to dump a server newer than itself — default Ubuntu `postgresql-client` is v14.

That package surfaced a second bug: `deps-builder` installs `ca-certificates` before registering the PGDG apt source, so the HTTPS fetch to `apt.postgresql.org` is trusted by the time it runs. `deps-final`'s block had PGDG's source arriving via COPY before `ca-certificates` existed, so the fetch failed with "No system certificates available." Fixed with a `ca-certificates`-only install at line 414, ahead of the PGDG COPY, matching `deps-builder`'s order.

Verified both directly: imported OMPL's bindings inside the built image, and ran `pg_dump` against a live Postgres 18 container on a throwaway network, proving the version match actually works.

Net size after both fixes: 9.55GB(for the base), before it was 9.49GB. Given the mentor's complexity/build-time concerns, I'm not pushing size optimization further for now.

Rebuilding `Dockerfile.humble` on the fixed image and re-running endpoint checks is done. The rest of this week is starting Podman: checking whether the RoboticsAcademy image builds and runs under it at all,Learning how does Podman work and how does the daemonless architecture of Podman can be exectuted, no GPU acceleration yet, success meaning a clean compile and one exercise launching.

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
