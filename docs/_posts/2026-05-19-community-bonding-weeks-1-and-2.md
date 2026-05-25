---
layout: single
title: "Community Bonding: Weeks 1 & 2"
date: 2026-05-19 08:00:00 -0000
published: true
categories: [gsoc, community-bonding]
tags: [docker, podman, ros2, robotics, gsoc2026, jderobot]
author: Kartik Jangid
---

![JdeRobot GSoC 2026]({{ "/assets/images/logo.png" | relative_url }})

I got selected for GSoC 2026 with **JdeRobot**, and the first two weeks had one clear goal: understand the platform deeply enough to know exactly what will break when I change it. Before you can optimize a **29.5 GB** Docker image, you need to know why every gigabyte is there. That is what Weeks 1 and 2 were for — not guessing, but measuring.

My project is Project #7 — Optimizing RoboticsAcademy Infrastructure. It has three goals. First, reduce the size and build time of the `jderobot/robotics-academy` Docker image, which currently sits at **29.5 GB** uncompressed — a serious barrier for students and contributors with limited disk space or slow internet. The primary targets are OMPL (takes **34 minutes** to compile from source, leaves **1.5 GB** of build artifacts on disk) and Aerostack2 (takes nearly **14 minutes** to build, leaves **463 MB** of dead weight). Second, migrate the runtime from Docker to a daemonless, rootless **Podman** architecture for better security, including GPU acceleration via the **Container Device Interface (CDI)**. Third, restructure the build into a proper multi-stage pipeline so compiler toolchains, source trees, and build artifacts never make it into the final runtime image. These two weeks were about collecting the baseline measurements that will prove the optimization worked.

---

## Test Environment

All build time measurements in this post were recorded on a Lenovo Legion 5 with AMD Ryzen 5 4600H, NVIDIA GTX 1650, and **16 GB RAM** running Kubuntu Linux. These numbers represent a mid-range developer machine — not a CI server — so they reflect realistic local build times a contributor would experience.

---

## The Mentor Team

Before I get into the work, I want to introduce the mentors I'm working with — they've been genuinely helpful from the start.

- **David Pascual-Hernández** — He leads our weekly syncs, keeps the project direction on track, and is the main person I check in with when I need to validate an approach.
- **Javier I.** — Most of the deeper architecture and code questions go to Javier. Whenever I'm confused about how something fits together in the stack, he's the one I ask.
- **Md. Shariar Kabir** — Official mentor for this project. Has been available throughout the bonding period and brings direct experience with the JdeRobot infrastructure.
- **Nikhil Gupta** — official mentor, has been available for questions during the bonding period.

---

## Week 1 — Setting Up Locally

The first priority was getting the full stack running locally on my machine — a Lenovo Legion 5 with Ryzen 5 4600H, GTX 1650, and **16 GB RAM** running Kubuntu. This meant pulling `jderobot/robotics-academy:latest` (**29.5 GB**) and `jderobot/robotics-database:latest` (**486 MB**), setting up the NVIDIA Container Toolkit, configuring the NVIDIA runtime in `/etc/docker/daemon.json`, and verifying that Django was reachable on **port 7164**.

![Local Setup]({{ "/assets/images/local_setup.png" | relative_url }})

![JdeRobot Logo]({{ "/assets/images/JdeRobot_Gsoc_Logo.webp" | relative_url }})

The kickoff meeting with David covered project milestones and set expectations for the coding period. One piece of advice that turned out to be useful early: do not assume this stack works like a standard web application. The Django server is not what runs student code — that distinction became important in Week 2.

---

## Week 2 — Looking at the Dockerfile

With the environment confirmed working, Week 2 was entirely about measurement. The production image is built from three Dockerfiles in sequence: `Dockerfile.dependencies_humble` builds the base from `nvidia/opengl:1.2-glvnd-runtime-ubuntu22.04`, `Dockerfile.humble` layers the RoboticsAcademy application on top, and `Dockerfile.database` builds an independent PostgreSQL image. The first question was simple: where does the **29.5 GB** actually come from?

I ran a few `grep` commands directly on the file to get a concrete count.

```bash
# Count all layer-altering instructions
grep -cE '^(RUN|COPY|ADD)' Dockerfile.dependencies_humble

# Count separate apt-get install blocks
grep -c 'apt-get install' Dockerfile.dependencies_humble

# Count cache purges
grep -c 'rm -rf /var/lib/apt/lists/\*' Dockerfile.dependencies_humble
```

| Metric | Count |
|---|---|
| Total layer-altering instructions (`RUN`, `COPY`, `ADD`) | **59** |
| Independent `apt-get install` blocks | **17** |
| `rm -rf /var/lib/apt/lists/*` cache purges | **12** |
| Net leaking layers | **≥ 4** |

The static grep analysis gave us the structure of the problem — **59** layer-altering instructions, **17** separate apt install blocks, and at least **4** layers leaking apt cache. But structure alone does not tell you where the gigabytes and the minutes go. That required running actual measurements against the pulled image, which the sections below document in full.

### Current Image Size Baseline

The current production image `jderobot/robotics-academy:latest` has the following measured profile:

- **Total uncompressed size: 29.5 GB**
- **Total layers: 30**
- **Build pipeline: 3 Dockerfiles in sequence**
  - `Dockerfile.dependencies_humble` — builds on `nvidia/opengl:1.2-glvnd-runtime-ubuntu22.04`
  - `Dockerfile.humble` — builds on top of the dependencies image
  - `Dockerfile.database` — independent, builds on `postgres:18`, final size **486 MB**

These numbers were obtained by running `docker images` and `docker history --no-trunc --format` against the pulled production image.

### Layer-by-Layer Size Breakdown

Running `docker history jderobot/robotics-academy:latest --no-trunc --format "{{.Size}}\t{{.CreatedBy}}" | sort -h -r` produces a ranked list of every layer by size. The top 30 layers sorted largest first:

| Rank | Layer Size | What It Does | Which Dockerfile |
|---|---|---|---|
| 1 | **7.9 GB** | pip install torch with CUDA 12.8 support | `Dockerfile.dependencies_humble` |
| 2 | **4.61 GB** | git clone RoboticsInfrastructure (shallow, --depth 1) | `Dockerfile.humble` |
| 3 | **2.91 GB** | mv packages from clone into ROS2 workspace | `Dockerfile.humble` |
| 4 | **2.39 GB** | install-ompl-ubuntu.sh — compile OMPL from source | `Dockerfile.dependencies_humble` |
| 5 | **1.87 GB** | apt-get install gazebo11 + gstreamer plugins | `Dockerfile.dependencies_humble` |
| 6 | **1.78 GB** | yarn install && yarn run build React frontend | `Dockerfile.humble` |
| 7 | **1.3 GB** | pip install ML packages (onnxruntime-gpu, opencv, numpy) | `Dockerfile.dependencies_humble` |
| 8 | **628 MB** | colcon build && colcon build IndustrialRobots workspace | `Dockerfile.dependencies_humble` |
| 9 | **594 MB** | apt-get install ros-humble-ros-base + rviz2 + colcon | `Dockerfile.dependencies_humble` |
| 10 | **580 MB** | apt-get install libpcl-dev + ros-humble-pcl-ros | `Dockerfile.dependencies_humble` |
| 11 | **559 MB** | apt-get install lxde-common desktop environment | `Dockerfile.dependencies_humble` |
| 12 | **495 MB** | apt-get install build-essential git cmake vim gnupg | `Dockerfile.dependencies_humble` |
| 13 | **468 MB** | apt-get install ros-humble-ros-gzharmonic | `Dockerfile.dependencies_humble` |
| 14 | **385 MB** | apt-get install libglvnd0 libgl1 libegl1 NVIDIA GL | `Dockerfile.dependencies_humble` |
| 15 | **384 MB** | colcon build --symlink-install Aerostack2 workspace | `Dockerfile.dependencies_humble` |
| 16 | **375 MB** | apt-get install libeigen3 + 40 ros-humble packages + MoveIt | `Dockerfile.dependencies_humble` |
| 17 | **292 MB** | git clone IndustrialRobots | `Dockerfile.dependencies_humble` |
| 18 | **279 MB** | apt-get install nodejs + yarn | `Dockerfile.dependencies_humble` |
| 19 | **267 MB** | apt-get install gz-harmonic Gazebo Harmonic | `Dockerfile.dependencies_humble` |
| 20 | **224 MB** | git clone RoboticsAcademy | `Dockerfile.humble` |
| 21 | **163 MB** | apt-get install xvfb x11vnc xterm VNC and X11 stack | `Dockerfile.dependencies_humble` |
| 22 | **119 MB** | colcon build --symlink-install RoboticsAcademy workspace | `Dockerfile.humble` |
| 23 | **115 MB** | git clone aerostack2 -b robotics-academy-fix | `Dockerfile.dependencies_humble` |
| 24 | **105 MB** | add-apt-repository ppa:openrobotics/gazebo11-gz-cli | `Dockerfile.dependencies_humble` |
| 25 | **94.5 MB** | Install VirtualGL and TurboVNC | `Dockerfile.dependencies_humble` |
| 26 | **79 MB** | apt-get install postgresql-18 | `Dockerfile.dependencies_humble` |
| 27 | **77.8 MB** | Base Ubuntu 22.04 layer | base image |
| 28 | **69.9 MB** | apt-get install tmux ros-dev-tools python3-pip | `Dockerfile.dependencies_humble` |
| 29 | **64.1 MB** | pip install --upgrade pip wheel setuptools selenium | `Dockerfile.dependencies_humble` |
| 30 | **63.1 MB** | mv /opt/jderobot/resources /resources | `Dockerfile.humble` |

### Understanding Ghost Layers

A ghost layer is data that appears to have been cleaned up but is permanently baked into the image. In Docker, every `RUN` instruction creates a new layer. If layer 2 clones a **4.61 GB** repository and layer 3 moves files out of it with `mv`, the original **4.61 GB** from layer 2 never disappears — it stays in the image forever even though it looks like it was moved. The RoboticsInfrastructure clone in `Dockerfile.humble` follows exactly this pattern: layer 2 clones **4.61 GB**, layer 3 moves **2.91 GB** of it elsewhere, and both layers remain permanently in the image. The fix is to combine the clone and all subsequent `mv` operations into a single `RUN` instruction so Docker only records the final state.

### Measured Build Times for Key Layers

To understand where build time is actually spent, each expensive layer was measured in isolation by running it inside the existing production container using `time docker run --rm --entrypoint bash`. This avoids a full 3-hour rebuild while giving accurate per-component timings on the same hardware.

| Component | Measured Build Time | What Was Built | How It Was Measured |
|---|---|---|---|
| OMPL | **34 minutes 16 seconds** | Full C++ library + complete Python bindings compiled from source at commit 0f990886 | `time docker run` with full cmake + make update_bindings + make + make install |
| Aerostack2 | **13 minutes 52 seconds** | 20 packages built successfully with correct COLCON_IGNORE files (6 packages skipped as per Dockerfile) | `time docker run` with colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release |
| React frontend | **3 minutes 20 seconds** | yarn install (**88 seconds**) + webpack production build (**79 seconds**) | `time docker run` with yarn install && yarn run build |
| IndustrialRobots | **3 minutes 8 seconds** | Full git clone (no --depth 1) + double colcon build of 59 packages across both passes | `time docker run` clone + both colcon passes |

All times measured on Lenovo Legion 5 (Ryzen 5 4600H, GTX 1650, **16 GB RAM**). The OMPL measurement is the most significant — **34 minutes** for a single component means any change to a layer before OMPL in `Dockerfile.dependencies_humble` invalidates the cache and forces a full 34-minute recompile of that layer alone, with all subsequent layers also rebuilding.

### Full Cold Build Measurement

After measuring individual components in isolation, a complete cold 
build of both Dockerfiles was performed with `--no-cache` to get the 
true end-to-end baseline. All measurements on **Lenovo Legion 5, 
Ryzen 5 4600H, GTX 1650, 16 GB RAM, Kubuntu**.

#### Dockerfile.dependencies_humble — Full Build

**Total time: 72 minutes 17 seconds**

Complete per-layer breakdown ranked by time:

| Step | Time | Instruction |
|---|---|---|
| [64/70] | **26m56s** | `./install-ompl-ubuntu.sh --github --python` |
| [23/70] | **7m23s** | `pip install torch --extra-index-url .../cu128` |
| [45/70] | **5m58s** | `colcon build --symlink-install` Aerostack2 |
| [44/70] | **5m54s** | `apt-get install libeigen3 + 40 ros-humble packages + MoveIt` |
| [21/70] | **3m35s** | `pip install onnxruntime-gpu opencv numpy ML stack` |
| [55/70] | **2m26s** | `colcon build && colcon build` IndustrialRobots double pass |
| [4/70]  | **2m34s** | `apt-get install ros-humble-ros-base + rviz2 + rosdep` |
| [17/70] | **2m33s** | `apt-get install lxde-common` |
| [6/70]  | **2m29s** | `apt-get install gazebo11 + gstreamer plugins` |
| [8/70]  | **1m59s** | `apt-get install gz-harmonic` |
| All remaining layers | ~10m | Small apt/pip/git/config steps |

**OMPL alone accounts for 37.2% of the entire Step 1 build time.**

#### Dockerfile.humble — Full Build

**Total time: 30 minutes 6 seconds**

| Step | Time | Instruction |
|---|---|---|
| [2/20] | **23m27s** | `git clone RoboticsInfrastructure --depth 1` |
| [17/20] | **1m44s** | `yarn install && yarn run build` React frontend |
| [10/20] | **1m32s** | `git clone RoboticsAcademy --depth 1` |
| [14/20] | **1m32s** | `colcon build --symlink-install /home/ws` |
| All remaining | ~1m | mv, chmod, zip, config steps |

**The RoboticsInfrastructure clone took 23 minutes 27 seconds — 
78% of the entire Step 2 build time — on a home internet connection. 
This is pure network latency with zero CPU involvement.**

#### Combined Total

| | Time |
|---|---|
| Dockerfile.dependencies_humble | 72m17s |
| Dockerfile.humble | 30m06s |
| Dockerfile.database | 27s |
| **Total cold build** | **102m50s** |

This is the before-baseline. Every optimization in this project will 
be measured against this number. The difference between this 102-minute 
local build and the ~45-minute build on institutional infrastructure is 
almost entirely explained by network speed on two layers: the PyTorch 
download (7m23s locally, ~1-2m on fast connections) and the 
RoboticsInfrastructure clone (23m27s locally, ~2-3m on fast connections).
The database image (`Dockerfile.database`) builds in 27 seconds 
and is independent of the other two — it is never a bottleneck.


### What Lives Inside the Running Container

Running `docker run --rm --entrypoint bash jderobot/robotics-academy:latest` with `du -sh` against key directories reveals what is actually present on disk inside the container at runtime:

| Path Inside Container | Measured Size | Present at Runtime |
|---|---|---|
| `/ompl` (OMPL source tree + build artifacts) | **1.5 GB** | Yes — entire source and build directory left on disk |
| `/home/drones_ws/src` (Aerostack2 source) | **114 MB** | Yes |
| `/home/drones_ws/build` (Aerostack2 CMake artifacts) | **346 MB** | Yes |
| `/home/drones_ws/log` (Aerostack2 colcon logs) | **2.8 MB** | Yes |
| `/home/drones_ws/install` (Aerostack2 runtime) | **52 MB** | Yes — this is the only part needed |
| `/home/ws/src` (RoboticsInfrastructure packages) | **2.8 GB** | Yes — confirmed required: `find /home/ws/install -type l` returns symlinks pointing into `src/`. Deleting `src/` breaks the install tree. |
| `/home/ws/build` (ROS2 workspace build artifacts) | **119 MB** | Yes |
| `/home/ws/log` (ROS2 workspace colcon logs) | **2.9 MB** | Yes |
| `/home/ws/install` (ROS2 workspace runtime) | **54 MB** | Yes — runtime install tree |
| `react_frontend/node_modules` | **840 MB** | Yes — only needed during build, not at runtime |
| `/opt/jderobot` | **0 bytes (cleaned)** | No — moved to other locations |

### Image Efficiency Analysis

Running `dive jderobot/robotics-academy:latest --ci` produced the following result:

```
PASS: highestUserWastedPercent
PASS: lowestEfficiency
SKIP: highestWastedBytes (rule disabled by default)
Result: PASS [Total:3] [Passed:2] [Failed:0] [Warn:0] [Skipped:1]
```

The image passes `dive`'s default CI thresholds. However the `highestWastedBytes` rule — the rule that would flag the largest ghost layers — was skipped because it is disabled in the default configuration. This means the default `dive --ci` check is not sufficient to catch the largest sources of bloat in this image without custom threshold configuration. Enabling and tuning this rule will be part of the optimization deliverables.

---

## How Code Actually Gets Executed

One of the most important things to understand before touching any Dockerfile is what the running container actually does at runtime. I had initially assumed Django was responsible for executing student code. Tracing through the codebase — with Javier helping clarify the architecture — showed that assumption was wrong, and getting it wrong would have broken the most critical part of the migration.

The actual flow is:

1. The React frontend packages the student's code into a **Base64-encoded ZIP file**.
2. That ZIP is sent over WebSockets to **port 7163**, which belongs to the **Robotics Application Manager (RAM)** — a separate daemon.
3. RAM receives it, clears `/workspace/code/`, extracts the ZIP, and spawns a **`subprocess.Popen`** — either `python3 <entrypoint>` for Python code, or `colcon build` + `ros2 launch` for C++/ROS 2.

Django just handles frontend routing and file writes. RAM is where execution actually happens.

This distinction matters directly for the Podman migration. Because student code runs under RAM's UID via `subprocess.Popen`, any rootless container setup has to preserve that UID mapping correctly or volume writes will silently fail. The CDI requirement for GPU access follows from the same constraint — rootless execution cannot use the NVIDIA daemon runtime. Both of these are implementation problems for the coding period, not community bonding. The point here is that I now know exactly where the constraints come from.

---

## The Telemetry Bridge

I also confirmed how ROS 2 simulation data reaches the browser.
There is no `rosbridge_suite` in the dependencies. Instead, each
exercise backend spawns a native `rclpy` node that pushes data
over WebSockets on **port 2303** to the React `CommsManager`.

One thing flagged here that directly affects the multi-stage build:
there is a **custom-patched `websocket_server.py`** in the RAM source
tree that fixes an `OPCODE_CONTINUATION` bug in the upstream library.
A naive `pip install websocket-server` in the runtime stage would
silently overwrite this patch and break the telemetry pipeline.
This file needs explicit handling in the build — the exact strategy
will be documented in Week 1 of the coding period.

---

## Camera Feeds and Wayland

One concern I had was whether migrating the display stack would
break drone camera feeds. After tracing the vision pipeline, the
answer is: the primary camera feeds encode frames as Base64 via
**OpenCV** and send them over WebSockets — no dependency on `Xvfb`
or VNC. Those feeds are safe.

The Gazebo simulation window is a different story — it does rely
on the VNC pipeline. The X11-to-Wayland transition needs to
account for that separately. Core camera feeds safe, full Gazebo
desktop view is not a free migration.

---

## Summary

**Week 1:**
- [x] Pulled `jderobot/robotics-academy:latest` (**29.5 GB**) and `jderobot/robotics-database:latest` (**486 MB**)
- [x] Set up NVIDIA Container Toolkit and confirmed Django on port 7164
- [x] Kickoff sync with David Pascual-Hernández

**Week 2:**
- [x] Pulled and profiled `jderobot/robotics-academy:latest` — confirmed **29.5 GB**, 30 layers
- [x] Ran `docker history` analysis — full layer-by-layer size breakdown documented
- [x] Identified ghost layer pattern — RoboticsInfrastructure clone permanently inflating image
- [x] Measured OMPL build time: **34 minutes 16 seconds** on Ryzen 5 4600H
- [x] Measured Aerostack2 build time: **13 minutes 52 seconds** (20 packages, correct COLCON_IGNORE)
- [x] Measured React frontend build time: **3 minutes 20 seconds** (yarn install + webpack production)
- [x] Measured IndustrialRobots double colcon build: **3 minutes 8 seconds** (59 packages, both passes)
- [x] Confirmed live filesystem waste via `du -sh` inside running container
- [x] Traced execution pipeline: Django → RAM → `subprocess.Popen`
- [x] Confirmed `--userns=keep-id` is required for rootless Podman
- [x] Found custom-patched `websocket_server.py` — flagged as risk for multi-stage build
- [x] Confirmed primary camera feeds bypass X11 — Gazebo VNC pipeline requires separate handling
- [x] Ran `dive --ci` image efficiency analysis — flagged disabled `highestWastedBytes` rule

---

## What's Next

Week 1 of the coding period starts tomorrow. The baseline is fully
documented — every layer has a measured size, every expensive
component has a measured build time, and the live filesystem waste
is confirmed.

The before-baseline is locked. Every optimization will be measured
against these exact numbers.

---

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
