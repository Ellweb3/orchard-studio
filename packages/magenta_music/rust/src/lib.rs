//! Magenta (Google) MusicRNN and MusicVAE inference in pure Rust, reading the
//! TensorFlow.js checkpoints that magenta.js publishes. No ML runtime needed.

pub mod convert;
pub mod nn;
pub mod rnn;
pub mod vae;
pub mod weights;
mod ffi;

pub use convert::Note;
pub use rnn::MusicRnn;
pub use vae::MusicVae;
