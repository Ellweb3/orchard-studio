//! Flat C ABI for Dart FFI (`mm_*`). Models are plain heap objects: load
//! them on a background isolate, use each from one thread at a time.

use std::cell::RefCell;
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::ptr;

use crate::convert::Note;
use crate::rnn::{Encoding, MusicRnn};
use crate::vae::{MusicVae, VaeEncoding};

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

fn set_error(e: impl Into<String>) {
    LAST_ERROR.with(|l| *l.borrow_mut() = CString::new(e.into()).ok());
}

/// Last error on this thread, or null.
#[unsafe(no_mangle)]
pub extern "C" fn mm_last_error() -> *const c_char {
    LAST_ERROR.with(|l| l.borrow().as_ref().map_or(ptr::null(), |s| s.as_ptr()))
}

unsafe fn path<'a>(p: *const c_char) -> Option<&'a Path> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok().map(Path::new)
}

unsafe fn notes<'a>(p: *const Note, n: u32) -> &'a [Note] {
    if p.is_null() || n == 0 { &[] } else { unsafe { std::slice::from_raw_parts(p, n as usize) } }
}

/// Copies `src` into `out` (capacity `cap`) and returns the full count
/// (may exceed `cap`: call again with a bigger buffer), or -1 on error.
unsafe fn emit(r: Result<Vec<Note>, String>, out: *mut Note, cap: u32) -> i32 {
    match r {
        Ok(v) => {
            if !out.is_null() {
                let n = v.len().min(cap as usize);
                unsafe { ptr::copy_nonoverlapping(v.as_ptr(), out, n) };
            }
            v.len() as i32
        }
        Err(e) => {
            set_error(e);
            -1
        }
    }
}

fn guard<T>(f: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|_| Err("panic in magenta_music".into()))
}

// ------------------------------------------------------------------ MusicRNN

/// Loads a MusicRNN checkpoint directory (config.json + weights). Null on error.
///
/// # Safety
/// `dir` must be a NUL-terminated UTF-8 path.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mm_rnn_load(dir: *const c_char) -> *mut MusicRnn {
    let Some(dir) = (unsafe { path(dir) }) else {
        set_error("bad path");
        return ptr::null_mut();
    };
    match guard(|| MusicRnn::load(dir)) {
        Ok(m) => Box::into_raw(Box::new(m)),
        Err(e) => {
            set_error(e);
            ptr::null_mut()
        }
    }
}

/// # Safety
/// `m` must come from `mm_rnn_load`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mm_rnn_free(m: *mut MusicRnn) {
    if !m.is_null() {
        drop(unsafe { Box::from_raw(m) });
    }
}

/// 0 = drums, 1 = melody, 2 = melody over chords (ImprovRNN).
///
/// # Safety
/// `m` must be a live model.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mm_rnn_kind(m: *const MusicRnn) -> u8 {
    let m = unsafe { &*m };
    match m.encoding {
        Encoding::Drums => 0,
        Encoding::Melody { .. } if m.needs_chords() => 2,
        Encoding::Melody { .. } => 1,
    }
}

/// Continues `primer` (notes within [0, primer_steps)) by `steps` steps;
/// output notes start at `primer_steps`. `chords`: comma-separated symbols
/// (ImprovRNN) or null. `temperature` <= 0 = argmax. Returns the note count.
///
/// # Safety
/// Pointers valid for their counts; `chords` null or NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mm_rnn_continue(
    m: *mut MusicRnn,
    primer: *const Note,
    primer_len: u32,
    primer_steps: u32,
    steps: u32,
    temperature: f32,
    seed: u64,
    chords: *const c_char,
    out: *mut Note,
    out_cap: u32,
) -> i32 {
    let m = unsafe { &mut *m };
    let primer = unsafe { notes(primer, primer_len) };
    let chords: Option<Vec<String>> = if chords.is_null() {
        None
    } else {
        unsafe { CStr::from_ptr(chords) }
            .to_str()
            .ok()
            .map(|s| s.split(',').map(|c| c.trim().to_string()).filter(|c| !c.is_empty()).collect())
    };
    let r = guard(|| match m.encoding {
        Encoding::Drums => m.continue_drums(primer, primer_steps as usize, steps as usize, temperature, seed),
        Encoding::Melody { .. } => {
            m.continue_melody(primer, primer_steps as usize, steps as usize, temperature, chords.as_deref(), seed)
        }
    });
    unsafe { emit(r, out, out_cap) }
}

// ------------------------------------------------------------------ MusicVAE

/// # Safety
/// `dir` must be a NUL-terminated UTF-8 path.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mm_vae_load(dir: *const c_char) -> *mut MusicVae {
    let Some(dir) = (unsafe { path(dir) }) else {
        set_error("bad path");
        return ptr::null_mut();
    };
    match guard(|| MusicVae::load(dir)) {
        Ok(m) => Box::into_raw(Box::new(m)),
        Err(e) => {
            set_error(e);
            ptr::null_mut()
        }
    }
}

/// # Safety
/// `m` must come from `mm_vae_load`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mm_vae_free(m: *mut MusicVae) {
    if !m.is_null() {
        drop(unsafe { Box::from_raw(m) });
    }
}

/// 0 = drums, 1 = melody.
///
/// # Safety
/// `m` must be a live model.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mm_vae_kind(m: *const MusicVae) -> u8 {
    match unsafe { &*m }.encoding {
        VaeEncoding::Drums => 0,
        VaeEncoding::Melody { .. } => 1,
    }
}

/// Sequence length in steps (32 for the 2-bar models).
///
/// # Safety
/// `m` must be a live model.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mm_vae_steps(m: *const MusicVae) -> u32 {
    unsafe { &*m }.steps as u32
}

/// A new sequence from the prior.
///
/// # Safety
/// `m` live; `out` valid for `out_cap` notes (or null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mm_vae_sample(m: *mut MusicVae, temperature: f32, seed: u64, out: *mut Note, out_cap: u32) -> i32 {
    let m = unsafe { &mut *m };
    let r = guard(|| Ok(m.sample(temperature, seed)));
    unsafe { emit(r, out, out_cap) }
}

/// The sequence `alpha` (0..1) of the way from `a` to `b`.
///
/// # Safety
/// Pointers valid for their counts.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mm_vae_interpolate(
    m: *mut MusicVae,
    a: *const Note,
    a_len: u32,
    b: *const Note,
    b_len: u32,
    alpha: f32,
    temperature: f32,
    seed: u64,
    out: *mut Note,
    out_cap: u32,
) -> i32 {
    let m = unsafe { &mut *m };
    let (a, b) = unsafe { (notes(a, a_len), notes(b, b_len)) };
    let r = guard(|| Ok(m.interpolate(a, b, alpha, temperature, seed)));
    unsafe { emit(r, out, out_cap) }
}

/// A variation of `src`: latent noise of `amount` (0.1 subtle .. 1 wild).
///
/// # Safety
/// Pointers valid for their counts.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mm_vae_similar(
    m: *mut MusicVae,
    src: *const Note,
    src_len: u32,
    amount: f32,
    temperature: f32,
    seed: u64,
    out: *mut Note,
    out_cap: u32,
) -> i32 {
    let m = unsafe { &mut *m };
    let src = unsafe { notes(src, src_len) };
    let r = guard(|| Ok(m.similar(src, amount, temperature, seed)));
    unsafe { emit(r, out, out_cap) }
}

#[cfg(test)]
mod tests {
    #[test]
    fn note_layout_is_12_bytes() {
        assert_eq!(std::mem::size_of::<super::Note>(), 12);
    }
}
