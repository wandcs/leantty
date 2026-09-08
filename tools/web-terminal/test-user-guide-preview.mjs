import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { request } from 'node:http';
import { startGuidePreview, guidePaths, guideRoute } from './preview-user-guide.mjs';

function send(preview, pathname, { method = 'GET', host } = {}) {
  return new Promise((resolve, reject) => {
    const req = request({ hostname: '127.0.0.1', port: preview.address.port, path: pathname,
      method, headers: host ? { Host: host } : {}, agent: false }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers,
        body: Buffer.concat(chunks) }));
    });
    req.on('error', reject);
    req.end();
  });
}

let checks = 0;
for (const asset of ['source', 'packaged']) {
  const preview = await startGuidePreview({ asset });
  try {
    assert.equal(preview.address.address, '127.0.0.1');
    const get = await send(preview, guideRoute);
    assert.equal(get.status, 200);
    assert.deepEqual(get.body, readFileSync(guidePaths[asset]));
    assert.equal(get.headers['content-type'], 'text/html; charset=utf-8');
    assert.equal(get.headers['cache-control'], 'no-store');
    assert.equal(get.headers['access-control-allow-origin'], undefined);
    checks++;
    const head = await send(preview, guideRoute, { method: 'HEAD' });
    assert.equal(head.status, 200);
    assert.equal(head.body.length, 0);
    assert.equal(Number(head.headers['content-length']), get.body.length);
    checks++;
    const root = await send(preview, '/');
    assert.equal(root.status, 302);
    assert.equal(root.headers.location, guideRoute);
    checks++;
    // Raw HTTP paths avoid the client's URL normalizer hiding traversal probes.
    for (const pathname of ['/AGENTS.md', '/.git/config', '/signing/', '/../AGENTS.md',
      '/%2e%2e/AGENTS.md', '/%252e%252e/AGENTS.md', '/..\\AGENTS.md', '/%00',
      `${guideRoute}?file=AGENTS.md`, `http://example.invalid${guideRoute}`]) {
      assert.equal((await send(preview, pathname)).status, 404, pathname);
      checks++;
    }
    assert.equal((await send(preview, guideRoute, { method: 'POST' })).status, 405);
    assert.equal((await send(preview, guideRoute, { host: 'example.invalid' })).status, 403);
    checks += 2;
  } finally { await preview.close(); }
  await assert.rejects(send(preview, guideRoute), { code: 'ECONNREFUSED' });
  checks++;
}
await assert.rejects(startGuidePreview({ asset: '../AGENTS.md' }), /source or packaged/);
await assert.rejects(startGuidePreview({ port: -1 }), /Invalid preview port/);
checks += 2;
console.log(`User guide preview tests passed (${checks} cases; both listeners closed).`);
