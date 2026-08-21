# Proposal 0022 — A key/value store, and not a database

**Status:** Implemented

**Motivation:** A CrossByte client in a browser has nowhere to put anything.
`crossbyte.io.File` refuses there, deliberately, and the framework offers no
alternative — so an offline cache, a session, or a queue of messages waiting
for a reconnect has no home.

---

## What exists today

Measured, not assumed.

`crossbyte.db` is two mechanisms, and a browser has neither of them.
`AsyncDatabase`'s own documentation states the first: *"Every CrossByte
database driver is synchronous."* Its answer to that is the second — a
`TaskPool`, running the query on a worker **thread** holding a pooled
connection. A page has no threads, and no synchronous storage to drive from
one. Node has no `sys.thread` either.

`crossbyte.io.File` throws on the browser through `NoFileSystem`, and proposal
0020 already argued why that shim is right: IndexedDB and OPFS are asynchronous
and not POSIX-shaped, and *"pretending otherwise underneath a synchronous API
is how a write silently goes nowhere."* That reasoning has not changed. What is
missing is the other half — somewhere the browser's storage can honestly live.

## Three shapes were considered

**Browser entries in `crossbyte.db`.** An `IndexedDBConnection` beside the SQL
drivers. Rejected: it would share neither of that package's mechanisms — it is
not a synchronous SQL driver and cannot be driven by a thread pool — so it
would be a member of a package whose abstractions it does not implement. The
name would say "database driver" and the type would not be one.

**A `crossbyte.browser` package.** Rejected on the evidence, which is already
in. Every browser capability this framework has adopted went behind an existing
portable API:

| capability | browser API | where it lives |
|---|---|---|
| random | Web Crypto | `crossbyte.crypto.SecureRandom` |
| HTTP | `XMLHttpRequest` | `crossbyte.url.URLLoader` |
| sockets | `WebSocket` | `crossbyte.net.Socket` |
| frame loop | `requestAnimationFrame` | `crossbyte.core.Application` |

Four for four, and none wanted a namespace. That is not luck. The browser APIs
with no native counterpart — Canvas, Web Audio, Notifications, geolocation,
the clipboard — are UI and media, and CrossByte has no UI layer at all. A
`crossbyte.browser` created today would hold exactly one thing, and that thing
should not be browser-only.

The test for revisiting, so this is a decision and not a mood: *does the
capability have no native counterpart, and does it fall inside runtime,
networking, or data?* Nothing currently passes both. When something does, this
argument is void and the package is worth having.

**One abstraction over SQLite and IndexedDB.** The seductive one, and the
framing is what is wrong with it. Abstracting a relational engine and an object
store together yields their intersection: no SQL, no joins, no ad-hoc queries,
no schema. That is a crippled SQLite, sold as a feature.

## What this actually is

Key/value with byte payloads is not a reduction of a database. It is a
complete idea in its own right, and it is what the need actually is: a cache
that survives a reload, a session, a queue of outbound messages waiting for a
reconnect. Nobody wants a join in a browser tab.

So the proposal is a store, named as one, sitting beside `crossbyte.db` rather
than inside it. SQL for a server's data; key/value for a client's durability.
Two ideas, two names, neither pretending to be the other.

The honest cost of that is a second storage concept to explain. The mitigation
is that they genuinely are two concepts — not that one is a subset of the
other.

### Where it lives

`crossbyte.io`, beside `File` and `FileStream`. That package already means
getting bytes in and out of somewhere durable, and a keyed byte store is that
with a key instead of a path -- so it sits next to the type it is the
counterpart to. Someone asking how to persist something opens `io` before
inventing `storage`.

A `crossbyte.storage` package was the first instinct and is refused by this
document's own argument against `crossbyte.browser`: it would hold exactly one
type. If a second storage concept ever arrives, the package can be made then,
when it has two things to justify it.

`Store` and not `LocalStorage`, deliberately. A browser developer reading
`crossbyte.io.LocalStorage` would reasonably expect a wrapper over
`window.localStorage`, and inherit its assumptions -- five megabytes, strings,
synchronous, blocking the page. This is none of those, and it uses IndexedDB
precisely to avoid being them. `LocalStore` is the alternative if the locality
is worth signalling; the Web API's own name is not.

```haxe
package crossbyte.io;

class Store {
	public static function open(name:String):Future<Store>;

	public function get(key:String):Future<Null<ByteArray>>;
	public function put(key:String, value:ByteArray):Future<Nothing>;
	public function remove(key:String):Future<Nothing>;
	public function keys(?prefix:String):Future<Array<String>>;
	public function clear():Future<Nothing>;
	public function close():Void;
}
```

### Decisions, with reasons

**Keyed get and put, and nothing else.** The shape is deliberately the one
`localStorage` has -- and that shape is right, which is why the Web API is
still in use twenty years on. What is wrong with `localStorage` is its
implementation, not its interface: synchronous, string-only, five megabytes,
blocking the page it runs in. Keeping the interface and replacing the
implementation is the whole design.

**Bytes, not arbitrary values.** A store that serialises for you must define a
format, and a format is a compatibility promise — across targets, and across
versions of the framework. `ByteArray` is what every backend stores anyway.
String and `haxe.Serializer` helpers can sit on top as a clearly separate
layer, where the format is the caller's choice and their problem.

**String keys.** IndexedDB and SQLite both accept richer keys; String is the
intersection, and for this purpose it loses nothing. `keys(prefix)` covers the
grouping that ranges would otherwise be needed for.

**Asynchronous on every target, from the first line.** Not because browsers
force it. Because a synchronous signature is a decision about which targets can
implement the method, and this codebase learned that a week ago at some cost:
`PHPBridge.execute()` returning a response is the *only* remaining reason PHP
cannot run on Node. Everything else about that bridge ported. A store that is
synchronous on native will have exactly that conversation later.

**One async result type for the framework.** `crossbyte.rpc.RPCResponse<T>`
already is one — `then(onResult, onError)`, `completed`, `succeeded`, plus
event observation through `IEventDispatcher` — and nothing about it is
RPC-specific. It should be promoted to `crossbyte.Future<T>`, with
`RPCResponse` kept as a typedef so RPC's surface does not move. Three async
idioms in one framework (events for `URLLoader`, threads for `Task`, `then` for
RPC) is two too many, and adding a fourth for storage would be worse than
picking one.

**Results arrive on the owning runtime's tick**, as `NativeProcess` events and
`Task` completions already do. A callback that fires from an IndexedDB
transaction or a file thread, straight into application code, is a
re-entrancy bug waiting for its first user.

### Backends

| target | backend |
|---|---|
| browser | IndexedDB |
| Node, cpp, hl, neko, jvm | a single file, written atomically |

Two implementations, not three. IndexedDB rather than `localStorage`, which is
synchronous, string-only, about five megabytes, and blocks the page while it
works. IndexedDB rather than OPFS, which is file-shaped and lower-level than
this needs.

SQLite was considered for the native side and deferred, with a reason: it is
not available on Node, so choosing it would mean three backends and a Node gap
on day one. If the file store proves too slow or too fragile, SQLite is the
upgrade — behind the same API, which is the point of having one.

Atomicity is the file store's real work: write a temporary file, fsync, rename.
A store that corrupts on a power cut is worse than no store, because it is
trusted.

### Not in this

**An ordered queue.** It is a policy over a store — keys ordered by sequence —
and building it in would force a second index concept into the base. It is the
likeliest first consumer and should be written on top, in application code
first, and promoted only if three of them agree on the shape.

**Anything resembling a query.** No ranges beyond `prefix`, no indices, no
predicates. Every one of those is a step toward reimplementing the thing this
proposal exists to avoid abstracting.

**Encryption, quotas, eviction.** Real concerns, none of them storage's.

## Open questions

**Where a native store lives on disk.** `File.applicationStorageDirectory`
exists and is the obvious answer, but a server process and a desktop client
want different things, and a name collision between two CrossByte apps on one
machine is silent data mixing. Probably `open(name)` resolves under the
application storage directory with the name as a subdirectory, but that needs
stating rather than assuming.

**Whether `put` of a large value should stream.** The HTTP layer already
streams responses. A store that takes a whole `ByteArray` cannot hold a value
larger than memory, which is fine for a session and not for a cached asset.
Worth deciding before the API is public rather than after.

**Concurrency between two runtimes.** Two CrossByte runtimes in one process
opening the same store, or two processes doing so. IndexedDB has its own
answer; a file store needs one, and "last writer wins" is an answer only if it
is written down.

**Whether `keys()` is honest at scale.** Returning every key is fine for
hundreds and wrong for millions. A cursor is the general answer and a heavier
API. Possibly `keys()` stays and is documented as small-collection only, with a
cursor added when something needs it.

## Staging

1. **`Future<T>`.** Promote `RPCResponse`, alias the old name, change nothing
   else. Independently useful and independently reviewable.
2. **The API and the file backend**, on native and Node. No browser yet: this
   is the step where the shape is argued with something real behind it.
3. **IndexedDB**, in the browser, against the same tests.
4. **The helpers** — String, serialised values — once the base has users.

Step 2 is where this proposal is proved or abandoned. If the file backend is
awkward to write against the API, the API is wrong, and that is much cheaper to
learn before IndexedDB than after.

## Testing

The portable suite cannot test a store: it needs a filesystem or a page. So the
same split the framework already uses applies — the file backend on the native
and Node suites, IndexedDB in the headless browser job that now exists.

What must be covered, because each is a way for a store to lie:

- a value survives `close()` and a reopen. Trivially, and the whole point.
- a value survives a *process* restart, not just a reopen, on the native suite.
- a key that was never written reads as null, not as an empty value. `File`
  taught this one: an `exists()` answering false reads as "no such file" rather
  than "this target has no files", and a caller goes on to create it.
- `put` of a value that fails midway leaves the previous value, not a
  half-written one. Testable by writing to a path made unwritable.
- the same key, written on one target and read on another, gives the same
  bytes. The hash and the bloom filter both drifted between targets this month
  while every test passed, because every test compared a target to itself.

---

## What landed

All four stages, in one pass, because step 2 did not turn up the problem it
was staged to catch: the file backend was not awkward to write against the API,
so there was nothing to reconsider before IndexedDB.

`crossbyte.Future<T>` is the promoted `RPCResponse`, which now extends it and
keeps only `requestId` and `op`. `then` is safe to call after completion, which
the original was too -- an asynchronous result that silently never calls back
because you registered a moment late is the classic way one gets lost.

`crossbyte.io.Store` over `IStoreBackend`, with `FileStore` for every target
with a filesystem and `IndexedDBStore` for a page. The file backend keys by hex
rather than by the key itself: `a/b` is a path, `..` is the parent, `CON` is a
device on Windows, and `Token` and `token` are one file on a case-insensitive
volume and two keys everywhere. Writes go to a temporary file and are renamed,
because rename is the only atomic thing a filesystem offers.

The browser suite earned its place again. `testBinaryValuesAreNotTextAndSurviveIntact`
failed there and only there, with "expected 256 but it is 385" -- and 385 is
exactly `(256 + 1) * 3 >> 1`, `ByteArray`'s growth. The IndexedDB backend was
storing the whole backing buffer instead of the logical length, padding
included. The same mistake LZ4 was making in a page two commits earlier: handing
back the container instead of the contents. Node could not have found it, and
neither could any amount of reading.

The four open questions are still open, and none of them blocked this. Streaming
large values, cursors for `keys()`, and concurrency between two runtimes all
remain future work; the on-disk location settled as `stores/<name>` under the
application storage directory, which is what `open()` documents.
