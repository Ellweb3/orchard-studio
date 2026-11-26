//! Orchard engine: flat C ABI for Dart FFI (pattern from flutter_audio_fx /
//! hum_cpal, no flutter_rust_bridge). All `oe_*` functions are called from the
//! Flutter UI isolate; the audio thread is reached only via the rtrb queue.

pub mod drumkit;
pub mod engine;
pub mod laws;
mod output;

use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::sync::Arc;
use std::sync::atomic::Ordering;

use engine::{Cmd, MAX_CH, Status};

pub struct OeHandle {
    tx: rtrb::Producer<Cmd>,
    status: Arc<Status>,
    output: output::Output,
}

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
        let (tx, rx) = rtrb::RingBuffer::<Cmd>::new(4096);
        let output = output::Output::start(Arc::clone(&status), rx)?;
        Ok::<_, String>(OeHandle { tx, status, output })
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

fn send(h: *mut OeHandle, cmd: Cmd) -> bool {
    match unsafe { h.as_mut() } {
        Some(h) => h.tx.push(cmd).is_ok(),
        None => false,
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
#[unsafe(no_mangle)]
pub extern "C" fn oe_set_step(h: *mut OeHandle, pat: u8, ch: u8, step: u8, vel: u8) -> bool {
    send(h, Cmd::Step { pat, ch, step, vel })
}
#[unsafe(no_mangle)]
pub extern "C" fn oe_set_channel(
    h: *mut OeHandle,
    ch: u8,
    sample: u8,
    vol: f32,
    pan: f32,
    pitch: f32,
    mute: bool,
    used: bool,
) -> bool {
    send(h, Cmd::Channel { ch, sample, vol, pan, pitch, mute, used })
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
pub extern "C" fn oe_preview(h: *mut OeHandle, ch: u8) -> bool {
    send(h, Cmd::Preview { ch })
}
#[unsafe(no_mangle)]
pub extern "C" fn oe_clear_pattern(h: *mut OeHandle, pat: u8) -> bool {
    send(h, Cmd::ClearPattern(pat))
}

/// Pattern-local playback position in ticks (PPQ 96).
#[unsafe(no_mangle)]
pub extern "C" fn oe_position(h: *mut OeHandle) -> f64 {
    unsafe { h.as_ref() }.map_or(0.0, |h| f64::from_bits(h.status.pos_ticks.load(Ordering::Relaxed)))
}

/// Peak since the previous call for channel `idx` (MAX_CH = master), then resets it.
#[unsafe(no_mangle)]
pub extern "C" fn oe_take_peak(h: *mut OeHandle, idx: u32) -> f32 {
    let Some(h) = (unsafe { h.as_ref() }) else { return 0.0 };
    h.status
        .peaks
        .get(idx as usize)
        .map_or(0.0, |p| f32::from_bits(p.swap(0, Ordering::Relaxed)))
}

#[unsafe(no_mangle)]
pub extern "C" fn oe_sample_rate(h: *mut OeHandle) -> u32 {
    unsafe { h.as_ref() }.map_or(0, |h| h.status.sample_rate.load(Ordering::Relaxed))
}

#[unsafe(no_mangle)]
pub extern "C" fn oe_xruns(h: *mut OeHandle) -> u64 {
    unsafe { h.as_ref() }.map_or(0, |h| h.output.xruns.load(Ordering::Relaxed))
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
