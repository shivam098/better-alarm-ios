// Original synthesized tones. No recordings or third-party assets are used.
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const rate = 22050;
const seconds = 4;
const tones = {
  radar: [660, 880, 4], ascend: [440, 880, 1], sunrise: [330, 660, 1],
  chimes: [880, 1320, 2], klaxon: [440, 554, 6], siren: [550, 1100, 2],
  insistent: [784, 1047, 8],
};
const directory = new URL('../Alarmy/Resources/Sounds/', import.meta.url);
mkdirSync(directory, { recursive: true });

for (const [name, [low, high, pulses]] of Object.entries(tones)) {
  const dataLength = rate * seconds * 2;
  const wav = Buffer.alloc(44 + dataLength);
  wav.write('RIFF', 0);
  wav.writeUInt32LE(36 + dataLength, 4);
  wav.write('WAVEfmt ', 8);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20);
  wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(rate, 24);
  wav.writeUInt32LE(rate * 2, 28);
  wav.writeUInt16LE(2, 32);
  wav.writeUInt16LE(16, 34);
  wav.write('data', 36);
  wav.writeUInt32LE(dataLength, 40);
  let phase = 0;
  for (let index = 0; index < rate * seconds; index++) {
    const time = index / rate;
    const cycle = time * pulses % 1;
    const sweep = name === 'siren'
      ? 0.5 - 0.5 * Math.cos(2 * Math.PI * time) : Math.floor(time * 2) % 2;
    phase += 2 * Math.PI * (low + (high - low) * sweep) / rate;
    const envelope = Math.min(1, cycle / 0.025, (1 - cycle) / 0.08)
      * Math.min(1, time / 0.02, (seconds - time) / 0.02);
    wav.writeInt16LE(Math.round((Math.sin(phase) + 0.2 * Math.sin(phase * 2)) * envelope * 18000), 44 + index * 2);
  }
  writeFileSync(new URL(`${name}.wav`, directory), wav);
}
console.log(`Generated ${Object.keys(tones).length} original PCM tones in ${fileURLToPath(directory)}`);
