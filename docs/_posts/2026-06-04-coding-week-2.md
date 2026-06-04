---
layout: single
title: "Coding Week 2 — Eliminating the 4.6 GB Ghost Layer"
date: 2026-06-04
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, optimization, gazebo, ros2]
---

Week 1 removed the caches. Week 2 addressed the largest single bloat source identified in the community bonding audit: the **4.6 GB copy-on-write ghost layer** produced by the `RoboticsInfrastructure` clone in `Dockerfile.humble`.

---

## Brief Goal

1. Collapse the split `git clone` + `mv` + `rm -rf .git` instructions in `Dockerfile.humble` into a single atomic `RUN` block to eliminate the ghost layer.

---

## Problems Encountered

### Problem 1 — Docker Copy-on-Write Bloat

The community bonding audit identified the root cause but Week 2 was where it had to actually be fixed. In `Dockerfile.humble`, the `RoboticsInfrastructure` repository was cloned in one `RUN` instruction (**4.61 GB** layer), packages were relocated with `mv` in a second instruction (**2.91 GB** layer), and `.git` was deleted in a third. Because each `RUN` produces an independent overlay layer, Docker baked all three states permanently into the image history. The clone layer — including the full `.git` pack files — never left the image regardless of what happened in subsequent steps.


---

## Approaches Taken

### Fix 1 — Atomic RUN Block

Refactored the three separate instructions into a single chained `RUN`:

```dockerfile
# Before — three separate layers (ghost layers accumulate)
RUN git clone --depth 1 https://github.com/JdeRobot/RoboticsInfrastructure.git /tmp/RI
RUN mv /tmp/RI/Launchers /opt/jderobot/ && \
    mv /tmp/RI/Universes /opt/jderobot/ && \
    mv /tmp/RI/Worlds /opt/jderobot/
RUN rm -rf /tmp/RI

# After — single layer, only the final state is recorded
RUN git clone --depth 1 https://github.com/JdeRobot/RoboticsInfrastructure.git /tmp/RI && \
    mv /tmp/RI/Launchers /opt/jderobot/ && \
    mv /tmp/RI/Universes /opt/jderobot/ && \
    mv /tmp/RI/Worlds /opt/jderobot/ && \
    rm -rf /tmp/RI
```

The `/opt/jderobot` root directory structure (`Launchers/`, `Universes/`, `Worlds/`) was explicitly preserved — these paths are hardcoded in both the PostgreSQL database and the Django backend. Changing the destination layout would have broken exercise routing silently.

---

## Weekly Achievements

| Item | Result |
|---|---|
| Full image size | **26.4 GB → 21.8 GB** |
| Ghost layer eliminated | **−4.6 GB** (clone + `.git` no longer baked in) |
| `dive` efficiency score | **96%** — infrastructure duplication fully removed |

**`dive` analysis after the fix:**

![dive terminal analysis confirming 96% image efficiency]({{ "/assets/images/week2/Screenshot_20260604_173324.png" | relative_url }})

**Visual Follow Line running successfully in the UI:**

![Visual Follow Line exercise running in RoboticsAcademy UI]({{ "/assets/images/week2/Screenshot_20260604_182352.png" | relative_url }})

---

## What is Next

The 21.8 GB number is the new baseline. Next up: the Python dependency audit to identify further packages that can be removed, and the start of the runtime dependency map that feeds into the multi-stage build design. OMPL — the 34-minute compile and 2.39 GB layer — is the next major target.

---

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
