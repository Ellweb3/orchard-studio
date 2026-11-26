import { BUILTIN_SAMPLES } from '../../src/audio/drumkit.ts';
import { writeFileSync } from 'node:fs';
for (const s of BUILTIN_SAMPLES) {
  const m = s.make(); const chs = Array.isArray(m) ? m : [m];
  const buf = Buffer.alloc(4 + chs.length * chs[0].length * 4);
  buf.writeUInt32LE(chs.length, 0);
  let o = 4; for (const c of chs) { Buffer.from(c.buffer, c.byteOffset, c.byteLength).copy(buf, o); o += c.byteLength; }
  writeFileSync(`${new URL('../rust/tests/golden/', import.meta.url).pathname}${s.key}.f32`, buf);
}
