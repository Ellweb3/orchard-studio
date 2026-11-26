# orchard_engine

Rust port of `src/engine` (stage 1-2: transport, Channel Rack step patterns, swing,
one-shot sampler, metronome, starter kit) exposed to Flutter over a flat C ABI.

- `rust/` — the crate. `cargo test --release` runs engine tests (timing, swing, FL
  volume/pan laws) and `tests/drumkit_parity.rs` (kit == TS `src/audio/drumkit.ts`).
- `hook/build.dart` — builds the crate for the target via `native_toolchain_rust`.
- `lib/src/bindings.dart` — hand-written `@Native` bindings, keep in sync with `oe_*`.
- Android: `MainActivity` calls `nativeInitAndroidContext` so cpal can open AAudio.

Regenerate golden files after changing the TS kit:
`node --experimental-strip-types tools/golden.mts`
