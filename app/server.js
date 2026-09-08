const http = require('http');

const PORT = process.env.PORT || 3000;
const ENV_NAME = process.env.ENV_NAME || 'local';

const server = http.createServer((req, res) => {
  const requestId = req.headers['x-request-id'] || '';

  if (req.url === '/healthz') {
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'X-Request-ID': requestId,
    });
    res.end(JSON.stringify({ status: 'ok', service: 'app', env: ENV_NAME }));
    return;
  }

  if (req.url === '/') {
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'X-Request-ID': requestId,
    });
    res.end(JSON.stringify({ status: 'ok', service: 'app', env: ENV_NAME, path: req.url }));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ status: 'error', message: 'not found' }));
});

server.listen(PORT, () => {
  console.log(`app listening on port ${PORT}, env=${ENV_NAME}`);
});
