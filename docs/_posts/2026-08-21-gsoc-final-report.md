---
layout: single
title: "GSoC 2026 Final Report — Optimizing RoboticsAcademy's Container Infrastructure"
date: 2026-08-21
categories: [gsoc, final-report]
tags: [docker, gsoc2026, jderobot, podman, optimization, multi-stage-build, rootless, cuda, protobuf, cdi]
---

This is the final report for GSoC 2026 Project #7 with JdeRobot: exploring optimization strategies for the RoboticsBackend container. RoboticsAcademy ships a containerized environment bundling robotics middleware, simulators, libraries, and the application-management stack, so students can start learning robotics without setting up a development environment by hand. The project had two goals: cut the size and build time of that container image, and evaluate whether Podman could replace Docker in the build and run pipeline.

Hi 🤝, I'm Kartik, and this was my open source project this summer. I've been contributing to JdeRobot since January. I'm an ex-Research Intern at GahanAI, where I worked on a survey paper on humanoid robotics. My journey into ML started about a year ago, and I've been building on it ever since.

The starting point, measured during community bonding, was a 29.5GB image built across 30 layers, with a cold build taking 102 minutes 50 seconds.

My mentors on this project were David Pascual-Hernández, Javier Izquierdo, Md. Shariar Kabir, and Nikhil Gupta. Javier reviewed and merged the seven PRs that shipped from this work.

## What Exists Now

RoboticsBackend today is smaller than it was in May. My four merged pull requests below (cache cleanup, the ghost-layer fix, the PyTorch swap, and the ARG/ENV correctness fix) brought the shipped image from the 29.5GB baseline down to 18.2GB. Alongside that work, not after it, Javier merged his own parallel optimization removing legacy Gazebo 11 dependencies (PR #3875, merged 2026-06-23), which took the shipped image the rest of the way down to 10.7GB, a combined reduction of about 18.8GB, roughly 64%. RoboticsAcademy also has a documented, working path to run rootless under Podman with GPU passthrough, via three more merged pull requests, using nothing more exotic than `sudo apt install podman podman-compose` plus adding the user to the `video` and `render` groups.

Two things are tested but not shipped. A multi-stage rebuild of `Dockerfile.dependencies_humble` got the dependency image itself down to 9.55GB in testing, but that PR is on hold: the size win didn't justify the added build complexity, so it's still open and unmerged. A fix for a rootless file-permission bug is also still open, waiting on review.

One known limitation ships as-is rather than fixed: pressing Ctrl+C during `podman-compose up` does not stop the stack, because `podman-compose` 1.0.6 does not act on `SIGINT`. The workaround is a second terminal running `podman-compose down`.

## Phase 1: Shrinking the Image

### PR #3848 — Cache Cleanup 

Both Dockerfiles were leaking build cache into image layers: five apt cleanup blocks weren't removing apt's package lists, and pip installs across both files were missing `--no-cache-dir`. The fix normalized the apt cleanup and added the flag everywhere, and also dropped two packages, `netron` and `seaborn`, that David flagged as dead weight from an older version of the deep learning exercises.

Full image: 29.5GB to 26.4GB. The `dependencies_humble` base image alone dropped 3.4GB.

### PR #3856 — The Ghost Layer 

Cloning the `RoboticsInfrastructure` repo, moving its contents, then deleting its `.git` folder were three separate `RUN` instructions. Docker keeps every layer regardless of what a later instruction deletes since layers are read-only, so the original approx 4.6GB clone was baked into the image permanently even though nothing pointed at it anymore. Collapsing the three steps into one atomic `RUN` let Docker discard the intermediate state.

Full image: 26.4GB to 21.8GB.

### PR #3863 — PyTorch Out, CUDA Wheels In (merged 2026-06-12)
David told me in the meeting whether I could find a way to replace Pytorch with some libraries since we only do inferencing not training. PyTorch was installed with full CUDA support, but nothing in the codebase ever imports it: it was only there because it happened to bundle shared libraries that `onnxruntime-gpu` needed. The fix replaced it with the seven specific CUDA wheels `onnxruntime-gpu` actually needs, hard-pinned, plus a linker-cache entry so they survive ROS 2 workspace sourcing. In review, Javier caught a crash in Gazebo Harmonic exercises caused by a protobuf version conflict; the fix was forcing Python's pure protobuf implementation rather than pinning an older protobuf version that would have blocked future upgrades.

the net reduction was smaller not 4.7GB since the replacement wheels add weight back. After this merge, the `dependencies_humble` base sat at 12.8GB.

### PR #3890 — Two Small Correctness Fixes (merged 2026-07-20)

`NVIDIA_VISIBLE_DEVICES` had been declared as a Docker build `ARG`, which doesn't persist into the running container, so GPU visibility was silently broken at runtime for anything that relied on it directly. Changed to `ENV`. A second, unrelated fix removed a leftover `source` command that ran in its own throwaway shell and had no effect on the build that followed it. No size change; this PR was pure correctness.

### The Multi-Stage Build (PR #3900 — open, on hold, not merged)

The plan was to split `Dockerfile.dependencies_humble` into a builder stage and a slim runtime stage. That turned out to be harder than expected, mainly because `--symlink-install`, which the project can't drop since `RoboticsApplicationManager` calls it again at runtime, creates thousands of filesystem symlinks between the compiled output and the source tree, so the runtime stage has to carry a slice of source code too, not just binaries.

The first working split copied the builder's `/usr/local` wholesale into the runtime stage, which duplicated close to 3.5GB of pip packages already being reinstalled fresh, and the image came out bigger than the original. Replacing that with a handful of narrow, explicit `COPY` lines for just the compiled OMPL and onnxruntime libraries fixed the regression: the dependency image went from 11.9GB to 10.7GB. Two more bugs surfaced afterward, missing OMPL Python bindings and a missing `pg_dump` binary the admin panel needs, and fixing those brought the tested size to 9.55GB.

None of this shipped. Mentor's call was that an 11.9-to-10.7GB improvement didn't justify the added complexity, especially since the new stage still has to carry the full ROS toolchain and clean build time roughly doubled, from 20 to 40 minutes. PR #3900 has been open since July, still in draft, with the build-complexity question unresolved.

### PR #3953 — Rootless File Permissions (open, not merged)

Saving workspace files under Podman threw a blank "Error saving file" popup. The cause was five `os.chmod(path, 0o777)` calls that fail under rootless containers, since a rootless container's "root" can write to a file it doesn't own but can't change its permissions. World-writable permissions weren't needed in the first place, since Django is the only thing that manages these files, so the fix just removes all five calls. Still open, waiting on review.

## Phase 2: Podman, Rootless, and the GPU

Docker has a rootless mode too, but it still needs a background daemon and manual one-time setup. Podman is daemonless by design, which is the main reason it was worth investigating as a replacement.

The first Podman build attempt failed on an unqualified base image reference, since Podman, unlike Docker, won't assume Docker Hub by default. That was fixed through Podman's own registry config rather than editing the Dockerfile, and both Dockerfiles then built and ran cleanly.

Getting the full compose stack running took some setup work: starting Podman's user socket manually, working around a GPU config Podman couldn't interpret yet with a scratch compose file, and re-tagging images into Podman's separate image store. Once that was sorted, one exercise loaded end-to-end and responded to code, which was the goal for that pass. Separately, autosave threw a blank error popup on a file created back in May under regular Docker: rootless Podman can write new content into a file it doesn't own, but can't `chmod` it, which is the same bug class PR #3953 later fixes.

GPU passthrough needed the Container Device Interface (CDI) instead of Docker-style runtime hooks, and that surfaced the project's hardest bug: `nvidia-ctk`-generated CDI specs include a field, `additionalGids`, that Ubuntu 24.04's own Podman version (4.9.3) doesn't know how to parse, so it rejects the GPU spec outright and silently falls back to CPU. The development that first validated GPU passthrough had actually been done on a newer Podman (6.0.2, via Homebrew), which doesn't hit this problem. Switching to test against the real Ubuntu-shipped 4.9.3 reproduced the failure for real. The fix came from an already-filed upstream NVIDIA issue: generating the CDI spec with a compatibility flag produces an older-format spec 4.9.3 can read. Once pinned to 4.9.3, the rest of Ubuntu's own Podman toolchain worked without further changes, so the final documented install is just `sudo apt install podman podman-compose` plus adding the user to the `video` and `render` groups.

Along the way, GPU testing under rootless Podman also turned up three separate bugs: Ctrl+C corrupting the container network namespace and breaking DNS, a browser refresh freezing the VNC viewer because of zombie processes left behind by an unrelated Django error, and a camera widget failing on a ROS2 topic-namespace mismatch between an old image and a newer repo checkout. Despite all three, GPU passthrough itself was confirmed working: `vglrun glxinfo` correctly detected the GPU and offloaded rendering under a rootless container.

Two PRs shipped from this phase. PR #3959 (merged 2026-08-07) added new, purely additive Podman compose files using CDI for GPU access, with no existing files touched. PR #3960 (merged 2026-08-13) added a `-p` flag to the project's launcher scripts so they build and run through `podman-compose` instead of `docker compose`, while staying backward-compatible without the flag.

## Phase 3: Documentation

PR #3961 (merged 2026-08-13) added a standalone Podman setup guide covering installation, NVIDIA CDI setup, launching with `-p`, GPU verification, and migrating from Docker, linked in from the project's existing documentation without touching any of the Docker instructions.

## Demo Video

https://youtu.be/XqefB9AnR3w

## Pull Requests

| PR | Title | Status |
|---|---|---|
| [#3848](https://github.com/JdeRobot/RoboticsAcademy/pull/3848) | apt cache purge normalization and pip --no-cache-dir | Merged 2026-06-01 |
| [#3856](https://github.com/JdeRobot/RoboticsAcademy/pull/3856) | eliminate RoboticsInfrastructure ghost layer | Merged 2026-06-08 |
| [#3863](https://github.com/JdeRobot/RoboticsAcademy/pull/3863) | replace PyTorch with minimal CUDA runtime wheels | Merged 2026-06-12 |
| [#3890](https://github.com/JdeRobot/RoboticsAcademy/pull/3890) | correct NVIDIA_VISIBLE_DEVICES scope, remove no-op source | Merged 2026-07-20 |
| [#3900](https://github.com/JdeRobot/RoboticsAcademy/pull/3900) | multi-stage build for Dockerfile.dependencies_humble | **Open, draft — on hold, not merged** |
| [#3953](https://github.com/JdeRobot/RoboticsAcademy/pull/3953) | remove chmod 777 in filesystem layer for rootless compatibility | **Open — not merged** |
| [#3959](https://github.com/JdeRobot/RoboticsAcademy/pull/3959) | rootless Podman + NVIDIA CDI compose configurations | Merged 2026-08-07 |
| [#3960](https://github.com/JdeRobot/RoboticsAcademy/pull/3960) | add -p flag for rootless Podman to the launcher scripts | Merged 2026-08-13 |
| [#3961](https://github.com/JdeRobot/RoboticsAcademy/pull/3961) | add Podman documentation | Merged 2026-08-13 |

## Future Work

A CPU-only test of the Windows/WSL2 workflow got the web interface loading under rootless Podman, but the robot didn't respond to exercise code, and that actuation issue is unresolved. Two more PRs continue that direction: #3966 (Windows Podman GPU compose config) and #3973 (Docker Desktop WSL2 NVIDIA workflow support), both still open.

The Podman compose setup also has a maintenance problem worth fixing separately: 8 nearly-identical compose files, one for every combination of {user, dev} × {cpu, gpu, nvidia, nvidia-windows}, that all have to be updated together by hand.

## Challenges and What I Learned
The hardest problem for me was to write the perfect documentation which needs to be very simple but also covers everything so that any user or developer does not need to sit for hours to start using RoboticsAcademy with Podman. I was able to find a way to run it in my system, but finding out the simplest to run it in every system was challenging. The other major one was the Podman GPU passthrough bug: an undocumented `additionalGids` field in the CDI spec that Ubuntu's own shipped Podman couldn't parse, silently falling back to CPU with no error at all. Finding it meant realizing that the environment I'd been developing and testing against, a newer Podman installed via Homebrew, wasn't the environment a real user would have.

## Thanks

Thanks to my mentors on this project: David Pascual-Hernández and Javier Izquierdo, and Nikhil Gupta and Md. Shariar Kabir.

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
