# Arena

`arena` is an authoritative game server and sixteen bots that play in it, in
one process. It exists to show the game-server primitives working together
-- none of them is a game-server feature on its own -- and it checks itself:
every snapshot a bot decodes is compared against a checksum of what the
server built, and the run exits 1 on any difference.

It demonstrates:

- `FixedStep` running the simulation at 20 Hz whatever rate the loop runs at
- a `SpatialGrid` holding every entity's position, where a move costs a
  comparison unless the entity crosses into another cell, and
  `queryCircle` for each client's view
- an `InterestSet` per client reporting what entered and left its view,
  including an entity respawned under an id that was already in view
  (`forget`, and a generation in the snapshot)
- a view table of fixed slots, handed out with `BitSet.nextClearBit` as
  entities enter and freed as they leave, so a snapshot keeps its layout
  from one step to the next
- a `SequenceRing` per client of the snapshots sent, and `ByteDelta`
  encoding each one against the last snapshot that client acknowledged --
  or whole, when that has aged out
- logins through a `ConcurrencyLimiter`, four at a time with the rest queued,
  and connections through `ServerSocket.admit`
- `FrameCodec` for message boundaries over TCP

The snapshot scheme is the same on a transport that loses messages: a
client decodes against whatever baseline the server names, and the server
only ever names one the client has acknowledged.

A run prints what happened, for example:

```text
arena: 8s, 16 bots, 300 npcs, 159 steps at 20 Hz
  logins: 16 of 16, 4 at a time; 0 refused; 1 turned away at admission
  interest: 820 entered, 457 left, 7 respawned under an old id, 0 views trimmed to 64
  snapshots: 2344 sent (16 whole), 277060 bytes where whole ones would be 1200128 (23.1%)
  bots: 2344 decoded (fewest 139), 0 checksum mismatches, 0 missing baselines, 16 of 16 saw themselves
OK: every snapshot every bot decoded matched what the server built.
```

Useful commands from `samples/arena`:

```sh
aedifex task sample-arena-check <project-root>
aedifex task sample-arena-cpp <project-root>
```

From `samples/arena`, `<project-root>` is `../..`.

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
..\..\export\arena\ArenaSample.exe
```
