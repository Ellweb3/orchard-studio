//! cpal output stream driving the Engine (AAudio on Android, CoreAudio on
//! Apple). Pattern from hum_cpal: the engine lives inside the callback and is
//! fed by an rtrb queue.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SampleFormat, SizedSample, StreamConfig};

use crate::engine::{Cmd, Engine, Status};

pub struct Output {
    _stream: cpal::Stream,
    pub xruns: Arc<AtomicU64>,
}

const SCRATCH_FRAMES: usize = 4096;

fn build<T>(
    device: &cpal::Device,
    config: StreamConfig,
    mut engine: Engine,
    mut rx: rtrb::Consumer<Cmd>,
    xruns: Arc<AtomicU64>,
) -> Result<cpal::Stream, String>
where
    T: SizedSample + FromSample<f32>,
{
    let out_ch = config.channels as usize;
    let mut scratch = vec![0f32; SCRATCH_FRAMES * 2];
    let err_xruns = Arc::clone(&xruns);
    device
        .build_output_stream(
            config,
            move |data: &mut [T], _| {
                while let Ok(cmd) = rx.pop() {
                    engine.handle(cmd);
                }
                let frames = data.len() / out_ch;
                let mut done = 0;
                while done < frames {
                    let n = (frames - done).min(SCRATCH_FRAMES);
                    let buf = &mut scratch[..n * 2];
                    engine.process(buf);
                    for i in 0..n {
                        let (l, r) = (buf[i * 2], buf[i * 2 + 1]);
                        let frame = &mut data[(done + i) * out_ch..(done + i + 1) * out_ch];
                        match out_ch {
                            1 => frame[0] = T::from_sample((l + r) * 0.5),
                            _ => {
                                frame[0] = T::from_sample(l);
                                frame[1] = T::from_sample(r);
                                for x in frame.iter_mut().skip(2) {
                                    *x = T::from_sample(0.0f32);
                                }
                            }
                        }
                    }
                    done += n;
                }
            },
            move |err| {
                if matches!(err.kind(), cpal::ErrorKind::Xrun) {
                    err_xruns.fetch_add(1, Ordering::Relaxed);
                }
            },
            None,
        )
        .map_err(|e| format!("Failed to build output stream: {e}"))
}

impl Output {
    pub fn start(status: Arc<Status>, rx: rtrb::Consumer<Cmd>) -> Result<Self, String> {
        let host = cpal::default_host();
        let device = host
            .default_output_device()
            .ok_or_else(|| String::from("No default audio output device"))?;
        let sup = device
            .default_output_config()
            .map_err(|e| format!("No default output config: {e}"))?;
        let format = sup.sample_format();
        let config: StreamConfig = sup.config();
        let engine = Engine::new(config.sample_rate as f64, status);
        let xruns = Arc::new(AtomicU64::new(0));
        let x = Arc::clone(&xruns);
        let stream = match format {
            SampleFormat::F32 => build::<f32>(&device, config, engine, rx, x)?,
            SampleFormat::I16 => build::<i16>(&device, config, engine, rx, x)?,
            SampleFormat::I32 => build::<i32>(&device, config, engine, rx, x)?,
            other => return Err(format!("Unsupported sample format {other:?}")),
        };
        stream.play().map_err(|e| format!("Failed to start output stream: {e}"))?;
        Ok(Self { _stream: stream, xruns })
    }
}
