# SwiftNIO HTTP/2

This project contains HTTP/2 support for Swift projects using [SwiftNIO](https://github.com/apple/swift-nio).

Please be aware that this project is currently in a **beta** state, and is subject to change. There are a number of current limitations in the project (see the **Beta** section for more details), and the API remains subject to change.

## Building

`swift-nio-http2` is a SwiftPM project and can be built and tested very simply:

```bash
$ swift build
$ swift test
```

Note, however, that you need nghttp2 installed and available to the linker. On macOS or other Darwin platforms, the easiest way to get nghttp2 is via Homebrew:

```bash
$ brew install nghttp2
```

For more recent Linux systems, nghttp2 may be available from your package manager. Otherwise, you may need to [build it from source](https://nghttp2.org/documentation/package_README.html#requirements).

## Beta

This project is currently in a beta state. The intention is to allow the wider SwiftNIO community to get early access in order to provide feedback and help guide the development of the HTTP/2 support.

The current version of these bindings has a dependency on nghttp2. This dependency is intended to be temporary: it was used to get the functionality up-and-running, but as time goes on nghttp2 should be scaled back, and eventually removed once all the functionality it provides has been replaced with Swift code.

Due to this early state, there are a number of limitations in the current bindings. Please be aware of them. The known limitations are listed below:

1. Promises on control frame writes do not work and will be leaked. Promises on DATA frame writes work just fine and will be fulfilled correctly.
2. No support for manual flow control window management, only automatic.
3. No support for sending priority frames, and received priority frames will not be transmitted on the channel pipeline.
4. No support for push promise frames, either sending or receiving.
5. No low-level support for managing DATA frame boundaries: DATA frames may be interleaved and merged/split as necessary by nghttp2.

If you choose to use this project, please submit feedback and bug reports when you encounter problems or limitations.

## Developing SwiftNIO HTTP/2

For the most part, SwiftNIO development is as straightforward as any other SwiftPM project. With that said, we do have a few processes that are worth understanding before you contribute. For details, please see `CONTRIBUTING.md` in this repository.

