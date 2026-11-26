//! Loads TensorFlow.js weight checkpoints (weights_manifest.json + binary
//! shards), the format magenta.js models are published in.

use std::collections::HashMap;
use std::path::Path;

use serde_json::Value;

#[derive(Debug, Clone)]
pub struct Tensor {
    pub shape: Vec<usize>,
    pub data: Vec<f32>,
}

impl Tensor {
    pub fn rows(&self) -> usize {
        self.shape[0]
    }
    pub fn cols(&self) -> usize {
        self.shape.iter().skip(1).product::<usize>().max(1)
    }
}

pub type Vars = HashMap<String, Tensor>;

pub fn load_dir(dir: &Path) -> Result<Vars, String> {
    let manifest_path = dir.join("weights_manifest.json");
    let text = std::fs::read_to_string(&manifest_path).map_err(|e| format!("{}: {e}", manifest_path.display()))?;
    let manifest: Value = serde_json::from_str(&text).map_err(|e| format!("manifest: {e}"))?;
    let groups = manifest.as_array().ok_or("manifest is not an array")?;
    let mut vars = Vars::new();
    for g in groups {
        // the shards of a group are one contiguous buffer
        let mut buf = Vec::new();
        for p in g["paths"].as_array().ok_or("group without paths")? {
            let p = p.as_str().ok_or("bad path")?;
            let bytes = std::fs::read(dir.join(p)).map_err(|e| format!("{p}: {e}"))?;
            buf.extend_from_slice(&bytes);
        }
        let mut off = 0usize;
        for w in g["weights"].as_array().ok_or("group without weights")? {
            let name = w["name"].as_str().ok_or("weight without name")?.to_string();
            let shape: Vec<usize> = w["shape"]
                .as_array()
                .ok_or("weight without shape")?
                .iter()
                .map(|d| d.as_u64().unwrap_or(0) as usize)
                .collect();
            let n: usize = shape.iter().product::<usize>().max(1);
            let dtype = w["dtype"].as_str().unwrap_or("float32");
            if dtype != "float32" || !w["quantization"].is_null() {
                return Err(format!("{name}: unsupported dtype {dtype} / quantization"));
            }
            let end = off + n * 4;
            if end > buf.len() {
                return Err(format!("{name}: shard data too short"));
            }
            let data = buf[off..end].chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect();
            off = end;
            vars.insert(name, Tensor { shape, data });
        }
    }
    Ok(vars)
}

pub fn take(vars: &mut Vars, name: &str) -> Result<Tensor, String> {
    vars.remove(name).ok_or_else(|| format!("missing variable {name}"))
}

pub fn read_config(dir: &Path) -> Result<Value, String> {
    let p = dir.join("config.json");
    let text = std::fs::read_to_string(&p).map_err(|e| format!("{}: {e}", p.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("config: {e}"))
}
