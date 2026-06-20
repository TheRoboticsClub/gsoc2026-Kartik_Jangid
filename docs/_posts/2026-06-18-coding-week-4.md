---
layout: single
title: "Coding Week 4 — Pre-Refactoring Audit"
date: 2026-06-18
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, optimization, multi-stage-build, entrypoint, ros2]
---

I spent this week reading the existing build system carefully before touching a single file. Multi-stage Docker builds are not hard to write, but they are easy to get subtly wrong, and getting this one wrong matters because it's the foundation everything else builds on top of. David and Javier both made this point mid-week: work with clarity and safety first. If something is unclear, ask on Slack rather than assume. That framing shaped how I spent the week.

The Thursday meeting also cleared up several things I had been unsure about. One of the bigger ones: I had been planning to add a `.dockerignore` at the repo root once the multi-stage Dockerfile moves there, to avoid sending the whole repo as build context. David pointed out we don't need one. `docs/generate_a_radi.md` already tells users to `cd scripts/RADI` and run the build from inside that directory. The build context is that subdirectory, not the repo root, so the concern doesn't apply.

Below is what the audit found.


## How the Build Actually Works

`scripts/RADI/build.sh` is what actually runs the build. It calls `docker build` with `.` as the build context (just a dot), which means the context is whatever directory the script is run from. The Dockerfile names are passed by filename only with no path prefix, so this only works if you're already inside `scripts/RADI/`. That requirement is documented in `docs/generate_a_radi.md` as step 1 in every build example.

The directory itself is pretty small: `build.sh`, `Dockerfile.dependencies_humble`, `Dockerfile.humble`, `Dockerfile.database`, `README.md`, `install-ompl-ubuntu.sh`, and a `gpu/` folder with three `.deb` files. That's the entire build context.

The build runs two images in sequence. `Dockerfile.dependencies_humble` goes first and produces `jderobot/robotics-applications:dependencies-humble`. `Dockerfile.humble` goes second, uses that as its `FROM`, and produces `jderobot/robotics-academy:$IMAGE_TAG`. Here's the first build invocation from `build.sh` (lines 112-114):

```
docker build $NO_CACHE -f $DOCKERFILE_BASE \
  --build-arg TARGETARCH=$(uname -m | sed 's/x86_64/amd64/;s/arm64/arm64/') \
  -t jderobot/robotics-applications:dependencies-$ROS_DISTRO .
```


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

Removing the flag from the image build would create a mismatch between the pre-built install trees and what the manager builds at runtime. So the multi-stage design has to carry `src/` directories into the runtime stage alongside `install/`. That's the constraint to design around, not a flag to remove.


## What /workspace/worlds Actually Is

`/workspace/worlds` doesn't exist in the image, so there's nothing to copy or account for at build time.

The directory is created in `Manager.__init__()` when the manager process starts and lives for the entire lifetime of the manager. On each exercise load, `prepare_custom_universe()` calls `shutil.rmtree` at lines 386-387 to wipe it, then recreates a fresh universe subdirectory at lines 390-392. After that, line 403 runs `colcon build --symlink-install` inside it and sources `install/setup.bash`. The `setup.bash` at `/workspace/worlds/install/setup.bash` only exists after the manager has built the universe. It gets wiped the moment the next exercise loads.

Nothing to model in the Dockerfile here.


## One Thing I'm Not Sure About

`Dockerfile.humble` lines 39-41:

```
WORKDIR /home/ws
RUN /bin/bash -c "source /home/drones_ws/install/setup.bash"
RUN /bin/bash -c "source /opt/ros/humble/setup.bash; colcon build --symlink-install ..."
```

Docker starts a new shell for each `RUN` instruction. The shell on line 40 exits when it finishes, and whatever it sourced is gone. Line 41 starts completely fresh. So `/home/drones_ws/install/setup.bash` is not sourced during the `colcon build` on line 41. The source call on line 40 does nothing.

I don't know if this is intentional or a leftover from an earlier version of the file. Rather than assume, I posted it on Slack. I won't touch that file until I get a clear answer.


## The Source That Was Already There

The standalone `RUN` on line 40 of `Dockerfile.humble`:

```
RUN /bin/bash -c "source /home/drones_ws/install/setup.bash"
```

has no effect on the `colcon build` on line 41. Docker starts a fresh shell for each `RUN` instruction, so the sourced environment from line 40 is gone before line 41 even starts. I flagged this on Slack as something that looked like a bug.

The git history gave a clearer picture. Commit `ae1967950` from May 11 2026 had already fixed this correctly by collapsing the source instructions and the colcon build into a single `RUN`. Two days later, commit `79b9ef589` explicitly reverted it with the message "return dockerfile source commands to original version." The mentor confirmed the revert had nothing to do with the fix being wrong. The PR that contained the change was scoped to something entirely unrelated to the Dockerfiles, and the mentor asked the contributor to revert all Dockerfile changes to keep the PR focused. The fix was correct and came back out for process reasons only.

What I hadn't understood until the mentor explained it is why line 40 doesn't cause a build failure in the first place. `Dockerfile.dependencies_humble` at lines 382 and 385 appends both sources into `~/.bashrc`:

```
RUN echo "source /opt/ros/$ROS_DISTRO/setup.bash" >> ~/.bashrc
RUN echo "source /home/drones_ws/install/setup.bash" >> ~/.bashrc
```

And `Dockerfile.humble` at line 65 sets `ENV BASH_ENV=/.env`. The `BASH_ENV` variable tells bash to source that file at startup for every non-interactive shell, which includes every `RUN /bin/bash -c` instruction. So `drones_ws` is already in the environment before line 40 runs. Line 40 is sourcing something that is already there. The mentor confirmed: the source instructions in `Dockerfile.humble` are not needed because `Dockerfile.dependencies_humble` already handles them through `BASH_ENV`.

So line 40 can go. The mentor confirmed this explicitly on Slack. The sources in `Dockerfile.dependencies_humble` stay exactly as they are because they are the mechanism that makes the environment work.

This matters for the multi-stage build: the runtime stage will inherit `ENV BASH_ENV=/.env` from the base image, so the sourcing behaviour carries forward automatically. No extra `RUN` instructions needed to wire up the ROS environment in the runtime stage.


## What's Next

The audit is still ongoing. Some things need more reading before I can be confident in the multi-stage split design, and the Thursday meeting actually added a few items to check rather than only removing them. That's fine. David's point about building on a solid foundation applies here: it's better to spend another few days on the audit than to start writing a Dockerfile based on assumptions that turn out to be wrong.

If you're following the project or want to weigh in on anything above, the Slack channel is the right place. I check it daily.

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
