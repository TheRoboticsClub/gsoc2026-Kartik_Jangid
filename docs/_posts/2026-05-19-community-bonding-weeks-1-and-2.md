---
layout: single
title: "Community Bonding: Weeks 1 & 2"
date: 2026-05-19 08:00:00 -0000
published: true
categories: [gsoc, community-bonding]
tags: [docker, podman, ros2, robotics, gsoc2026, jderobot]
author: Kartik Jangid
---

![JdeRobot GSoC 2026](/assets/images/logo.png)

I got selected for GSoC 2026 with **JdeRobot**, and the first two weeks have been mostly reading code, running `grep` on Dockerfiles, and slowly building a map of how this platform actually works.

My project (#7) has three main goals. First, optimize the `dependencies_humble` Docker image through strict apt squashing and source pruning of heavy ROS 2 meta-packages — specifically **Aerostack2** and **OMPL** — which are the primary contributors to image bloat. Second, migrate the runtime to a daemonless, rootless **Podman** architecture for better security, including safe GPU acceleration via the **Container Device Interface (CDI)**. Third, restructure the build into a proper multi-stage pipeline so the final runtime image isn't carrying compiler toolchains and build artifacts it doesn't need. These two weeks were about understanding the codebase well enough to do all of that safely.

---

## The Mentor Team

Before I get into the work, I want to introduce the mentors I'm working with — they've been genuinely helpful from the start.

- **David Pascual-Hernández** — He leads our weekly syncs, keeps the project direction on track, and is the main person I check in with when I need to validate an approach.
- **Javier I.** — Most of the deeper architecture and code questions go to Javier. Whenever I'm confused about how something fits together in the stack, he's the one I ask.
- **Md. Shariar Kabir** — Official mentor for this project. Has been available throughout the bonding period and brings direct experience with the JdeRobot infrastructure.
- **Nikhil Gupta** — official mentor, has been available for questions during the bonding period.

---

## Week 1 — Setting Up Locally

The first thing I did was clone [RADI](https://github.com/JdeRobot/RoboticsApplicationManager) and [RoboticsBackend](https://github.com/JdeRobot/RoboticsBackend) on my Kubuntu machine and get the legacy environment running. There was a bit of initial setup friction, but I eventually got the Django frontend routing confirmed on **port 7164**.

![Local Setup](/assets/images/local_setup.png)

![JdeRobot Logo](/assets/images/JdeRobot_Gsoc_Logo.webp)

The kickoff meeting with David went well. We went through the project milestones, talked about what the refactor needs to accomplish, and set expectations for the coding period. David gave me one piece of advice early on that turned out to be useful: don't assume this stack works like a standard web app. I took note of that, and it saved me from a wrong assumption later in the week.

---

## Week 2 — Looking at the Dockerfile

With the environment running, I moved on to understanding why `Dockerfile.dependencies_humble` is so large. I ran a few `grep` commands directly on the file to get a concrete count.

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
| `rm -rf /var/lib/apt/lists/*` cache purges | **13** |
| Net leaking layers | **≥ 4** |

The proposal estimated `Dockerfile.dependencies_humble` would have around 57 `RUN`-equivalent stages. The actual count came out at **59** — the bloat has grown beyond even that estimate. There are 17 separate apt install commands but only 13 cache purges, meaning at least four layers have downloaded package archives permanently baked into the image. Why does this matter? Because unpurged cache layers mean students with slow internet connections are forced to download gigabytes of dead weight just to boot a basic robotics exercise. The fix is to consolidate the `RUN` stages, enforce `--no-install-recommends` everywhere, and ensure every apt chain cleans up in the same layer. On top of that, the biggest size wins will come from pruning the source installs of **Aerostack2** and **OMPL**, which pull in heavy Boost and drone-stack dependencies that the runtime image doesn't need.

---

## How Code Actually Gets Executed

I had assumed the Django backend (port 7164) was responsible for running student code. After tracing through the codebase, that's not the case — Javier helped clarify this when I asked about it.

The actual flow is:

1. The React frontend packages the student's code into a **Base64-encoded ZIP file**.
2. That ZIP is sent over WebSockets to **port 7163**, which belongs to the **Robotics Application Manager (RAM)** — a separate daemon.
3. RAM receives it, clears `/workspace/code/`, extracts the ZIP, and spawns a **`subprocess.Popen`** — either `python3 <entrypoint>` for Python code, or `colcon build` + `ros2 launch` for C++/ROS 2.

Django just handles frontend routing and file writes. RAM is where execution actually happens.

### `--userns=keep-id` for Podman

Because RAM uses `subprocess.Popen()`, the student's running code inherits RAM's UID/GID. In rootless Podman without `--userns=keep-id`, that UID gets remapped to an unprivileged one that can't write to the bind-mounted `/workspace/code/` volume, and RAM will error out.

```bash
# Works: host UID maps into the container correctly
podman run --userns=keep-id -v /workspace/code:/workspace/code ...

# Breaks: internal UID gets remapped, volume writes fail
podman run -v /workspace/code:/workspace/code ...
```

So `--userns=keep-id` isn't optional for this migration — it's a requirement based on how RAM works.

### GPU Access via CDI

The other Podman constraint involves GPU acceleration. The legacy Docker setup uses the NVIDIA container runtime, which requires root. In rootless Podman, the equivalent is the **Container Device Interface (CDI)** — a standardized spec that lets Podman expose GPU devices into the container without needing a privileged daemon. The Podman migration plan has to include generating the CDI config for the NVIDIA device and passing `--device nvidia.com/gpu=all` (or equivalent) at runtime, rather than relying on the old `--gpus all` Docker flag.

---

## The Telemetry Bridge

I also looked into how ROS 2 data gets from simulation topics to the browser. I expected to find `rosbridge_suite` in the dependencies. It's not there.

Instead, JdeRobot uses a custom Python framework. Each exercise backend spawns a native `rclpy` node, subscribes to local simulation topics like `/webgui/user_map`, and pushes the data over WebSockets on **port 2303** to the React `CommsManager`.

One thing I need to be careful about during the multi-stage build: there's a **custom-patched `websocket_server.py`** sitting in the RAM source tree. It fixes an `OPCODE_CONTINUATION` bug in the upstream library. If we just run `pip install websocket-server` in the new runtime container, that patch gets overwritten by the standard package, and the telemetry pipeline breaks. This file has to be explicitly preserved when we split the build stages.

---

## Camera Feeds and Wayland

One thing I was uncertain about was whether migrating from X11/TurboVNC to Wayland would break the drone camera feeds. After tracing through the vision pipeline, the answer is: it depends on which part of the frontend you're talking about.

The primary drone camera feeds work like this:

1. `HAL.py` subscribes to `sensor_msgs/Image` topics like `/drone0/frontal_cam/image_raw`.
2. The Python GUI thread grabs the numpy arrays, encodes them as JPEG via **OpenCV**, and converts them to a Base64 JSON payload.
3. That payload goes to port **2303** (the CommsManager).
4. The React frontend puts the Base64 string directly into an `<img>` tag.

That chain has no dependency on the virtual display stack — no `Xvfb`, no VNC. So for those feeds specifically, the Wayland migration doesn't change anything.

However, the official architecture diagram shows a different story for the Gazebo simulator itself: the web frontend includes **VNC viewers** (`Visores VNC`) that connect directly to the Gazebo simulation window. That part of the platform does rely on the VNC pipeline, and any X11-to-Wayland transition will need to account for it. The core camera feeds are safe; the full Gazebo desktop view is not.

---

## Summary

**Week 1:**
- [x] Cloned RADI and RoboticsBackend on local Kubuntu
- [x] Spun up the legacy environment
- [x] Verified Django frontend routing on port 7164
- [x] Kickoff sync with David Pascual-Hernández

**Week 2:**
- [x] Ran static analysis on `Dockerfile.dependencies_humble` — 59 layers, 17 apt blocks, 13 purges
- [x] Traced the execution pipeline: Django → RAM → `subprocess.Popen`
- [x] Confirmed `--userns=keep-id` is required for rootless Podman
- [x] Found the custom-patched `websocket_server.py` that must survive the multi-stage build
- [x] Confirmed camera feeds bypass X11 — Wayland migration won't break them

---

## What's Next

Next week is **Week 1 of the Coding Period**. The main task is drafting the multi-stage Dockerfile split — separating the build environment (Stage 1) from the runtime environment (Stage 2), and writing the `COPY --from=builder` instructions to carry only the compiled `install/` directories across. The analysis from these two weeks gives a clear enough picture to start writing actual Dockerfiles.

---

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
