---
layout: single
title: "Coding Week 5 — Two Fixes and a Refactor Plan"
date: 2026-06-28
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, optimization, multi-stage-build, nvidia, ros2]
---

Semester exams and VIVAs ran through most of the week. David knew going in, and the scope was set accordingly. Two things shipped.

## The NVIDIA Fix ([PR #3890](https://github.com/JdeRobot/RoboticsAcademy/pull/3890))

`Dockerfile.dependencies_humble` had this near the top:

```
ARG NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all
```

`ARG` variables exist only during the build — not written into any image layer, so the running container never sees them. `NVIDIA_VISIBLE_DEVICES` controls which GPUs the NVIDIA container runtime exposes. Setting it as `ARG` meant GPU visibility was silently broken at runtime. No error, no warning, just no GPUs. Changed to `ENV`.

The second fix: `Dockerfile.humble` had a standalone `source` call in its own `RUN` instruction before the `colcon build`. Docker starts a new shell for each `RUN`, so the sourced environment was gone before the next line ran. Dead line. Removed it.

Both fixes are one PR — small, isolated, and reviewable without touching the refactor.

## The Refactor Plan

Before touching any Dockerfile I wrote out the full multi-stage split as a design document. At this scale — two images, each with its own builder/runtime boundary, one `FROM` the other — getting the COPY boundaries wrong in code means broken container runs that are slow to diagnose. The structure: `Dockerfile.dependencies_humble` gets a builder that runs the full Aerostack2 build and a slim runtime that receives only the compiled artifacts. `Dockerfile.humble` chains off that slim runtime, adds its own builder to compile `/home/ws/`, and produces the shipped image.

The key finding that changed what gets `COPY --from`'d came from the `--symlink-install` verification done in Week 4. The assumption was that it writes `.pth` files for Python packages, meaning only a few small `src/` directories would need to travel with `install/`. Running `find` inside both images returned zero `.pth` files. What `--symlink-install` actually produces is filesystem symlinks — 3,206 from `/home/ws/install/` back into `/home/ws/src/`, and 347 from `/home/drones_ws/install/` back into `/home/drones_ws/src/`. Copying `install/` alone into the runtime stage leaves all of those dangling. The minimal subset of `src/` the symlink graph requires has to be traced from the links — that question goes to the mentor before implementation starts.

The 83 `NEEDS_CLARIFICATION` packages from the Week 4 audit are kept as-is in the plan. Their classification needs confirmation before they can be moved or dropped.

The implementation is split into sequential PRs — one per Dockerfile — so each can be built and tested before the next opens.

Next week is implementation, starting with the builder/runtime stage skeleton for `Dockerfile.dependencies_humble`.

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
