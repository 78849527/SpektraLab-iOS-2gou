#!/usr/bin/env python3
"""Apply the iOS port's changes to the upstream engine.

    python3 tools/apply-ios-patch.py [engine_dir]

Every change is asserted before it is written: the script counts the hits for
each `(old, new)` pair and refuses to write anything unless every count is
exactly what it expects. That is deliberate -- an engine patch that silently
does not apply is a build that fails later and further away, and the failure
looks like an engine bug rather than a patch that missed.

The changes, and why each is needed:

1. `metal_gpu.cpp` -- the memory-pressure monitor.
   `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` and `DISPATCH_MEMORYPRESSURE_*` do
   not exist in the iOS SDK: the memory-pressure source is macOS-only. Left
   alone, this does not compile for iOS at all. The idle timer that shares
   the same queue is fine on iOS -- it is a plain timer -- so only the
   pressure half is conditional, and the queue stays unconditional because
   the timer needs it.

2. `metal_gpu.cpp` -- the result texture keeps its upstream `ShaderRead`
   usage. There is no `MTL::TextureUsageCopySource` in metal-cpp: Metal has
   no such usage bit, and blit-copying from a texture requires no usage
   declaration on the source. An earlier version of this patch added that
   flag and failed the iOS build with "no member named
   'TextureUsageCopySource'". The export blits into a shared buffer, which
   needs none of this.

3. `metal_gpu.cpp` -- `GPUFamilyMac2` under `TARGET_OS_OSX`.
   `supportsFamily(Mac2)` returns false on iOS, so the expression is
   harmless, but it is clearer to ask for a family that exists on the
   platform being built for.
"""

from __future__ import annotations

import sys
from pathlib import Path

# (label, old, new, expected_hits)
CHANGES: list[tuple[str, str, str, int]] = []


def change(label: str, old: str, new: str, expected: int = 1) -> None:
    CHANGES.append((label, old, new, expected))


FILE = "src/gpu/metal_gpu.cpp"

# --- 1a. the source creation ------------------------------------------------
# The queue is created unconditionally (the idle timer needs it); only the
# pressure source and its flags are macOS-only.

change(
    "memory-pressure source creation",
    """        pressure_source_ = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
            DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, pressure_queue_);
        if (!pressure_source_) {
            dispatch_release(pressure_queue_);
            pressure_queue_ = nullptr;
            return;
        }
        dispatch_set_context(pressure_source_, this);
        dispatch_source_set_event_handler_f(pressure_source_, &MetalGpu::pressure_event);
        dispatch_activate(pressure_source_);
        // Read once, here, where nothing can race with it (see the seam's
        // comment further down).
        const char* mode = std::getenv("SPEKTRAFILM_TEST_PRESSURE");
        if (mode && std::strcmp(mode, "critical") == 0) {
            test_pressure_flags_ = DISPATCH_MEMORYPRESSURE_CRITICAL;
        } else if (mode && std::strcmp(mode, "warn") == 0) {
            test_pressure_flags_ = DISPATCH_MEMORYPRESSURE_WARN;
        }
""",
    """#if TARGET_OS_OSX
        // The memory-pressure source is macOS-only: `DISPATCH_SOURCE_TYPE_
        // MEMORYPRESSURE` does not exist in the iOS SDK, so this whole block
        // is conditional. The idle timer below is not -- it is a plain timer
        // and works everywhere -- and it shares this queue, so the queue
        // itself is created unconditionally above.
        pressure_source_ = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
            DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, pressure_queue_);
        if (pressure_source_) {
            dispatch_set_context(pressure_source_, this);
            dispatch_source_set_event_handler_f(pressure_source_, &MetalGpu::pressure_event);
            dispatch_activate(pressure_source_);
            // Read once, here, where nothing can race with it (see the seam's
            // comment further down).
            const char* mode = std::getenv("SPEKTRAFILM_TEST_PRESSURE");
            if (mode && std::strcmp(mode, "critical") == 0) {
                test_pressure_flags_ = DISPATCH_MEMORYPRESSURE_CRITICAL;
            } else if (mode && std::strcmp(mode, "warn") == 0) {
                test_pressure_flags_ = DISPATCH_MEMORYPRESSURE_WARN;
            }
        }
#endif
""",
)

# --- 1b. the cancel ---------------------------------------------------------
# `stop_monitors` cancels both sources and drains the queue once. The drain
# has to stay unconditional: the idle timer needs it too.

change(
    "memory-pressure source cancel",
    """        if (pressure_source_) dispatch_source_cancel(pressure_source_);""",
    """#if TARGET_OS_OSX
        if (pressure_source_) dispatch_source_cancel(pressure_source_);
#endif""",
)

change(
    "memory-pressure source release",
    """        if (pressure_source_) { dispatch_release(pressure_source_); pressure_source_ = nullptr; }""",
    """#if TARGET_OS_OSX
        if (pressure_source_) { dispatch_release(pressure_source_); pressure_source_ = nullptr; }
#endif""",
)

# --- 1b+. the stop_monitors drain guard -------------------------------------
# `stop_monitors` drains the queue with a synchronous no-op; its guard
# references `pressure_source_`, which on iOS is inside `#if TARGET_OS_OSX` and
# therefore does not exist. Left unguarded, the patched file fails to compile
# with "use of undeclared identifier 'pressure_source_'". Drop it on iOS.

change(
    "stop monitors drain guard",
    """        if (pressure_queue_ && (pressure_source_ || idle_source_)) {""",
    """#if TARGET_OS_OSX
        if (pressure_queue_ && (pressure_source_ || idle_source_)) {
#else
        if (pressure_queue_ && idle_source_) {
#endif""",
)

# --- 1c. the handler --------------------------------------------------------
# `pressure_event` reads the source's data. On iOS there is no source, so the
# handler is not compiled and the seam that calls it is not either.

change(
    "pressure event handler",
    """    static void pressure_event(void* context) {
        auto* self = static_cast<MetalGpu*>(context);
        self->handle_pressure(dispatch_source_get_data(self->pressure_source_));
    }""",
    """#if TARGET_OS_OSX
    static void pressure_event(void* context) {
        auto* self = static_cast<MetalGpu*>(context);
        self->handle_pressure(dispatch_source_get_data(self->pressure_source_));
    }
#endif""",
)

change(
    "test pressure event handler",
    """    static void test_pressure_event(void* context) {
        auto* self = static_cast<MetalGpu*>(context);
        self->handle_pressure(self->test_pressure_flags_);
    }""",
    """#if TARGET_OS_OSX
    static void test_pressure_event(void* context) {
        auto* self = static_cast<MetalGpu*>(context);
        self->handle_pressure(self->test_pressure_flags_);
    }
#endif""",
)

change(
    "test pressure seam",
    """    void fire_test_pressure_if_asked() {
        if (!test_pressure_flags_ || !pressure_queue_) return;
        dispatch_sync_f(pressure_queue_, this, &MetalGpu::test_pressure_event);
    }""",
    """#if TARGET_OS_OSX
    void fire_test_pressure_if_asked() {
        if (!test_pressure_flags_ || !pressure_queue_) return;
        dispatch_sync_f(pressure_queue_, this, &MetalGpu::test_pressure_event);
    }
#else
    // The two frame-boundary call sites are unconditional, so iOS needs
    // a definition too. There is no pressure source (and no test hook)
    // on iOS, so it is a no-op rather than an unresolved symbol.
    void fire_test_pressure_if_asked() {}
#endif""",
)

# --- 1d. the members -------------------------------------------------------

change(
    "pressure source member",
    """    dispatch_source_t pressure_source_ = nullptr;""",
    """#if TARGET_OS_OSX
    dispatch_source_t pressure_source_ = nullptr;
#endif""",
)

change(
    "test pressure flags member",
    """    unsigned long test_pressure_flags_ = 0;""",
    """#if TARGET_OS_OSX
    unsigned long test_pressure_flags_ = 0;
#endif""",
)

# --- 1e. the report ---------------------------------------------------------
# `pool_stats().pressure_monitor` says whether the monitor is running. On
# iOS it is always false, and that is the truth.

change(
    "pressure monitor report",
    """        s.pressure_monitor = pressure_source_ != nullptr;""",
    """#if TARGET_OS_OSX
        s.pressure_monitor = pressure_source_ != nullptr;
#else
        s.pressure_monitor = false;
#endif""",
)

# --- 3. the GPU family probe ------------------------------------------------

change(
    "GPU family probe",
    """        const bool known = device_->supportsFamily(MTL::GPUFamilyMac2) ||
                           device_->supportsFamily(MTL::GPUFamilyApple7);""",
    """#if TARGET_OS_OSX
        const bool known = device_->supportsFamily(MTL::GPUFamilyMac2) ||
                           device_->supportsFamily(MTL::GPUFamilyApple7);
#else
        // `GPUFamilyMac2` does not exist on iOS.
        const bool known = device_->supportsFamily(MTL::GPUFamilyApple7);
#endif""",
)


def main() -> None:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("engine")
    path = root / FILE
    if not path.exists():
        print(f"missing: {path}")
        sys.exit(1)
    text = path.read_text(encoding="utf-8")

    # Every change is checked against the *original* text first, so one
    # change cannot invalidate the anchor of the next.
    staged = text
    for label, old, new, expected in CHANGES:
        hits = text.count(old)
        if hits != expected:
            print(f"FAILED: {label}: expected {expected} hit(s), found {hits}")
            sys.exit(1)
        staged = staged.replace(old, new)
        print(f"  ok: {label}")

    # A second pass over the staged text: the `#if`/`#endif` pairs must
    # balance, or the file will not compile at all.
    if staged.count("#if") != staged.count("#endif"):
        print(f"FAILED: #if/#endif do not balance: "
              f"{staged.count('#if')} vs {staged.count('#endif')}")
        sys.exit(1)

    path.write_text(staged, encoding="utf-8")
    print(f"patched {path}")


if __name__ == "__main__":
    main()
