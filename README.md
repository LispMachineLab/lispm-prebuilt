# lispm-prebuilt

The native code of [LispM](https://lispm.ai)'s packages, downloaded and checked: a module Emacs
loads, as [lispm-gl](https://github.com/LispMachineLab/lispm-gl)'s and
[lispm-remote](https://github.com/LispMachineLab/lispm-remote)'s, or a program it runs, as
[lispm-doom](https://github.com/LispMachineLab/lispm-doom)'s engine.

Nobody has to build it. The one the package's workflow built for this computer from the sources
there are is downloaded, and kept only when its SHA-256 is the one pinned beside the package's
Lisp. Those checksums come with the Lisp, from the package's signed history, not from the
release, so a file changed on the release after it was pinned is refused. Building is asked
for, never done because a compiler happens to be there.

A package says what it ships, once:

```elisp
(lispm-prebuilt-define 'lispm-gl-module
  :title "lispm-gl's module"
  :root (expand-file-name "native" ...)          ; its sources are here
  :sources '("Cargo.toml" "Cargo.lock" ("src" "\\.rs\\'"))
  :targets '("aarch64-apple-darwin" "x86_64-apple-darwin" "x86_64-unknown-linux-gnu")
  :release "gl-module-%v"                        ; a release under :url
  :asset "lispm-gl-module-%t%e.gz"               ; what it publishes per target
  :file "lispm-gl-module-%t%e"                   ; kept, unpacked
  :url 'lispm-gl-module-prebuilt-url             ; variables of its own
  :source 'lispm-gl-module-source                ; download or build
  :sums (expand-file-name "lispm-gl-module-sums.eld" ...)
  :build '("cargo" "build" "--release" "--target" "%t")
  :built "target/%t/release/liblispm_gl%e")
```

`%t` is the target, `%e` the suffix of a library there (`.dylib` or `.so`), `%v` the version of
the sources: the first 16 digits of the SHA-256 of what `sha256sum` writes for them in `:root`.
An asset ending in `.tar.gz` unpacks into a directory holding the `:files` it names; one ending
in `.gz` is one file. Downloads are kept by version, those of other versions removed.

Then, the same for each:

| `lispm-prebuilt-get NAME CALLBACK` | downloaded and checked in the background, then a callback: Emacs does not wait |
| `lispm-prebuilt-prefetch NAME`     | the same, so that it is there once needed                                       |
| `lispm-prebuilt-ensure NAME`       | Emacs waiting, for code that cannot wait                                        |
| `lispm-prebuilt-load NAME FEATURE` | a module, loaded                                                                |
| `lispm-prebuilt-batch-pin NAME`    | the pins of a published release, written, for `make pin`                        |

In the background, downloads go through `lispm-prebuilt-fetch-function`: curl, as a process of
Emacs's own. [lispm-kernel](https://github.com/LispMachineLab/lispm-kernel) advises it to have
its kernel fetch instead, on a thread of its own, through the proxy url.el would use.
Unpacking runs through [lispm-agent](https://github.com/LispMachineLab/lispm-agent)'s
`lispm-exec` where it is there. lispm-prebuilt requires neither.

## Install

LispM's App Store installs it with the packages that need it. Elsewhere:

```elisp
(package-vc-install '(lispm-prebuilt :url "https://github.com/LispMachineLab/lispm-prebuilt"))
```

```sh
make test       # a package of the tests' own, its releases read from file: URLs
make compile    # byte-compile, warnings failing it
```

## License

GNU Affero General Public License, version 3 or later: see [LICENSE](LICENSE).
