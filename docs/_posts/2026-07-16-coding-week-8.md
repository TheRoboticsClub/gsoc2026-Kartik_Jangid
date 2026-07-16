---
layout: single
title: "Coding Week 8 — Podman Compose Testing"
date: 2026-07-16
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, podman, rootless, docker-compose]
---

This week mostly Focused on learning the podman architectures and whether or not migrating to Podman is a plausible strategy with also the conclusion of running the exercises with Podman compose.

## Docker also works via rootless, then why not use it?

According to official Docker docs, it also supports rootless mode, but it needs manual configuration by the end-user — the user needs to execute the rootless setup script.

```bash
# it creates a user systemd service and a user socket
dockerd-rootless-setuptool.sh install
```
Then enable and start the user Docker service.In short the user needs to do an additional one-time configuration step to switch from system-wide daemon to per-user daemon.The friction for this step is unnecessary and as told in last time it is not daemonless just like podman , it still works with daemon as a background service permanently.Switching to podman decreases the resource usage there is no background process unless needed. Podman natively has better security and also has Docker compatible CLI commands.Podman is better for RoboticsAcademy as it has true daemonless architecture and also has minimal setup for students/users.For Maintainers it will have fewer failures since the failures that included the daemon are no longer there.

#### How much difference would there be with Podman instead of Docker?

For most RoboticsAcademy users, **very little changes**. The existing workflows such as building images, running the exercises, using Compose, mounting volumes and exposing ports remain largely the same because both Docker and Podman implement the OCI container standards.

The differences become noticeable mainly in the following scenarios:

- **No need for the `docker` group.** With Docker, many users add themselves to the `docker` group to avoid using `sudo`, even though Docker's documentation warns that this effectively grants root-equivalent access. Podman avoids this entirely by running containers as the current user.

- **Better support for shared laboratory environments.** Since Podman is rootless by default, multiple students can use containers on the same machine without requiring administrator privileges or sharing a system-wide daemon. This makes deployments on university lab machines considerably easier.

- **Simpler recovery for beginners.** A user's containers and images remain isolated within their own home directory. If a student wants to reset their environment, they can remove only their own Podman storage without affecting other users or requiring privileged cleanup.

From a maintainer's perspective, the migration mainly simplifies the container runtime itself rather than changing the development workflow. Existing commands and Compose files require minimal changes, while eliminating the daemon removes an entire component that previously had to be installed, managed and debugged.

Overall, the migration is less about introducing new functionality and more about providing a simpler and safer default environment without significantly changing how RoboticsAcademy is used. How much difference would be there with Podman instead of Docker?


## Current Status of the Podman Migration testing : 

Mentor's ask was narrow: get the RoboticsAcademy image building and running under Podman, no GPU required for this pass, and call it a success if the image compiles and one exercise launches inside RA. Performance, the full exercise catalog, and GPU support were explicitly out of scope for this round.

### Getting the Full Stack Up

A standalone container is one thing, a compose stack is another. Two things had to be sorted before `docker-compose` running against the Podman backend would even attempt to bring the stack up.

First, Podman doesn't run a background daemon by default, so compose had nothing to talk to until I started the API socket: `systemctl --user start podman.socket`, enabled for persistence afterward.

Second, the compose file I was testing with requested an NVIDIA device reservation and `/dev/dri` access, which Podman couldn't interpret and wasn't needed for this pass anyway. Made a GPU-free copy, `dev-test-compose.podman.yaml`, for the test.

Third, Podman keeps its own image store, separate from Docker's. The images built in last week's Podman test weren't visible to compose under the names it expected, `jderobot/robotics-academy:test` and `jderobot/robotics-database:latest`, until I retagged them.

With both sorted, the stack came up clean, database `healthy`, app `Up`.

### Stale Checkouts Across Three Repos

Getting an exercise to actually load turned into the most confusing part of the week, and none of it was Podman's fault — I just hadn't pulled the latest commits across three different repos, all renamed the same day, July 7th, as part of one coordinated cleanup.

The frontend bundle was still calling `get_universes_list`, renamed to `get_worlds_list` — fixed with `yarn install && yarn run build`. The `RoboticsInfrastructure` submodule had renamed `universes.sql` to `worlds.sql`, breaking a bind mount — a one-line path fix (the same stale reference is still in the tracked compose files under `compose_cfg/` on `humble-devel`). And `src/`, a separate nested clone of `RoboticsApplicationManager` about 35 throwing `KeyError: 'world'` — fixed with a `git pull`.

Once all three were current, `follow_line` launched end to end, noVNC came up, the simulation loaded, and running the exercise's code got a response from the robot.

### A Real Podman Difference: chmod Fails on Root-Owned Files

Autosave, the save that fires automatically when leaving an exercise's editor, threw an "Error saving file:" popup with no message attached. This one was worth tracing properly rather than shrugging off.

![Error saving file popup with no message, shown while testing autosave on the Follow Line exercise]({{ "/assets/images/week8/Error podman.png" | relative_url }})

The file in question, `filesystem/follow_line/academy.py`, isn't in the repo at all, icommits behind its upstream, had renamed `world` to `scene` in the frontend-backend message format, t's gitignored, a per-student workspace file the app creates and manages at runtime. Its ownership traces to root, and its creation timestamp is from May 29th, seven weeks before this test, with more workspace files created across six other dates since. This machine also runs a genuine rootful Docker daemon alongside Podman, and plain Docker's root inside a container is real host root, no translation. So every time an exercise got opened for the first time over the past seven weeks using regular Docker, that container, as actual root, created these files, and they've stayed root-owned ever since.

Rootless Podman doesn't work that way by design, its container's "root" is just the host user in disguise, not real root. So when the app tried to save under Podman today, the content write itself went through fine, but the very next step, resetting the file's permission bits back to 777 via `chmod`, failed. Changing permission bits needs actual ownership, and disguised-root doesn't qualify. The error code that came back, `EPERM` rather than the more common `EACCES`, is the specific signature of exactly this kind of identity mismatch.

Nothing was lost, the edit itself saved, but the failed permission reset is what surfaces as the error popup.

### Result

The full stack ran under Podman, `follow_line` launched, and the simulation responded to code, which was the whole goal for this round. Everything that got there outside the codebase itself: two one-time host/Podman config changes, one scratch GPU-free compose file, three unrelated stale checkouts pulled up to date, and one genuine, reproducible Podman-vs-Docker behavior difference around rootless UID handling on legacy root-owned files.

## What's Next

Testing if the podman works with the GPU enabled which is the main pain-point of using podman
*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
