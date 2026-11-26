//! Orchard engine: flat C ABI for Dart FFI (pattern from flutter_audio_fx /
//! hum_cpal, no flutter_rust_bridge). All `oe_*` functions taking a handle
//! are called from the Flutter UI isolate; the audio thread is reached only
//! via the rtrb command queue. `oe_parse_soundfont` is handle-free so it can
//! run on a background isolate.

pub mod drumkit;
pub mod engine;
pub mod export;
pub mod fx;
pub mod instrument;
pub mod laws;
mod output;
pub mod threeosc;

use std::ffi::{CString, c_char};
use std::io::Cursor;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::sync::Arc;
use std::sync::atomic::Ordering;

use rustysynth::SoundFont;

use engine::{Clip, Cmd, Garbage, MAX_CH, Note, Status};
use fx::{Effect, FxKind};
use instrument::{Instrument, Sampler, SoundFontInst};
use threeosc::OscParams;

enum Backend {
    /// Real-time: the engine lives in the cpal callback.
    Live { tx: rtrb::Producer<Cmd>, garbage: rtrb::Consumer<Garbage>, output: output::Output },
    /// Export: the engine is called directly on the caller's thread.
    Offline { engine: Box<engine::Engine> },
}

pub struct OeHandle {
    backend: Backend,
    status: Arc<Status>,
    sr: f64,
    kit_size: usize,
    sf: Option<Arc<SoundFont>>,
}

/// A parsed SoundFont, owned by Dart until attached.
pub struct OeSoundFont(Arc<SoundFont>);

thread_local! {
    static LAST_ERROR: std::cell::RefCell<Option<CString>> = const { std::cell::RefCell::new(None) };
}

fn set_error(msg: String) {
    LAST_ERROR.with(|e| *e.borrow_mut() = CString::new(msg).ok());
}

/// Opens the default output device and starts the engine. Null on failure
/// (see `oe_last_error`).
#[unsafe(no_mangle)]
pub extern "C" fn oe_create() -> *mut OeHandle {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let status = Arc::new(Status::new());
        let (tx, rx) = rtrb::RingBuffer::<Cmd>::new(8192);
        let (gtx, grx) = rtrb::RingBuffer::<Garbage>::new(8192);
        let (output, sr) = output::Output::start(Arc::clone(&status), rx, gtx)?;
        let kit_size = drumkit::builtin_kit().len();
        Ok::<_, String>(OeHandle { backend: Backend::Live { tx, garbage: grx, output }, status, sr, kit_size, sf: None })
    }));
    match r {
        Ok(Ok(h)) => Box::into_raw(Box::new(h)),
        Ok(Err(e)) => {
            set_error(e);
            ptr::null_mut()
        }
        Err(_) => {
            set_error("panic while starting audio".into());
            ptr::null_mut()
        }
    }
}

/// Last error message of this thread, or null. Valid until the next error.
#[unsafe(no_mangle)]
pub extern "C" fn oe_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ref().map_or(ptr::null(), |s| s.as_ptr()))
}

/// # Safety
/// `h` must come from `oe_create` and not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn oe_destroy(h: *mut OeHandle) {
    if !h.is_null() {
        drop(unsafe { Box::from_raw(h) });
    }
}

fn handle<'a>(h: *mut OeHandle) -> Option<&'a mut OeHandle> {
    unsafe { h.as_mut() }
}

/// Drops whatever the audio thread handed back (old note lists, instruments).
#[unsafe(no_mangle)]
pub extern "C" fn oe_collect(h: *mut OeHandle) {
    if let Some(OeHandle { backend: Backend::Live { garbage, .. }, .. }) = handle(h) {
        while garbage.pop().is_ok() {}
    }
}

fn send(h: *mut OeHandle, cmd: Cmd) -> bool {
    match handle(h).map(|h| &mut h.backend) {
        Some(Backend::Live { tx, garbage, .. }) => {
            while garbage.pop().is_ok() {}
            tx.push(cmd).is_ok()
        }
        Some(Backend::Offline { engine }) => {
            engine.handle(cmd);
            true
        }
        None => false,
    }
}

/// An engine without audio output for exporting, sharing `live`'s SoundFont.
/// Configure it with the usual `oe_*` setters, start it with `oe_play`, then
/// call `oe_export`. Free with `oe_destroy`.
#[unsafe(no_mangle)]
pub extern "C" fn oe_offline_create(live: *mut OeHandle, sample_rate: u32) -> *mut OeHandle {
    let sf = handle(live).and_then(|h| h.sf.clone());
    let sr = if sample_rate == 0 { 44100.0 } else { sample_rate as f64 };
    let status = Arc::new(Status::new());
    let engine = Box::new(engine::Engine::new(sr, Arc::clone(&status), None));
    let kit_size = engine.kit_size();
    Box::into_raw(Box::new(OeHandle { backend: Backend::Offline { engine }, status, sr, kit_size, sf }))
}

/// Renders `play_frames` + up to `tail_frames` (stops early on silence) to
/// `path`. `format`: 0 WAV, 1 MP3 (`kbps`). `progress` (f32 bits, 0..1) may be
/// null. Blocking: call it from a background isolate.
///
/// # Safety
/// `h` must be an offline handle used by no other thread meanwhile; `path` a
/// NUL-terminated UTF-8 string; `progress` null or valid for writes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn oe_export(
    h: *mut OeHandle,
    play_frames: u64,
    tail_frames: u64,
    path: *const c_char,
    format: u8,
    kbps: u32,
    progress: *const std::sync::atomic::AtomicU32,
) -> bool {
    let Some(OeHandle { backend: Backend::Offline { engine }, .. }) = handle(h) else {
        set_error("oe_export needs an offline handle".into());
        return false;
    };
    if path.is_null() {
        return false;
    }
    let Ok(path) = (unsafe { std::ffi::CStr::from_ptr(path) }).to_str() else {
        set_error("path is not UTF-8".into());
        return false;
    };
    let fmt = if format == 1 { export::Format::Mp3 } else { export::Format::Wav };
    let progress = unsafe { progress.as_ref() };
    match catch_unwind(AssertUnwindSafe(|| export::render(engine, play_frames, tail_frames, path, fmt, kbps, progress))) {
        Ok(Ok(())) => true,
        Ok(Err(e)) => {
            set_error(e);
            false
        }
        Err(_) => {
            set_error("panic while exporting".into());
            false
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn oe_set_tempo(h: *mut OeHandle, bpm: f64) -> bool {
    send(h, Cmd::Tempo(bpm))
}
#[unsafe(no_mangle)]
pub extern "C" fn oe_set_swing(h: *mut OeHandle, swing: f32) -> bool {
    send(h, Cmd::Swing(swing))
}
#[unsafe(no_mangle)]
pub extern "C" fn oe_set_master(h: *mut OeHandle, fader: f32) -> bool {
    send(h, Cmd::Master(fader))
}
#[unsafe(no_mangle)]
pub extern "C" fn oe_play(h: *mut OeHandle, play: bool) -> bool {
    send(h, Cmd::Play(play))
}
#[unsafe(no_mangle)]
pub extern "C" fn oe_set_metronome(h: *mut OeHandle, on: bool) -> bool {
    send(h, Cmd::Metronome(on))
}

/// Replaces the notes of channel `ch` in pattern `pat` (copied).
///
/// # Safety
/// `notes` must point to `count` valid `Note`s (or be null with count 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn oe_set_notes(h: *mut OeHandle, pat: u8, ch: u8, notes: *const Note, count: u32) -> bool {
    let list: Box<[Note]> = if notes.is_null() || count == 0 {
        Box::default()
    } else {
        let mut v = unsafe { std::slice::from_raw_parts(notes, count as usize) }.to_vec();
        v.sort_by_key(|n| n.pos);
        v.into_boxed_slice()
    };
    send(h, Cmd::Notes { pat, ch, notes: list })
}

/// `insert`: mixer insert (0 = master).
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn oe_set_channel(
    h: *mut OeHandle,
    ch: u8,
    vol: f32,
    pan: f32,
    pitch: f32,
    mute: bool,
    used: bool,
    insert: u8,
) -> bool {
    send(h, Cmd::Channel { ch, vol, pan, pitch, mute, used, insert })
}

#[unsafe(no_mangle)]
pub extern "C" fn oe_song_mode(h: *mut OeHandle, on: bool) -> bool {
    send(h, Cmd::SongMode(on))
}

/// Replaces the Playlist clips (copied).
///
/// # Safety
/// `clips` must point to `count` valid `Clip`s (or be null with count 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn oe_set_clips(h: *mut OeHandle, clips: *const Clip, count: u32) -> bool {
    let list: Box<[Clip]> = if clips.is_null() || count == 0 {
        Box::default()
    } else {
        unsafe { std::slice::from_raw_parts(clips, count as usize) }.to_vec().into_boxed_slice()
    };
    send(h, Cmd::Clips(list))
}

/// Mixer insert `idx` (0 = master): fader 0..1 (0.8 = 0 dB), pan -1..1.
#[unsafe(no_mangle)]
pub extern "C" fn oe_set_insert(h: *mut OeHandle, idx: u8, vol: f32, pan: f32, mute: bool) -> bool {
    send(h, Cmd::Insert { idx, vol, pan, mute })
}

/// Puts a new effect of `kind` (fx::FxKind) in a slot, or clears it (kind 255).
/// `params` (6 floats, 0..1) may be null for the defaults.
///
/// # Safety
/// `params` must be null or point to 6 floats.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn oe_set_fx(h: *mut OeHandle, ins: u8, slot: u8, kind: u8, params: *const f32) -> bool {
    let Some(hh) = handle(h) else { return false };
    let fx = FxKind::from_u8(kind).map(|k| {
        let mut e = Effect::new(k, hh.sr as f32);
        if !params.is_null() {
            let p = unsafe { std::slice::from_raw_parts(params, fx::MAX_PARAMS) };
            for (i, v) in p.iter().enumerate() {
                e.set(i, *v);
            }
        }
        Box::new(e)
    });
    send(h, Cmd::Fx { ins, slot, fx })
}

#[unsafe(no_mangle)]
pub extern "C" fn oe_fx_param(h: *mut OeHandle, ins: u8, slot: u8, param: u8, value: f32) -> bool {
    send(h, Cmd::FxParam { ins, slot, param, value })
}

#[unsafe(no_mangle)]
pub extern "C" fn oe_fx_bypass(h: *mut OeHandle, ins: u8, slot: u8, bypass: bool) -> bool {
    send(h, Cmd::FxBypass { ins, slot, bypass })
}

/// Mixer insert peak (post fader) since the previous call, then resets it.
#[unsafe(no_mangle)]
pub extern "C" fn oe_take_insert_peak(h: *mut OeHandle, idx: u32) -> f32 {
    let Some(h) = handle(h) else { return 0.0 };
    h.status.ins_peaks.get(idx as usize).map_or(0.0, |p| f32::from_bits(p.swap(0, Ordering::Relaxed)))
}

#[unsafe(no_mangle)]
pub extern "C" fn oe_set_sampler(h: *mut OeHandle, ch: u8, sample: u8) -> bool {
    let Some(hh) = handle(h) else { return false };
    let sample = (sample as usize).min(hh.kit_size - 1);
    send(h, Cmd::Instrument { ch, inst: Box::new(Instrument::Sampler(Sampler::new(sample))) })
}

/// # Safety
/// `params` must point to a valid `OscParams`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn oe_set_osc(h: *mut OeHandle, ch: u8, params: *const OscParams) -> bool {
    let Some(hh) = handle(h) else { return false };
    let Some(p) = (unsafe { params.as_ref() }) else { return false };
    let inst = Instrument::osc(*p, hh.sr);
    send(h, Cmd::Instrument { ch, inst: Box::new(inst) })
}

/// Needs an attached SoundFont. Bank 128 = drum kits.
#[unsafe(no_mangle)]
pub extern "C" fn oe_set_soundfont(h: *mut OeHandle, ch: u8, bank: u16, program: u8) -> bool {
    let Some(hh) = handle(h) else { return false };
    let Some(sf) = hh.sf.clone() else {
        set_error("no SoundFont loaded".into());
        return false;
    };
    match SoundFontInst::new(&sf, hh.sr, bank, program) {
        Ok(inst) => send(h, Cmd::Instrument { ch, inst: Box::new(Instrument::SoundFont(inst)) }),
        Err(e) => {
            set_error(e);
            false
        }
    }
}

/// Parses an .sf2 image (copied). Safe on any thread. Null on failure.
///
/// # Safety
/// `data` must point to `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn oe_parse_soundfont(data: *const u8, len: usize) -> *mut OeSoundFont {
    if data.is_null() {
        return ptr::null_mut();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    match catch_unwind(|| SoundFont::new(&mut Cursor::new(bytes))) {
        Ok(Ok(sf)) => Box::into_raw(Box::new(OeSoundFont(Arc::new(sf)))),
        Ok(Err(e)) => {
            set_error(format!("{e:?}"));
            ptr::null_mut()
        }
        Err(_) => {
            set_error("panic while parsing SoundFont".into());
            ptr::null_mut()
        }
    }
}

/// Takes ownership of `sf`.
///
/// # Safety
/// `sf` must come from `oe_parse_soundfont` and not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn oe_attach_soundfont(h: *mut OeHandle, sf: *mut OeSoundFont) -> bool {
    if sf.is_null() {
        return false;
    }
    let sf = unsafe { Box::from_raw(sf) };
    match handle(h) {
        Some(h) => {
            h.sf = Some(sf.0);
            true
        }
        None => false,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn oe_sf_preset_count(h: *mut OeHandle) -> u32 {
    handle(h).and_then(|h| h.sf.as_ref()).map_or(0, |sf| sf.get_presets().len() as u32)
}

/// Writes preset `i`'s NUL-terminated name into `name` (cap bytes) and its bank / program.
///
/// # Safety
/// `name` must hold `cap` writable bytes; `bank` / `program` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn oe_sf_preset_info(
    h: *mut OeHandle,
    i: u32,
    name: *mut u8,
    cap: u32,
    bank: *mut u16,
    program: *mut u8,
) -> bool {
    let Some(sf) = handle(h).and_then(|h| h.sf.as_ref()) else { return false };
    let Some(p) = sf.get_presets().get(i as usize) else { return false };
    if name.is_null() || cap == 0 || bank.is_null() || program.is_null() {
        return false;
    }
    let s = p.get_name().trim_end_matches('\0').trim().as_bytes();
    let mut n = s.len().min(cap as usize - 1);
    while n > 0 && n < s.len() && (s[n] & 0xC0) == 0x80 {
        n -= 1; // don't cut a UTF-8 sequence
    }
    unsafe {
        ptr::copy_nonoverlapping(s.as_ptr(), name, n);
        *name.add(n) = 0;
        *bank = p.get_bank_number().clamp(0, u16::MAX as i32) as u16;
        *program = p.get_patch_number().clamp(0, 127) as u8;
    }
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn oe_set_pattern_len(h: *mut OeHandle, pat: u8, steps: u8) -> bool {
    send(h, Cmd::PatternLen { pat, steps })
}
#[unsafe(no_mangle)]
pub extern "C" fn oe_select_pattern(h: *mut OeHandle, pat: u8) -> bool {
    send(h, Cmd::SelectPattern(pat))
}
#[unsafe(no_mangle)]
pub extern "C" fn oe_note_on(h: *mut OeHandle, ch: u8, key: u8, vel: u8) -> bool {
    send(h, Cmd::NoteOn { ch, key, vel })
}
#[unsafe(no_mangle)]
pub extern "C" fn oe_note_off(h: *mut OeHandle, ch: u8, key: u8) -> bool {
    send(h, Cmd::NoteOff { ch, key })
}

/// Pattern-local playback position in ticks (PPQ 96).
#[unsafe(no_mangle)]
pub extern "C" fn oe_position(h: *mut OeHandle) -> f64 {
    handle(h).map_or(0.0, |h| f64::from_bits(h.status.pos_ticks.load(Ordering::Relaxed)))
}

/// Peak since the previous call for channel `idx` (MAX_CH = master), then resets it.
#[unsafe(no_mangle)]
pub extern "C" fn oe_take_peak(h: *mut OeHandle, idx: u32) -> f32 {
    let Some(h) = handle(h) else { return 0.0 };
    h.status.peaks.get(idx as usize).map_or(0.0, |p| f32::from_bits(p.swap(0, Ordering::Relaxed)))
}

#[unsafe(no_mangle)]
pub extern "C" fn oe_sample_rate(h: *mut OeHandle) -> u32 {
    handle(h).map_or(0, |h| h.status.sample_rate.load(Ordering::Relaxed))
}

#[unsafe(no_mangle)]
pub extern "C" fn oe_xruns(h: *mut OeHandle) -> u64 {
    match handle(h).map(|h| &h.backend) {
        Some(Backend::Live { output, .. }) => output.xruns.load(Ordering::Relaxed),
        _ => 0,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn oe_max_channels() -> u32 {
    MAX_CH as u32
}

#[cfg(target_os = "android")]
mod android {
    //! cpal needs the JavaVM + Context in ndk-context before it can open
    //! AAudio streams. MainActivity calls this once (hum_flutter pattern).
    use std::ffi::c_void;
    use std::ptr;
    use std::sync::Once;

    use jni::sys::{JNIEnv, JavaVM, jclass, jobject};

    static INIT: Once = Once::new();

    /// # Safety
    /// Called by the JVM with a valid env and a non-null Context.
    #[unsafe(no_mangle)]
    pub unsafe extern "system" fn Java_com_ellweb_orchardtab_MainActivity_nativeInitAndroidContext(
        env: *mut JNIEnv,
        _class: jclass,
        context: jobject,
    ) {
        if env.is_null() || context.is_null() {
            return;
        }
        INIT.call_once(|| {
            let mut vm: *mut JavaVM = ptr::null_mut();
            let vtable = unsafe { *env };
            if vtable.is_null() {
                return;
            }
            let get_vm = unsafe { (*vtable).v1_2.GetJavaVM };
            if unsafe { get_vm(env, &mut vm) } != 0 || vm.is_null() {
                return;
            }
            let new_global_ref = unsafe { (*vtable).v1_2.NewGlobalRef };
            let ctx = unsafe { new_global_ref(env, context) };
            if ctx.is_null() {
                return;
            }
            unsafe { ndk_context::initialize_android_context(vm.cast::<c_void>(), ctx.cast::<c_void>()) };
        });
    }
}

#[cfg(test)]
mod abi_tests {
    /// Must match the Dart structs in lib/src/bindings.dart (see test/abi_test.dart).
    #[test]
    fn struct_layouts() {
        assert_eq!(std::mem::size_of::<super::Note>(), 12);
        assert_eq!(std::mem::size_of::<super::Clip>(), 12);
        assert_eq!(std::mem::size_of::<super::OscParams>(), 32);
        assert_eq!(std::mem::offset_of!(super::OscParams, attack), 16);
    }
}
