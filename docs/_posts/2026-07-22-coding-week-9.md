---
layout: single
title: "Coding Week 9 — Podman GPU Passthrough"
date: 2026-07-16
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, podman, rootless, docker-compose]
---

This week focuses on the problems that can occur while working on running the image with podman and GPU enabled and Specifically why these problems occur and possible solution or plan of execution 

## Docker vs Podman GPU pass-through
As specified in the previous week's blog the podman is daemon-less and that causes me to do the daemon's work. Daemon with root privileges used to nvidia-container-runtime ,finds the driver files and attaches them.Podman uses a different way since it doesn't have Nvidia runtime which is CDI and podman reads this yaml file for details. The CDI spec doesn't just attach the GPU device, it also mounts the NVIDIA driver libraries the container needs to actually render; without them you'd get the device but no working graphics.

## UID/GID and rootless
Since Podman rootless maps the container's root back to my unprivileged host user, the container thinks it's root, but outside it's just me, so a process that tries to access a host device file with the wrong UID or GID gets an error. Most importantly the GPU render node on the host is owned by group `render` and if the container's process doesn't have it's group ID the GPU is denied and it falls back silently to CPU rendering (silent fallback is a problem). `keep-id` maps the user to itself inside the container so the file ownership stays the same, and CDI injects the render/video group access automatically, so no extra group setup was needed. On my machine this currently works only because my desktop login grants temporary access to the GPU device; that won't exist on a server.

## Problems and their solutions

### The blocker: an outdated podman I forgot to update
This one was my own mistake, I hadn't kept podman updated. When two tools that share a file drift apart in version, one writes something the other can't read. Here `nvidia-ctk` (which generates the CDI spec) wrote a newer field, `additionalGids`, that my older podman's parser doesn't recognize. Instead of ignoring the unknown field, the parser rejects the entire spec (`json: unknown field "additionalGids"`) → 0 devices found → no GPU. This happens before compose is even involved, so compose would hit the same wall.

It's not only my mistake though. Ubuntu 24.04 ships podman 4.9.3 in its repositories and that's the ceiling, so a plain `apt upgrade` won't move past it. Any student following the default install path on Ubuntu 24.04 would hit this exact wall, which makes updating podman a real prerequisite for the project and not just something I overlooked.

The fix is to update podman so its parser understands the newer spec. A user `containers.conf` redirects the CDI search path but podman ignores it and reads `/var/run/cdi` anyway, and `~/.config/cdi` holds two conflicting spec files, cleared as part of the same fix.

### Which compose engine to use
There are two "podman compose" tools and they don't behave the same. `podman compose` (which delegates to docker-compose) mangles `nvidia.com/gpu=all` into a plain bind-mount and needs the podman socket, which is disabled in rootless. The Python `podman-compose` forwards `--device nvidia.com/gpu=all` to podman untouched, so that's the engine I'll use.

### NVIDIA environment variables
`NVIDIA_DRIVER_CAPABILITIES` stays, it controls which graphics libraries get mounted. `NVIDIA_VISIBLE_DEVICES` is dropped as a GPU selector here: it belongs to the old runtime-hook mechanism, and in CDI mode the device is chosen by its CDI name instead.

## Extra read — compose file duplication
Right now the compose_cfg contains 8 compose files which are mostly identical-every combination of {user, dev} × {cpu, gpu, nvidia, nvidia-windows}.One change needs to be replicated in all other files. I can put base code into one file and put the actual difference(GPU bits) into small override fragments I layer on top.base + nvidia-override, base + intel-override, base + nothing for CPU.

## Conclusion
The blocker is understood and has a chosen fix (upgrading podman). The path forward is CDI-based GPU passthrough run through Python `podman-compose`, with keep-id and keep-groups handling rootless identity.