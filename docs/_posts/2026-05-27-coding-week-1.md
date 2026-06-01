---
title: "Coding Week 1 — First Dent in 29.5 GB"
date: 2026-05-27
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, optimization, ros2, cache]
---

Week 1 had one job: remove the caches. The community bonding 
period ended with a fully measured baseline — 29.5 GB, 102 minutes 
and 50 seconds cold build time, every layer accounted for. This 
week was about making the first measurable reduction in those numbers.

Week 1 started with a sync with the mentors before touching any code. 
A few things came out of that conversation that completely shaped how I spent the week.

First: PyTorch. It sits at 7.9 GB in a single layer and Javier mentioned 
he had already tried replacing it with ONNX Runtime for inference — it 
didn't work. So that's not something I touch without proper investigation. 
Second: the mentor specifically said making lots of PRs should not be the 
goal. One well-tested, properly validated change matters more than ten 
half-finished branches.

The confirmed Week 1 task: remove the caches.

---

## What the Audit Found

I already knew from community bonding that `Dockerfile.dependencies_humble` 
had cache problems — 17 separate apt install blocks, at least 4 leaking 
apt lists. But I needed exact line numbers before touching anything, so I 
ran a full audit.

Two categories of problems showed up.

**apt cache leaks — 5 blocks:**

| Lines | Problem |
|---|---|
| 91–101 | Incomplete brace form: `{apt,dpkg,cache,log}` instead of `*` |
| 113–118 | Missing `rm -rf /var/lib/apt/lists/*` entirely |
| 148–150 | Missing `rm -rf /var/lib/apt/lists/*` entirely |
| 171–177 | Missing `rm -rf /var/lib/apt/lists/*` entirely |
| 185–189 | Missing `rm -rf /var/lib/apt/lists/*` entirely |

**pip wheel cache — 8 blocks:**

Every single `pip install` RUN block in the file was missing 
`--no-cache-dir`. All 8 of them. A quick `git blame` confirmed this 
was never a deliberate decision — the flag was just never added, by 
multiple contributors over the project's history. Simple oversight 
accumulated over time.

Before making any change, I verified the safety of each apt fix — 
specifically checking whether any later RUN block ran `apt-get install` 
without its own `apt-get update`. Every block checked out clean. The 
NodeSource setup script at line 148 runs `apt update` internally, so 
cleaning the cache in earlier layers is safe.

---

## The Fix

Branch: `fix/removing-cache-layers` off `gsoc-project-7`.

Phase 1 — normalized all 5 apt cleanup blocks. The brace form 
`{apt,dpkg,cache,log}` only removes four named subdirectories and 
leaves everything else in `/var/lib/apt/lists/` intact — replacing it 
with `*` is the correct form.

Running `ls /var/lib/apt/lists/ | wc -l` inside the optimized container returns 46 — meaning some apt list files still persist from layers we did not touch in this pass. The 5 blocks we fixed are clean; the remaining files come from other layers. Full elimination requires either a multi-stage build or fixing every remaining apt block in a subsequent pass.

Phase 2 — added `--no-cache-dir` to all 8 pip install blocks. Without 
this flag, pip writes downloaded wheels into `~/.cache/pip` inside the 
layer. The packages install identically either way — the only difference 
is whether that cache gets baked into the image permanently.

The pip cache shows 5.1 MB remaining at `~/.cache/pip` — this is pip's HTTP metadata cache, not wheel files. `--no-cache-dir` prevents wheel persistence but not HTTP metadata. The actual wheel cache savings are reflected in the layer size reductions.

I also applied the same `--no-cache-dir` fix to the one pip install line 
in `Dockerfile.humble`.

---

## Removing netron and seaborn

During the mentor sync, David mentioned that `netron` and `seaborn` were 
used in an older version of the deep learning exercises and are no longer 
needed. I verified this — searched the entire codebase, found only one 
file using seaborn (`exercises/object_detection/benchmarking/Evaluator.py`) 
and it was a stale import from a primitive version of the exercise. Removed 
both from the Dockerfile and removed the dead import from the Python file.

Small change. Clean removal. Two fewer packages baked into every build.

Runtime verification confirms both packages are absent — `import netron` and `import seaborn` both fail with `ModuleNotFoundError`. However, the layer history still shows the old install command because the deps base image was reused from cache rather than rebuilt from scratch. A full cold rebuild will reflect the removal in the layer text as well.

---

## The Build That Got Stuck

Here is the friction moment from this week. At one point during testing, 
the Docker build ran for over 5000 seconds — nearly 84 minutes — and I 
could not figure out why it was that slow. Turns out it was building from 
the upstream repo's Dockerfile rather than my local changes. The build 
context was wrong. Once I fixed the context to point at my local source, 
the build ran in about 10 minutes by reusing the already-built 
`dependencies-humble` base layer.

Obvious in hindsight. Took longer than it should have to diagnose.

The before-baseline for a full cold build was 102m50s 
(72m17s for dependencies_humble + 30m06s for humble). After 
the cache fixes, dependencies_humble alone measured 62m52s — 
a 9m25s reduction. The humble layer was tested with a cached 
base (10 minutes), not a full cold build.

---

## Testing the Changes

Javier's requirement before any merge: all exercises must pass. I ran 
three exercises on the optimized image to validate nothing broke.

**Follow Line** — the robot tracked the line correctly, crosshair overlay 
worked, motion control responsive. No lag even with my GTX 1650.

**Basic Vacuum Cleaner** — obstacle avoidance ran as expected, bumper 
sensor integration intact, robot navigated around objects cleanly.

**Laser Mapping** — occupancy grid built correctly, odometry and laser 
scan fusion working, map populated as the robot moved.

All three launched, ran, and produced correct output. No crashes, no 
missing modules, no broken shared libraries.

Two small issues came up during testing. An `unable to import Frequency` 
error turned out to be a case sensitivity problem — `frequency` vs 
`Frequency`. A `cv2.line() has no member` warning was a pylint 
static-analysis false positive. Both fixed in under five minutes.

---

## Updated Layer Analysis

David asked to repeat the full layer analysis from community bonding 
against the optimized image. Here is the direct comparison.

Measured on Lenovo Legion 5, Ryzen 5 4600H, GTX 1650, 16 GB RAM, Kubuntu.

| Layer | Before | After | Change |
|---|---|---|---|
| PyTorch pip install | 7.9 GB | 4.79 GB | **-3.11 GB** |
| RoboticsInfrastructure clone | 4.61 GB | 4.78 GB | ~0* |
| RoboticsInfrastructure mv | 2.91 GB | 3.06 GB | ~0* |
| OMPL build | 2.39 GB | 2.4 GB | 0 |
| Gazebo11 + gstreamer | 1.87 GB | 1.87 GB | 0 |
| yarn install + build | 1.78 GB | 1.8 GB | 0 |
| ML pip stack | 1.3 GB | 867 MB | **-433 MB** |
| IndustrialRobots double colcon | 628 MB | 628 MB | 0 |
| ROS2 base install | 594 MB | 594 MB | 0 |
| PCL + Gazebo ROS plugins | 580 MB | 580 MB | 0 |
| lxde-common | 559 MB | 558 MB | 0 |
| Base toolchain | 495 MB | 495 MB | 0 |
| Gazebo Harmonic bridge | 468 MB | 468 MB | 0 |
| NVIDIA GL libs | 385 MB | 385 MB | 0 |
| Aerostack2 colcon build | 384 MB | 384 MB | 0 |
| MoveIt + ROS deps | 375 MB | 380 MB | 0 |
| IndustrialRobots clone | 292 MB | 292 MB | 0 |
| nodejs + yarn | 279 MB | 175 MB | **-104 MB** |
| gz-harmonic | 267 MB | 268 MB | 0 |
| RoboticsAcademy clone | 224 MB | 367 MB | +143 MB** |

*Slight increase due to additional commits in the fork branch used for this build.

**Larger because this build clones from the gsoc-project-7 branch 
which has more history than the original humble-devel baseline.

**Summary:**

| Metric | Before | After | Change |
|---|---|---|---|
| Full image size | 29.5 GB | 26.3 GB | **-3.2 GB** |
| dependencies_humble size | 19.5 GB | 16.1 GB | **-3.4 GB** |
| dependencies_humble build time | 72m17s | 62m52s | **-9m25s** |
| Full cold build time | 102m50s | not yet measured | — |

Zero functional changes. Same packages, same versions, same build logic. 
Just the dead weight removed.

---

## The Draft PR

Opened [PR #3848](https://github.com/JdeRobot/RoboticsAcademy/pull/3848) 
as a draft. Javier responded quickly — appreciated the way the work is 
documented and tracked.

Shariar raised a good point in the channel — we need a proper test 
criterion, specifically running all exercises against the optimized image. 
Javier confirmed that's the minimum requirement for any merge. The 
automated testing framework is next on the list.

---

## What the Mentors Want Next

Meeting briefs from this week's sync:

1. Check Python dependencies that are no longer needed — netron and 
   seaborn already removed, more to investigate
2. Remember RoboticsAcademy uses 2 Gazebo versions — changes must 
   not break either
3. Test exercises with mutually exclusive dependencies
4. Map runtime-only dependencies — this will feed directly into the 
   multi-stage build design
5. Investigate PyTorch alternatives or size reduction strategies

David specifically asked to repeat the layer-by-layer analysis from 
community bonding against the optimized image — the time and space 
tables need to be updated with the new numbers before the PR merges.

That analysis is happening next week alongside the dependency audit.

---

## What's Next

The cache cleanup is done and in a draft PR. Before it merges, 
two things need to happen: a full cold rebuild to get accurate 
final numbers, and broader exercise testing across both Gazebo 
versions the platform supports.

Next week focuses on the Python dependency audit — finding what 
else can be removed — and beginning the runtime dependency map 
that will drive the multi-stage build design. The 26.3 GB number 
will move again.
