import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const repoRoot = fileURLToPath(new URL('../../', import.meta.url));
export const guidePaths = Object.freeze({
  source: path.join(repoRoot, 'docs/design/LeanTTY-User-Guide.html'),
  packaged: path.join(repoRoot, 'entry/src/main/resources/rawfile/LeanTTY-User-Guide.html')
});
export const guideRoute = '/LeanTTY-User-Guide.html';
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

// Serve one immutable file snapshot, never a directory or a request-derived path.
// The editor may preview source before copying it to the packaged resource.
export async function startGuidePreview({ port = 0, asset = 'source' } = {}) {
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('Invalid preview port');
  if (!Object.hasOwn(guidePaths, asset)) throw new Error('Expected source or packaged guide');
  const html = readFileSync(guidePaths[asset]);
  const server = createServer((request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Referrer-Policy', 'no-referrer');
    const authority = `127.0.0.1:${server.address().port}`;
    if (request.headers.host !== authority) {
      response.writeHead(403).end();
    } else if (!['GET', 'HEAD'].includes(request.method)) {
      response.writeHead(405, { Allow: 'GET, HEAD' }).end();
    } else if (request.url === '/') {
      response.writeHead(302, { Location: guideRoute }).end();
    } else if (request.url !== guideRoute) {
      response.writeHead(404).end();
    } else {
      response.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Content-Length': html.length
      });
      response.end(request.method === 'HEAD' ? undefined : html);
    }
  });
  server.requestTimeout = 5000;
  server.headersTimeout = 5000;
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
  return {
    asset,
    sha256: sha256(html),
    byteLength: html.length,
    address: server.address(),
    url: `http://127.0.0.1:${server.address().port}${guideRoute}`,
    close: () => new Promise((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
      server.closeAllConnections();
    })
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  if (args.includes('--help')) {
    console.log('Usage: node preview-user-guide.mjs [port=0] [source|packaged=source]\n' +
      'Loopback only; serves a snapshot of one guide. Restart after editing. Ctrl+C stops it.');
  } else {
    try {
      if (args.length > 2) throw new Error('Unexpected preview arguments; use --help');
      const preview = await startGuidePreview({ port: Number(args[0] ?? 0), asset: args[1] ?? 'source' });
      console.log(JSON.stringify({ url: preview.url, asset: preview.asset, sha256: preview.sha256 }));
      let stopping = false;
      const stop = async () => {
        if (stopping) return;
        stopping = true;
        await preview.close();
      };
      process.once('SIGINT', stop);
      process.once('SIGTERM', stop);
    } catch (error) {
      console.error(error.message);
      process.exitCode = 1;
    }
  }
}
