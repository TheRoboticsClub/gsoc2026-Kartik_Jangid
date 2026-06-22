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

`NVIDIA_DRIVER_CAPABILITIES` is `ENV`, so it persists into the running container. `NVIDIA_VISIBLE_DEVICES` is `ARG`, which only exists during the build and is gone by runtime. The NVIDIA container runtime reads both from the container's live environment to decide which GPUs to expose and what capabilities to enable. With `NVIDIA_VISIBLE_DEVICES` as `ARG`, there's nothing on the devices side for it to read.

In practice, passing `--gpus all` at `docker run` makes the NVIDIA toolkit inject `NVIDIA_VISIBLE_DEVICES=all` automatically, so nothing silently breaks today. But that's the toolkit bailing you out, not the Dockerfile being correct. Declaring it as `ENV` is NVIDIA's own recommended pattern and removes the dependency on that implicit injection. The fix goes in the runtime stage of the multi-stage build.


## --symlink-install Is Not a Bug

Lines 364-375 of `Dockerfile.dependencies_humble` are a single `RUN` instruction with an if/else on `$TARGETARCH`. Both the `arm64` branch and the non-`arm64` branch call `colcon` with `--symlink-install`, but only one branch runs per build. The main workspace build in `Dockerfile.humble` at line 41 also uses the flag. I initially wanted to drop it for the multi-stage build because `COPY --from=builder` copies symlinks verbatim without the `src/` trees they point into, which would leave the runtime stage full of dangling pointers.

Javier confirmed in the Thursday meeting that the flag has to stay. The RoboticsApplicationManager runs its own `colcon build --symlink-install` at runtime when loading a universe (manager.py line 403):

```
'/bin/bash -c "cd /workspace/worlds; source /opt/ros/humble/setup.bash; colcon build --symlink-install; source install/setup.bash; cd ../.."'
```

Removing the flag from the image build would create a mismatch between the pre-built install trees and what the manager builds at runtime. So the multi-stage design has to carry `src/` directories into the runtime stage alongside `install/`. That's the constraint to design around, not a flag to remove. `/workspace/worlds` itself doesn't exist in the image — the manager creates and destroys it at runtime for each exercise load — so there's nothing to account for in the Dockerfile on that front.


## The Dead Source Line and Why It Doesn't Break Anything

`Dockerfile.humble` lines 39-41 have this pattern:

```
WORKDIR /home/ws
RUN /bin/bash -c "source /home/drones_ws/install/setup.bash"
RUN /bin/bash -c "source /opt/ros/humble/setup.bash; colcon build --symlink-install ..."
```

Docker starts a new shell for each `RUN` instruction. The shell on line 40 exits when it finishes, so the sourced environment is gone before line 41 starts. The source call on line 40 does nothing useful. I flagged this on Slack before touching the file.

The git history resolved it. Commit `ae1967950` from May 11 2026 had already fixed this by collapsing the source and the build into a single `RUN`. Commit `79b9ef589` two days later reverted it — not because the fix was wrong, but because the PR was scoped to something unrelated to Dockerfiles and the mentor asked for a clean revert. The fix was correct and came back out for process reasons only.

What I didn't understand until the mentor explained it is why line 40 doesn't cause a build failure. `Dockerfile.dependencies_humble` at lines 382 and 385 appends both source commands into `~/.bashrc`, and `Dockerfile.humble` at line 65 sets `ENV BASH_ENV=/.env`. `BASH_ENV` tells bash to source that file at startup for every non-interactive shell — including every `RUN /bin/bash -c` instruction — so `drones_ws` is already in the environment before line 40 even runs. Line 40 is sourcing something that's already there. The source instructions in `Dockerfile.humble` are not needed because `Dockerfile.dependencies_humble` already handles them through `BASH_ENV`. Line 40 can go, and the runtime stage will inherit `ENV BASH_ENV=/.env` from the base image automatically — no extra wiring needed.


## What the Runtime Stage Actually Needs

To figure out which packages actually need to ship in the runtime image, I traced every apt package in `Dockerfile.dependencies_humble` through the files that run at container start: `entrypoint.sh`, `manager.py`, `set_dri_name.sh`, `check_ram_version.sh`, `start_vnc.sh`, and all the launcher files. The goal was to classify each package as build-time or runtime, with no guessing. The build-time list is long and expected: `build-essential`, `cmake`, the full `colcon` and `rosdep` stack, all the `ament-cmake` lint and test packages, `flake8` and its plugins, and the APT infrastructure tools — `curl`, `wget`, `gnupg`, `lsb-release`, `git`. None of those ship in the runtime stage.

Three packages looked like dev tools but turned out to be runtime. `manager.py` imports `black` at line 14 and calls `black.format_str()` to format code that users submit through the web editor. At line 620 it calls `jedi.Script()` to power live autocomplete in that same editor. At line 518 it runs `pylint` via subprocess to do live code analysis on exercise submissions. All three run on every exercise session, so `pylint`, `black`, and `jedi` go in the runtime stage. The counterintuitive discovery was `python3-pip`: it's build-time only. The pip binary available at runtime is `/usr/local/bin/pip`, pip 23.3.1, installed from the wheel upgrade done during the build. I confirmed this by running `which pip` inside the container — the apt package was only the bootstrap. `python-is-python3` is also build-time only. The only file in the repo with a bare `#!/usr/bin/env python` shebang is `build_world.py` in `tello_phy`, which has no external callers anywhere in the codebase and no registered universe in `universes.sql`.

The shared library situation needed a different tool. I ran `dpkg -S` inside the `dependencies-humble` container against `libGeographic.so`, `libPocoFoundation.so`, `libpcl_common.so`, `libncurses.so`, and `libyaml-cpp.so` and got the same pattern every time. The unversioned `.so` symlink belongs to the `-dev` package — that's what the linker follows at compile time. The versioned `.so` belongs to a separate runtime package and is what the dynamic linker actually loads when the container runs. The runtime stage therefore needs `libgeographic19`, `libpocofoundation80`, `libpcl-common1.12`, `libncurses6`, and `libyaml-cpp0.7`, not the `-dev` packages.


## What --symlink-install Means for the Split

The mentor confirmed `--symlink-install` has to stay, so the question was never whether to keep it but what it actually means for copying artifacts into a runtime stage. The audit found the flag only affects `ament_python` packages. For those, `colcon` calls `pip install --editable` instead of a normal install, landing a `.pth` file in `install/` that points back to the source directory in `src/`. C++ packages are unaffected — CMake physically copies compiled `.so` files into `install/` regardless of the flag. `COPY --from=builder` of `install/` works cleanly for all C++ artifacts. It breaks only for Python packages because the `.pth` paths dangle as soon as `src/` is absent.

Four packages in `/home/ws/` are `ament_python`: `jderobot_drones` (116K), `tello_camera` (56K), `tello_simple_teleop` (44K), and `platform_controller` (52K). Their combined `src/` is 268K against a total `/home/ws/src/` of 2.5G. The runtime stage needs `install/` (72M) plus those 268K of Python source — the remaining 2.5G stays in the builder only. One classification from the earlier package audit needed a correction here: `python3-colcon-common-extensions` is not build-time only. `manager.py` line 403 runs `colcon build --symlink-install` at runtime when the `RoboticsApplicationManager` loads a custom universe into `/workspace/worlds/`. `colcon` must be present in the runtime stage.

Running `objdump -p` on `libdrone_lib_cpp.so` confirmed no RPATH is baked into the binary. It resolves `aerostack2` dependencies at runtime through `LD_LIBRARY_PATH`, set by sourcing `/home/drones_ws/install/setup.bash`. The runtime stage needs `/home/drones_ws/install/` present and the `BASH_ENV=/.env` mechanism to carry forward — but no path fixup is needed. The `/home/dev_ws/install` reference in `jderobot_drones_cpp/CMakeLists.txt` at line 11 is a build-time hint that left no trace in the compiled output. That question is closed.


## What's Next

The audit is still ongoing. Some things need more reading before I can be confident in the multi-stage split design, and the Thursday meeting actually added a few items to check rather than only removing them. That's fine. David's point about building on a solid foundation applies here: it's better to spend another few days on the audit than to start writing a Dockerfile based on assumptions that turn out to be wrong.

If you're following the project or want to weigh in on anything above, the Slack channel is the right place. I check it daily.

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
