# SwiftNIO HTTP/2

This project contains HTTP/2 support for Swift projects using [SwiftNIO](https://github.com/apple/swift-nio). To get started, check the [API docs](https://apple.github.io/swift-nio-http2/docs/current/NIOHTTP2/index.html).

## Building

`swift-nio-http2` is a SwiftPM project and can be built and tested very simply:

```bash
$ swift build
$ swift test
```

## Versions

Just like the rest of the SwiftNIO family, swift-nio-http2 follows [SemVer 2.0.0](https://semver.org/#semantic-versioning-200) with a separate document
declaring [SwiftNIO's Public API](https://github.com/apple/swift-nio/blob/main/docs/public-api.md).

### `swift-nio-http2` 1.x

`swift-nio-http2` versions 1.x are a pure-Swift implementation of the HTTP/2 protocol for SwiftNIO. It's part of the SwiftNIO 2 family of repositories and does not have any dependencies besides [`swift-nio`](https://github.com/apple/swift-nio) and Swift 5. As the latest version, it lives on the [`main`](https://github.com/apple/swift-nio-http2) branch.

To depend on `swift-nio-http2`, put the following in the `dependencies` of your `Package.swift`:

    .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.5.0"),

### `swift-nio-http2` 0.x

The legacy `swift-nio-http` 0.x is part of the SwiftNIO 1 family of repositories and works on Swift 4.1 and newer but requires [nghttp2](https://nghttp2.org) to be installed on your system. The source code can be found on the [`nghttp2-support-branch`](https://github.com/apple/swift-nio-http2/tree/nghttp2-support-branch).


## Developing SwiftNIO HTTP/2

For the most part, SwiftNIO development is as straightforward as any other SwiftPM project. With that said, we do have a few processes that are worth understanding before you contribute. For details, please see [`CONTRIBUTING.md`](/CONTRIBUTING.md) in this repository.

