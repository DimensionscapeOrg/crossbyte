# Simple Application

`simple-application` is the smallest primordial CrossByte app sample.

It demonstrates:

- extending `Application`
- observing `init` and `exit`
- listening for `TickEvent`
- shutting the primordial runtime down cleanly

Useful commands from `samples/simple-application`:

```sh
aedifex task sample-simple-application-check ../..
aedifex task sample-simple-application-cpp ../..
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
..\..\export\simple-application\SimpleApplicationSample.exe
```
