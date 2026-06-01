---
title: "Coding Week 1 — First Dent in 29.5 GB"
date: 2026-05-27
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, optimization, ros2, cache]
---

Week 1 had one job: remove the caches. The community bonding period ended with a fully measured baseline — 29.5 GB, 102 minutes and 50 seconds cold build time, every layer accounted for. This week was about making the first measurable reduction in those numbers.

Before touching any code I had a sync with the mentors. A few things came out of that conversation that completely shaped how I spent the week.

First: PyTorch. It sits at 7.9 GB in a single layer and Javier mentioned he had already tried replacing it with ONNX Runtime for inference — it did not work. So PyTorch is not something I touch without a proper investigation first. Second: David specifically said making lots of PRs should not be the goal. One well-tested, properly validated change matters more than ten half-finished branches. That framing stuck with me throughout the week.

The confirmed task for Week 1 was to remove the caches.


## What the Audit Found

I already knew from community bonding that `Dockerfile.dependencies_humble` had cache problems — 17 separate apt install blocks, at least 4 leaking apt lists. But I needed exact line numbers before touching anything, so I ran a full audit.

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

Every single `pip install` RUN block in the file was missing `--no-cache-dir`. All 8 of them. A quick `git blame` confirmed this was never a deliberate decision — the flag was just never added, by multiple contributors over the project's history. Simple oversight accumulated over time.

Before making any change, I verified the safety of each apt fix — specifically checking whether any later RUN block ran `apt-get install` without its own `apt-get update`. Every block checked out clean. The NodeSource setup script at line 148 runs `apt update` internally, so cleaning the cache in earlier layers is safe.


## The Fix

Branch: `fix/removing-cache-layers` off `gsoc-project-7`.

**Phase 1 — apt cleanup normalization.** The brace form `{apt,dpkg,cache,log}` only removes four named subdirectories and leaves everything else in `/var/lib/apt/lists/` intact. Replacing it with `*` is the correct form. Added the missing `rm -rf /var/lib/apt/lists/*` to the four blocks that had no cleanup at all.

Running `ls /var/lib/apt/lists/ | wc -l` inside the optimized container returns 46 — some apt list files still persist from layers we did not touch in this pass. The 5 blocks we fixed are clean. The remaining files come from other layers. Full elimination requires either a multi-stage build or fixing every remaining apt block in a subsequent pass.

**Phase 2 — pip --no-cache-dir.** Added the flag to all 8 pip install blocks in `Dockerfile.dependencies_humble`. Without it, pip writes downloaded wheels into `~/.cache/pip` inside the layer. The packages install identically either way — the only difference is whether that cache gets baked into the image permanently.

The pip cache shows 5.1 MB remaining at `~/.cache/pip` — this is pip's HTTP metadata cache, not wheel files. `--no-cache-dir` prevents wheel persistence but not HTTP metadata. The actual wheel savings are reflected in the layer size reductions.

I also applied the same fix to the one pip install line in `Dockerfile.humble`.


## Removing netron and seaborn

During the sync, David mentioned that `netron` and `seaborn` were used in an older version of the deep learning exercises and are no longer needed. I verified this — searched the entire codebase, found only one file using seaborn (`exercises/object_detection/benchmarking/Evaluator.py`) and it was a stale import from a primitive version of the exercise. I removed both packages from the Dockerfile and removed the dead import from the Python file.

Both packages are now gone from the Dockerfile source. However, the `optimized-cold` image built this week still carries them because that build used the previously-built `dependencies-humble` image as its base — the deps layer came from cache, not a fresh rebuild. The removal is committed and correct in the source. It will show up in the layer sizes only after a successful cold rebuild of `Dockerfile.dependencies_humble`. More on why that rebuild did not complete below.


## The Build That Got Stuck

Here is the first real friction moment from this week. At one point during testing, the Docker build ran for over 5000 seconds — nearly 84 minutes — and I could not figure out why it was that slow. It turned out I was building from the upstream repo's Dockerfile rather than my local branch. The build context was pointing at the wrong source tree entirely.

Once I fixed the context to point at my local fork, the build ran in about 10 minutes by reusing the already-built `dependencies-humble` base layer.

Obvious in hindsight. It took longer to diagnose than it should have, but it reinforced something important about working with multi-stage Docker builds: when you have separate base and application Dockerfiles, you need to be explicit about which image each build is pulling from at every step. A wrong FROM or a wrong build context and you are measuring someone else's numbers.


## The Cold Rebuild and What Broke

Toward the end of the week I ran a complete cold rebuild using `--no-cache` to get real before-versus-after numbers. I ran both Dockerfiles from scratch: `Dockerfile.humble` to build the full academy image, and `Dockerfile.dependencies_humble` to rebuild the base.

**Dockerfile.humble — 9 minutes 38 seconds.**

The humble build completed cleanly. Here is the per-step breakdown from the build log:

| Step | Time | What |
|---|---|---|
| [2/20] git clone RoboticsInfrastructure | **3m45s** | network download |
| [4/20] mv packages into workspace | **40s** | file moves |
| [10/20] git clone RoboticsAcademy | **22s** | network download |
| [14/20] colcon build workspace | **1m29s** | ROS2 compilation |
| [17/20] yarn install + build | **2m5s** | React frontend |
| Export to image | **1m9s** | layer flattening |

One thing worth noting: the RoboticsInfrastructure clone came in at 3m45s this run. In the community bonding baseline that same step took 23m27s. The repo and branch are identical — the difference is pure network speed between sessions. This kind of variance is why build time baselines need to be measured multiple times and on controlled connections before drawing conclusions.

**Dockerfile.dependencies_humble — failed at 17 minutes 23 seconds.**

This one did not finish. The build died at step 22 of 71, which is the PostgreSQL-18 install block, and the error was exit code 100. My first assumption was that the PGDG repository had a problem — maybe postgresql-18 was not available or the PPA URL had changed.

When I actually read the full log, the PGDG downloads worked fine. It fetched `postgresql-18` (7.5 MB), `postgresql-client-18` (2 MB), `libpq5`, `libpq-dev` — all from `apt.postgresql.org` without any issue. The failure was on two of postgresql's Ubuntu-side dependencies:

```
Err:7 http://archive.ubuntu.com jammy/main amd64 liburing2
  Temporary failure resolving 'archive.ubuntu.com'

Err:2 http://archive.ubuntu.com jammy/main amd64 libjson-perl
  Temporary failure resolving 'archive.ubuntu.com'
```

Docker's internal DNS resolver dropped the connection to `archive.ubuntu.com` at around the 47-second mark inside that step — 17 minutes into a long build. `liburing2` and `libjson-perl` are both standard Ubuntu packages that postgresql-18 depends on. The Dockerfile is not broken. This was a transient DNS failure inside the build container. Retrying the build on a stable network will let it go through.

The consequence for this week's numbers: the `optimized-cold` image was built using the pre-existing `dependencies-humble` image as its base. That means the netron/seaborn removal and some of the pip savings are not yet reflected in a freshly built deps layer. The `-3.4 GB` reduction in the deps image size was measured from a previous successful build of the optimized deps, not from this cold rebuild attempt.


## Testing the Changes

Javier's requirement before any merge: all exercises must pass. I ran three exercises on `jderobot/robotics-academy:local-no-sns` to validate nothing broke. The image tag is visible in the RoboticsAcademy status bar at the bottom of every exercise page — that is how I confirmed which image was actually running during each test.

**Follow Line** — the robot tracked the line correctly, crosshair overlay worked, motion control responsive. No lag even with my GTX 1650.

![Follow Line exercise running on local-no-sns]({{ "/assets/images/week1/follow_line.png" | relative_url }})

**Basic Vacuum Cleaner** — obstacle avoidance ran as expected, bumper sensor integration intact, robot navigated around objects cleanly.

![Basic Vacuum Cleaner exercise running on local-no-sns]({{ "/assets/images/week1/vacuum_cleaner.png" | relative_url }})

**Laser Mapping** — occupancy grid built correctly, odometry and laser scan fusion working, map populated as the robot moved.

![Laser Mapping exercise running on local-no-sns]({{ "/assets/images/week1/laser_mapping.png" | relative_url }})

All three launched, ran, and produced correct output. No crashes, no missing modules, no broken shared libraries.

Two small issues came up during testing. An `unable to import Frequency` error turned out to be a case sensitivity problem — `frequency` vs `Frequency`. A `cv2.line() has no member` warning was a pylint static-analysis false positive. Both fixed in under five minutes.


## Updated Layer Analysis

David asked to repeat the full layer analysis from community bonding against the optimized image. These numbers are from `docker history --no-trunc --format` run against both images on the same machine.

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

**Larger because this build clones from the gsoc-project-7 branch which has more history than the original humble-devel baseline.

The -433 MB reduction in the ML pip stack is entirely from `--no-cache-dir` — the netron and seaborn packages are still present in the deps layer used for this build because the cold deps rebuild did not complete. Once the deps image is rebuilt from scratch, additional savings from those two removals will show up in that layer.

**Summary:**

| Metric | Before | After | Change |
|---|---|---|---|
| Full image size | 29.5 GB | 26.4 GB | **-3.1 GB** |
| dependencies_humble size | 19.5 GB | 16.1 GB | **-3.4 GB** |
| dependencies_humble build time | 72m17s | 62m52s | **-9m25s** |
| Dockerfile.humble cold build time | 30m06s | 9m38s | **-20m28s** |
| Full cold build time | 102m50s | not yet complete | deps rebuild pending |

Zero functional changes. Same packages, same versions, same build logic. Just the dead weight removed.


## What Went Into the PR

The draft PR ([#3848](https://github.com/JdeRobot/RoboticsAcademy/pull/3848)) ended up with 7 commits across 4 distinct changes:

- **Normalized apt cleanup in 5 blocks** — replaced the incomplete brace form, added missing purges
- **Added --no-cache-dir to all pip install blocks** — 8 blocks in `Dockerfile.dependencies_humble`, 1 in `Dockerfile.humble`
- **Removed netron and seaborn** — packages gone from the Dockerfile, dead import cleaned from `object_detection/benchmarking/Evaluator.py`
- **Removed outdated benchmarking script** — `exercises/object_detection/benchmarking/` removed, aligned with what upstream PR #3851 also removed

Javier responded quickly and appreciated how the work is documented and tracked. Shariar raised a good point — we need a proper test criterion, specifically running all exercises against the optimized image before any merge. Javier confirmed that is the minimum requirement. The automated testing setup is next on the list.


## What the Mentors Want Next

From this week's sync:

1. Keep investigating Python dependencies that are no longer needed — netron and seaborn are done, more candidates likely exist
2. RoboticsAcademy supports two Gazebo versions — every change must be validated against both
3. Test exercises with mutually exclusive dependencies
4. Map runtime-only dependencies — this feeds directly into the multi-stage build design
5. Investigate PyTorch size reduction strategies — not a swap, but possibly a smaller build variant

David specifically asked to update the layer-by-layer time and space tables before the PR merges. That is in progress.


## What is Next

The cache cleanup is done and sitting in a draft PR. Before it merges, two things need to happen: a successful cold rebuild of the deps image to confirm the netron/seaborn removal and get a clean deps build time, and broader exercise testing across both Gazebo versions.

Next week focuses on the Python dependency audit — finding what else can be cut — and starting the runtime dependency map that will drive the multi-stage build design. The 26.4 GB number will move again.

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
