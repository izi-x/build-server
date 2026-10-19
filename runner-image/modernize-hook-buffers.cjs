const fs = require('node:fs');

// The upstream hook bundles stream-buffers, tunnel and whatwg-url versions
// that still call the deprecated Buffer constructor.
const replacements = new Map([
  ['new Buffer(initialSize)', 'Buffer.alloc(initialSize)'],
  ['new Buffer(amount)', 'Buffer.alloc(amount)'],
  ['new Buffer(buffer.length + (incrementAmount * factor))', 'Buffer.alloc(buffer.length + (incrementAmount * factor))'],
  ['new Buffer(Math.min(length || size, size))', 'Buffer.alloc(Math.min(length || size, size))'],
  ['new Buffer(connectOptions.proxyAuth)', 'Buffer.from(connectOptions.proxyAuth)'],
  ['new Buffer(c)', 'Buffer.from(c)'],
  ['new Buffer(str)', 'Buffer.from(str)'],
  ['new Buffer(output)', 'Buffer.from(output)'],
  ['new Buffer(this.buffer)', 'Buffer.from(this.buffer)'],
  ['new Buffer(line, chunkEncoding)', 'Buffer.from(line, chunkEncoding)'],
  ["new Buffer(parsedSignature.params.signature, 'base64')", "Buffer.from(parsedSignature.params.signature, 'base64')"],
]);

for (const file of process.argv.slice(2)) {
  let source = fs.readFileSync(file, 'utf8');
  const constructors = source.match(/\bnew Buffer\s*\(/g);
  if (!constructors?.length) {
    throw new Error(`${file}: upstream Buffer constructors changed; review this patch`);
  }
  for (const [before, after] of replacements) source = source.replaceAll(before, after);
  if (/\bnew Buffer\s*\(/.test(source)) {
    throw new Error(`${file}: unsupported Buffer constructor; classify its argument`);
  }
  fs.writeFileSync(file, source);
}
