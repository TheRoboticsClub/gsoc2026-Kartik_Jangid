---
layout: single
title: "Coding Week 9 — Podman GPU Passthrough"
date: 2026-07-16
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, podman, rootless, docker-compose]
---

This week I focused on getting the image running with Podman and GPU support, then narrowing down why the GPU path failed and what the next fix should be.

## Docker vs Podman GPU pass-through
As noted in the previous week's blog, Podman is daemonless, so the GPU setup has to happen through CDI instead of a rootful runtime hook. With NVIDIA, CDI is what tells Podman which device to expose and which driver libraries to mount; without those libraries, the container would see the device but would not render correctly.

## UID/GID and rootless
Since rootless Podman maps the container's root back to my unprivileged host user, the process inside the container can still fail on a host device file if the UID or GID does not line up. The GPU render node on the host is owned by group `render`, so if the container does not get the right group access the GPU gets denied and quietly falls back to CPU rendering. `keep-id` keeps the user mapping aligned, and CDI injects the render/video group access automatically, so no extra group setup was needed. On my machine this currently works only because my desktop login grants temporary access to the GPU device; that will not exist on a server.

## Problems and their solutions

### The blocker: an outdated podman I forgot to update
This one was my own mistake, I hadn't kept podman updated. When two tools that share a file drift apart in version, one writes something the other can't read. Here `nvidia-ctk` (which generates the CDI spec) wrote a newer field, `additionalGids`, that my older podman's parser doesn't recognize. Instead of ignoring the unknown field, the parser rejects the entire spec (`json: unknown field "additionalGids"`) → 0 devices found → no GPU. This happens before compose is even involved, so compose would hit the same wall.

It's not only my mistake though. Ubuntu 24.04 ships podman 4.9.3 in its repositories and that's the ceiling, so a plain `apt upgrade` won't move past it. Any student following the default install path on Ubuntu 24.04 would hit this exact wall, which makes updating podman a real prerequisite for the project and not just something I overlooked.

The fix is to update Podman so its parser understands the newer spec. I also found that my own `containers.conf` was overriding Podman's built-in CDI paths with a personal one, which made this work only because of a leftover debugging file from the version mismatch. Removing that override left GPU passthrough working the same way, but now on the paths a fresh install already has; `~/.config/cdi` also held two conflicting spec files, which I cleared as part of the same fix.

### Which compose engine to use
There are two "podman compose" tools and they don't behave the same. `podman compose` (which delegates to docker-compose) mangles `nvidia.com/gpu=all` into a plain bind-mount and needs the podman socket, which is disabled in rootless. The Python `podman-compose` forwards `--device nvidia.com/gpu=all` to podman untouched, so that's the engine I'll use.
I also hit a PATH issue inside `podman-compose`, where it was resolving the wrong helper binary at first, so the same stale-tooling pattern showed up twice before the stack would start.
I also hit a PATH issue inside `podman-compose`, where it was resolving the wrong helper binary at first, so the same stale-tooling pattern showed up twice before the stack would start.

### NVIDIA environment variables
`NVIDIA_DRIVER_CAPABILITIES` stays, it controls which graphics libraries get mounted. `NVIDIA_VISIBLE_DEVICES` is dropped as a GPU selector here: it belongs to the old runtime-hook mechanism, and in CDI mode the device is chosen by its CDI name instead.

## Extra read — compose file duplication
Right now the compose_cfg contains 8 compose files which are mostly identical-every combination of {user, dev} × {cpu, gpu, nvidia, nvidia-windows}.One change needs to be replicated in all other files. I can put base code into one file and put the actual difference(GPU bits) into small override fragments I layer on top.base + nvidia-override, base + intel-override, base + nothing for CPU.

## Conclusion
The path forward is CDI-based GPU passthrough run through Python `podman-compose`, with keep-id and keep-groups handling rootless identity.