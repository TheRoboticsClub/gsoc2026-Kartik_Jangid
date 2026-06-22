---
layout: single
title: "Coding Week 4 — Pre-Refactoring Audit"
date: 2026-06-18
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, optimization, multi-stage-build, entrypoint, ros2]
---

I spent this week doing a structured read of the existing build system before writing any new Dockerfile. David and Javier both said it clearly: work with clarity first, ask on Slack rather than assume. The build runs two images in sequence — `Dockerfile.dependencies_humble` produces `jderobot/robotics-applications:dependencies-humble`, then `Dockerfile.humble` uses that as its base. Both are invoked by `build.sh` from inside `scripts/RADI/`, which keeps the build context to just that directory. Below is what the audit found.


## The NVIDIA ARG That Does Nothing at Runtime

Near the top of `Dockerfile.dependencies_humble`, lines 4 and 5:

```
# Make all NVIDIA GPUS visible
ARG NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all
```

`NVIDIA_DRIVER_CAPABILITIES` is `ENV` so it persists. `NVIDIA_VISIBLE_DEVICES` is `ARG` — gone after the build, not present in the running container. Passing `--gpus all` at runtime compensates today via automatic toolkit injection, but the correct fix is `ENV`. It goes in the runtime stage.


## --symlink-install: The Constraint and What It Costs

The mentor confirmed `--symlink-install` has to stay, so the question became what it actually produces and what that means for copying artifacts into a runtime stage. The assumption going into verification was that it creates `.pth` editable installs for Python packages, meaning only a handful of small `src/` directories would need to travel with `install/`.

That assumption was wrong. Running `find` inside both images found zero `.pth` files. What `--symlink-install` actually creates is filesystem symlinks — 3,206 of them from `/home/ws/install/` back into `/home/ws/src/` across 21 packages, and 347 from `/home/drones_ws/install/` back into `/home/drones_ws/src/`. Copying `install/` alone into a runtime stage leaves all of those dangling. The "copy 268K of Python source" framing from the earlier audit was incorrect and is withdrawn.

What this means for the split is that `src/` cannot be excluded wholesale. The question is which subset of `src/` the symlink graph actually requires at runtime — not all of `/home/ws/src/` (2.5G) needs to ship, but the exact minimal set has to be traced from the symlinks rather than assumed. That tracing is the open question going to Slack before implementation starts.

Two things the verification did close: `AEROSTACK2_PATH` appears only in the Dockerfile's export line and has no runtime reader — so `/home/drones_ws/src/aerostack2` is not needed for that reason. The MoveIt and OMPL packages used by Industrial exercises are present in the inherited ROS install — no special COPY and no patched headers needed.

One correction from the package audit stands: `colcon` must be in the runtime stage because `manager.py` line 403 runs `colcon build --symlink-install` at runtime when loading a custom universe. Running `objdump -p` on `libdrone_lib_cpp.so` confirmed no RPATH is baked in — resolution is through `LD_LIBRARY_PATH` from sourcing `/home/drones_ws/install/setup.bash`, so that directory must be present in the runtime stage.


## The Dead Source Line and Why It Doesn't Break Anything

`Dockerfile.humble` lines 39-41 have this pattern:

```
WORKDIR /home/ws
RUN /bin/bash -c "source /home/drones_ws/install/setup.bash"
RUN /bin/bash -c "source /opt/ros/humble/setup.bash; colcon build --symlink-install ..."
```

Docker starts a new shell for each `RUN` instruction. The shell on line 40 exits when it finishes, so the sourced environment is gone before line 41 starts. The source call on line 40 does nothing useful. I flagged this on Slack before touching the file.

Someone had already fixed this in git by collapsing the source and the build into a single `RUN`. It was reverted for process reasons — the PR was scoped to something unrelated, mentor asked for a clean revert — not because the fix was wrong.

What I didn't understand until the mentor explained it is why line 40 doesn't cause a build failure. `Dockerfile.dependencies_humble` at lines 382 and 385 appends both source commands into `~/.bashrc`, and `Dockerfile.humble` at line 65 sets `ENV BASH_ENV=/.env`. `BASH_ENV` tells bash to source that file at startup for every non-interactive shell — including every `RUN /bin/bash -c` instruction — so `drones_ws` is already in the environment before line 40 even runs. Line 40 is sourcing something that's already there. The source instructions in `Dockerfile.humble` are not needed because `Dockerfile.dependencies_humble` already handles them through `BASH_ENV`.


## What the Runtime Stage Actually Needs

A package is build-time only if nothing running inside the container after the entrypoint fires ever calls, imports, or loads it — the criterion that drove every classification below.

To figure out which packages actually need to ship in the runtime image, I traced every apt package in `Dockerfile.dependencies_humble` through the files that run at container start: `entrypoint.sh`, `manager.py`, `set_dri_name.sh`, `check_ram_version.sh`, `start_vnc.sh`, and all the launcher files. The goal was to classify each package as build-time or runtime, with no guessing. The build-time list is long and expected: `build-essential`, `cmake`, the full `colcon` and `rosdep` stack, all the `ament-cmake` lint and test packages, `flake8` and its plugins, and the APT infrastructure tools — `curl`, `wget`, `gnupg`, `lsb-release`, `git`. None of those ship in the runtime stage.

Three packages looked like dev tools but turned out to be runtime. `manager.py` imports `black` at line 14 and calls `black.format_str()` to format code that users submit through the web editor. At line 620 it calls `jedi.Script()` to power live autocomplete in that same editor. At line 518 it runs `pylint` via subprocess to do live code analysis on exercise submissions. All three run on every exercise session, so `pylint`, `black`, and `jedi` go in the runtime stage.

Two packages that look like runtime dependencies turned out to be build-time only. `python3-pip` is the bootstrap — the pip binary available at runtime is `/usr/local/bin/pip`, pip 23.3.1, installed from the wheel upgrade done during the build. I confirmed this by running `which pip` inside the container. The apt package was only needed to get pip installed in the first place. `python-is-python3` is also build-time only. The only file in the repo with a bare `#!/usr/bin/env python` shebang is `build_world.py` in `tello_phy`, which has no external callers anywhere in the codebase and no registered universe in `universes.sql`.

The shared library situation needed a different tool. I ran `dpkg -S` inside the `dependencies-humble` container against `libGeographic.so`, `libPocoFoundation.so`, `libpcl_common.so`, `libncurses.so`, and `libyaml-cpp.so` and got the same pattern every time. The unversioned `.so` symlink belongs to the `-dev` package — that's what the linker follows at compile time. That job is done once the binary is compiled and never repeated — at runtime the dynamic linker loads the versioned `.so` from the separate runtime package, not the `-dev` package. The versioned `.so` belongs to a separate runtime package and is what the dynamic linker actually loads when the container runs. The runtime stage therefore needs `libgeographic19`, `libpocofoundation80`, `libpcl-common1.12`, `libncurses6`, and `libyaml-cpp0.7`, not the `-dev` packages.


## What's Next

One question goes to Slack before the Dockerfile is written: what is the minimal subset of `src/` the symlink graph requires at runtime, and where does `gz_ros2_control` fit in the two-Dockerfile split. Those two answers determine the COPY instructions for the runtime stage. Everything else the audit needed to know is verified.

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
