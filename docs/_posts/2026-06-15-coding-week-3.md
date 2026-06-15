---
layout: single
title: "Coding Week 3 — PyTorch Out, CUDA Wheels In, Protobuf Untangled"
date: 2026-06-15
categories: [gsoc, coding-period]
tags: [docker, gsoc2026, jderobot, optimization, gazebo, ros2, onnx, cuda, protobuf]
---

Week 2 left three items open: two unpinned CUDA wheel versions, the C++ ONNX Runtime header version gap, and a full exercise test run on `Dockerfile.dependencies_humble`. The first and third are closed this week. The multi-stage build, originally slated to begin this week, moves to next week. PR [#3863](https://github.com/JdeRobot/RoboticsAcademy/pull/3863) is merged.


## The Dependency Swap

PyTorch was installed in `Dockerfile.dependencies_humble` with full CUDA 12.8 support. It is not imported anywhere in RoboticsAcademy or RoboticsInfrastructure — it was only there because it happened to bundle the CUDA shared libraries that `onnxruntime-gpu` needs at runtime.

The replacement is the seven CUDA 12.8 wheels that `onnxruntime-gpu==1.22.0` actually declares as runtime dependencies:

```dockerfile
RUN python3.10 -m pip install --no-cache-dir \
    nvidia-cuda-runtime-cu12==12.8.90 \
    nvidia-cublas-cu12==12.8.4.1 \
    nvidia-cudnn-cu12==9.10.2.21 \
    nvidia-nvjitlink-cu12==12.8.93 \
    nvidia-cuda-nvrtc-cu12==12.8.93 \
    nvidia-curand-cu12==10.3.10.19 \
    nvidia-cufft-cu12==11.4.1.4
```

All seven are hard-pinned. A build-time `ldconfig` step registers the pip-installed `.so` files with the system linker so they are visible to `onnxruntime-gpu` regardless of shell environment (sourcing a ROS 2 workspace cannot interfere).

**Why is the image size reduction only ~1 GB?** PyTorch at ~4.7 GB was removed, but the seven CUDA runtime wheels that replaced it add back a meaningful portion of that size. The net gain is the training-only components of PyTorch that were never needed — the wheels above are the runtime-only slice.

| Image | Size |
|---|---|
| `jderobot/robotics-academy:test` (full) | **18.2 GB** |
| `jderobot/robotics-applications:dependencies-humble` (base) | **12.8 GB** |


## The Protobuf Issue

After the initial build, Javier caught a crash in Gazebo Harmonic exercises:

```
TypeError: Descriptors cannot be created directly.
```

Diagnosing it took three steps.

**Phase 1 — What does onnxruntime-gpu actually declare?**
Running `importlib.metadata.distribution('onnxruntime-gpu').metadata.get_all('Requires-Dist')` inside the container reads the wheel's declared dependencies directly. This showed that `onnx` was not in the `Requires-Dist` list — it had been added manually and unnecessarily. It was a second, silent source of the same protobuf conflict.

**Phase 2 — What versions are actually resolved?**
`pip list --format=columns | grep nvidia` captured the exact versions pip had resolved for the seven CUDA wheels. Those exact versions were then pinned in the Dockerfile rather than letting pip re-resolve on every build.

**Phase 3 — Why does the crash happen?**
The traceback pointed to `gz/msgs10/time_pb2.py` failing at import with the descriptor error. Gazebo Harmonic's `gz.msgs10` Python bindings were generated with `protoc` 3.x. The C++ extension enforcement was introduced in protobuf 4.x, and `onnxruntime-gpu` pulls in bare `protobuf` as a transitive dependency, which pip resolves to the latest version (7.35.0 at the time of testing).

Pinning `protobuf<4` would have fixed the immediate crash but created a version floor that would break future `onnxruntime-gpu` upgrades. The correct fix is Google's own documented workaround:

```dockerfile
ENV PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python
```

This forces the pure-Python parser, which is forward-compatible with all `protoc` versions. The `importlib.metadata` inspection in Phase 1 was what made this clear — without it, pinning protobuf would have looked like the obvious fix.


## Testing

All exercises were verified on the patched image before the PR was merged:

| Exercise | Simulator | Result |
|---|---|---|
| Follow Person | Gazebo Harmonic | World loads, camera feed and person detection working |
| Follow Line | Gazebo Classic | Passing |
| Basic Vacuum Cleaner | Gazebo Classic | Passing |

GPU inference confirmed inside the container:
```
['TensorrtExecutionProvider', 'CUDAExecutionProvider', 'CPUExecutionProvider']
```

![Follow Person running on Gazebo Harmonic after the protobuf fix]({{ "/assets/images/week3/follow_person.png" | relative_url }})

![Follow Line regression check]({{ "/assets/images/week3/follow_line.png" | relative_url }})

![Basic Vacuum Cleaner regression check]({{ "/assets/images/week3/vacuum_cleaner.png" | relative_url }})


## What is Next

Two targets for Week 4:

**Multi-stage build** — split `Dockerfile.dependencies_humble` into a builder stage and a runtime stage so build-only tools and intermediate artifacts do not land in the shipped image.

**Gazebo audit** — David flagged that the image carries two Gazebo installations but only one is needed. Week 4 will identify which is redundant and what removing it saves.

*Part of my GSoC 2026 work with JdeRobot. Project tracked at [github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid](https://github.com/TheRoboticsClub/gsoc2026-Kartik_Jangid).*
