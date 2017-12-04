# NIO-HTTP2

**HTTP/2 for NIO**

This project contains bindings to the awesome [nghttp2](https://nghttp2.org/documentation/package_README.html) library that make it possible to write clients and servers in SwiftNIO that use HTTP/2.

These bindings exist out-of-tree because not all systems that SwiftNIO supports necessarily have installations of nghttp2. For this reason, we want to ensure that users have access to nghttp2 before they attempt to build this code.

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
