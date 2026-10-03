// What a browser's fetch() of a same-origin JSON API sends besides the
// request line and Host: fourteen fields, about 700 bytes. Chrome's set, with
// a session cookie, so the parser, the header map and HPACK see a real block.
'use strict';
const fields = [
  ['Connection', 'keep-alive'],
  ['sec-ch-ua', '"Chromium";v="128", "Not;A=Brand";v="24", "Google Chrome";v="128"'],
  ['sec-ch-ua-mobile', '?0'],
  ['sec-ch-ua-platform', '"Windows"'],
  ['User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'],
  ['Accept', 'application/json, text/plain, */*'],
  ['Sec-Fetch-Site', 'same-origin'],
  ['Sec-Fetch-Mode', 'cors'],
  ['Sec-Fetch-Dest', 'empty'],
  ['Referer', 'http://127.0.0.1/app/dashboard'],
  ['Accept-Encoding', 'gzip, deflate, br, zstd'],
  ['Accept-Language', 'en-US,en;q=0.9'],
  ['Cookie', 'session=4f2a9c1e7b3d48e6a0c5f9e2d1b7a3c8; theme=dark; _ga=GA1.1.123456789.1700000000'],
  ['Priority', 'u=1, i'],
];

// HTTP/1.1 field lines, each ending CRLF.
exports.h1 = fields.map(([k, v]) => k + ': ' + v + '\r\n').join('');

// HTTP/2 fields: lowercase names, no Connection (RFC 9113 8.2.2).
exports.h2 = {};
for (const [k, v] of fields) {
  if (k.toLowerCase() === 'connection') continue;
  exports.h2[k.toLowerCase()] = v;
}
