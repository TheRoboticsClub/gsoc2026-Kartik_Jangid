---
layout: single
title: "GSoC 2026 Final Report — Optimizing RoboticsAcademy's Container Infrastructure"
date: 2026-08-21
categories: [gsoc, final-report]
tags: [docker, gsoc2026, jderobot, podman, optimization, multi-stage-build, rootless, cuda, protobuf, cdi]
---

This is the final report for GSoC 2026 Project #7 with JdeRobot: optimizing the RoboticsBackend container. The project had two goals: cut the container's size and build time, and evaluate replacing Docker with Podman.

Hi 🤝, I'm Kartik. This was my open source project this summer. I've contributed to JdeRobot since January, and before that was a Research Intern at GahanAI, working on a humanoid robotics survey paper. My ML journey started about a year ago.

The starting point, measured during community bonding, was a 29.5GB image built across 30 layers, with a cold build taking 102 minutes 50 seconds.

My mentors were David Pascual-Hernández, Javier Izquierdo, Md. Shariar Kabir, and Nikhil Gupta. Javier reviewed and merged the seven PRs that shipped.

## What Exists Now

RoboticsBackend is smaller than it was in May. My four merged PRs (cache cleanup, the ghost-layer fix, the PyTorch swap, the ARG/ENV fix) brought the image from 29.5GB to 18.2GB. Alongside that, not after it, Javier's parallel PR removing legacy Gazebo 11 dependencies (#3875, merged 2026-06-23) took it to 10.7GB, a combined 18.8GB drop, roughly 64%. A working rootless-Podman path with GPU passthrough also exists via three more merged PRs: `sudo apt install podman podman-compose` plus the `video` and `render` groups.

Two things are tested but not shipped: a multi-stage rebuild of `Dockerfile.dependencies_humble` reached 9.55GB in testing, but it's on hold since the size win didn't justify the build complexity. A rootless file-permission fix is also open.

One known limitation ships as-is: Ctrl+C during `podman-compose up` doesn't stop the stack, since `podman-compose` 1.0.6 doesn't act on `SIGINT`. Workaround: a second terminal running `podman-compose down`.

## Phase 1: Shrinking the Image

### PR #3848 — Cache Cleanup

Both Dockerfiles were leaking build cache: apt cleanup wasn't clearing package lists, and pip installs were missing `--no-cache-dir`. Both fixed, along with two dead packages, `netron` and `seaborn`. Full image: 29.5GB to 26.4GB; `dependencies_humble` dropped 3.4GB.

### PR #3856 — The Ghost Layer

Cloning `RoboticsInfrastructure`, moving its contents, then deleting `.git` were three separate `RUN` instructions, so the ~4.6GB clone stayed baked in regardless. One atomic `RUN` fixed it. Full image: 26.4GB to 21.8GB.

### PR #3863 — PyTorch Out, CUDA Wheels In (merged 2026-06-12)

David asked whether I could replace PyTorch with something lighter, since we only do inferencing, not training. The fix swapped in seven hard-pinned CUDA wheels plus a linker-cache entry to survive ROS 2 sourcing; Javier caught a protobuf crash in review, fixed by forcing Python's pure protobuf implementation. Net reduction was smaller than the claimed 4.7GB; `dependencies_humble` sat at 12.8GB after merge.

### PR #3890 — Two Small Correctness Fixes (merged 2026-07-20)

`NVIDIA_VISIBLE_DEVICES` had been a build `ARG`, silently breaking GPU visibility; changed to `ENV`. A second fix removed a dead `source` command with no effect. No size change; pure correctness.

### The Multi-Stage Build (PR #3900 — open, on hold, not merged)

The plan was to split `Dockerfile.dependencies_humble` into a builder and a slim runtime stage, harder than expected since part of the source tree is still needed at runtime. Fixing an early regression brought the image from 11.9GB to 10.7GB, later refined to 9.55GB. It didn't ship: build time roughly doubled, from 20 to 40 minutes, so it's been open since July, still in draft.

### PR #3953 — Rootless File Permissions (open, not merged)

Saving workspace files under Podman threw a blank error popup: five `os.chmod(path, 0o777)` calls fail under rootless containers, since Podman's "root" can write to a file it doesn't own but can't change its permissions. The fix removes all five calls. Still open.

## Phase 2: Podman, Rootless, and the GPU

Docker has a rootless mode too, but needs a daemon and manual setup; Podman is daemonless by design. The first Podman build failed on an unqualified base image reference, since Podman won't assume Docker Hub by default. Fixed via Podman's registry config, not the Dockerfile.

Getting the compose stack running took setup around Podman's socket and image store. Autosave also failed on a file created under Docker: rootless Podman can write new content into a file it doesn't own, but can't `chmod` it, the same bug PR #3953 later fixes.

GPU passthrough needed the Container Device Interface (CDI) instead of Docker-style runtime hooks, which surfaced the hardest bug: `nvidia-ctk` generates CDI specs with a field, `additionalGids`, that Ubuntu 24.04's shipped Podman (4.9.3) can't parse, silently falling back to CPU. The passthrough that first worked had been tested on Podman 6.0.2; the real 4.9.3 reproduced the failure. The fix, from an upstream NVIDIA issue, was a compatibility flag generating an older-format spec 4.9.3 can read. Once pinned, it's just `sudo apt install podman podman-compose` plus the `video` and `render` groups. Passthrough was then confirmed working via `vglrun glxinfo`.

Two PRs shipped here: #3959 (2026-08-07), new CDI compose files, and #3960 (2026-08-13), a `-p` flag switching launcher scripts to `podman-compose`.

## Phase 3: Documentation

PR #3961 (merged 2026-08-13) added a standalone Podman setup guide: install, CDI setup, `-p` launch, GPU verification, and Docker migration, linked from existing docs.

## Demo Video

https://youtu.be/XqefB9AnR3w

## Pull Requests

| PR | Title | Status |
|---|---|---|
| [#3848](https://github.com/JdeRobot/RoboticsAcademy/pull/3848) | apt cache cleanup, pip --no-cache-dir | Merged 2026-06-01 |
| [#3856](https://github.com/JdeRobot/RoboticsAcademy/pull/3856) | eliminate RoboticsInfrastructure ghost layer | Merged 2026-06-08 |
| [#3863](https://github.com/JdeRobot/RoboticsAcademy/pull/3863) | replace PyTorch with minimal CUDA wheels | Merged 2026-06-12 |
| [#3890](https://github.com/JdeRobot/RoboticsAcademy/pull/3890) | fix NVIDIA_VISIBLE_DEVICES scope, remove no-op source | Merged 2026-07-20 |
| [#3900](https://github.com/JdeRobot/RoboticsAcademy/pull/3900) | multi-stage build for Dockerfile.dependencies_humble | **Open, draft — on hold, not merged** |
| [#3953](https://github.com/JdeRobot/RoboticsAcademy/pull/3953) | remove chmod 777 for rootless compatibility | **Open — not merged** |
| [#3959](https://github.com/JdeRobot/RoboticsAcademy/pull/3959) | rootless Podman + NVIDIA CDI compose files | Merged 2026-08-07 |
| [#3960](https://github.com/JdeRobot/RoboticsAcademy/pull/3960) | add -p flag to launcher scripts | Merged 2026-08-13 |
| [#3961](https://github.com/JdeRobot/RoboticsAcademy/pull/3961) | add Podman documentation | Merged 2026-08-13 |

## Future Work

A CPU-only Windows/WSL2 test loaded the web interface under rootless Podman, but the robot didn't respond to exercise code. Two more PRs continue that direction: #3966 (Windows GPU compose) and #3973 (WSL2 NVIDIA workflow). The compose setup also has 8 nearly-identical files across {user, dev} × {cpu, gpu, nvidia, nvidia-windows} needing updates.

## Challenges and What I Learned

The hardest problem for me was to write the perfect documentation which needs to be very simple but also covers everything so that any user or developer does not need to sit for hours to start using RoboticsAcademy with Podman. I was able to find a way to run it in my system, but finding out the simplest to run it in every system was challenging. The other major one was the Podman GPU passthrough bug: an undocumented `additionalGids` field in the CDI spec that Ubuntu's own shipped Podman couldn't parse, silently falling back to CPU with no error at all. Finding it meant realizing that the environment I'd been developing and testing against, a newer Podman installed via Homebrew, wasn't the environment a real user would have.

## Thanks

Thanks to my mentors on this project: David Pascual-Hernández and Javier Izquierdo, and Nikhil Gupta and Md. Shariar Kabir.

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
