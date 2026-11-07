# OpsDeck dependency license materials

This directory contains license and notice texts retrieved from the official
upstream repositories at the exact revisions pinned by
OpsDeck's pinned Package.resolved.

The license texts are retained from upstream. Extracted source-header attributions
identify their original files; this index is not a replacement for those terms.

| Dependency | Pinned version/revision | SPDX (upstream declaration) | Included material |
|---|---|---|---|
| BigInt | 5.7.0 / e07e00f | MIT | BigInt-LICENSE.txt |
| Citadel | 0.12.1 / ae8562f | MIT | Citadel-LICENSE.txt |
| swift-argument-parser | 1.8.2 / 6a52f32 | Apache-2.0 | swift-argument-parser-LICENSE.txt |
| swift-asn1 | 1.7.1 / a9a5efd | Apache-2.0 | swift-asn1-LICENSE.txt, swift-asn1-NOTICE.txt |
| swift-atomics | 1.3.1 / 0442cb5 | Apache-2.0 | swift-atomics-LICENSE.txt |
| swift-collections | 1.6.0 / a0cb095 | Apache-2.0 | swift-collections-LICENSE.txt |
| swift-crypto | 3.15.1 / 95ba031 | Apache-2.0 | swift-crypto-LICENSE.txt, swift-crypto-NOTICE.txt, swift-crypto-BoringSSL-OpenSSL-attributions.txt |
| swift-log | 1.14.0 / a878e7f | Apache-2.0 | swift-log-LICENSE.txt, swift-log-NOTICE.txt |
| swift-nio | 2.101.2 / cd3e115 | Apache-2.0; embedded CNIOLLHTTP MIT | swift-nio-LICENSE.txt, swift-nio-NOTICE.txt, swift-nio-CNIOLLHTTP-LICENSE.txt, plus attribution headers |
| swift-nio-ssh | 0.3.6 / a05e6bb | Apache-2.0 | swift-nio-ssh-LICENSE.txt |
| swift-system | 1.7.4 / b5544ba | Apache-2.0 | swift-system-LICENSE.txt |
| SwiftTerm | 1.14.0 / 849e8a4 | MIT | SwiftTerm-LICENSE.txt |

## Embedded and derived materials

- Swift Crypto: the package LICENSE and NOTICE are preserved. The BoringSSL
  attribution file preserves all unique leading copyright/license blocks found
  in its pinned vendored subtree, with source-file provenance. The full
  Apache-2.0 terms are included in swift-crypto-LICENSE.txt. The upstream NOTICE
  also identifies Wycheproof test vectors and SwiftNIO-derived code.
- SwiftNIO: its complete NOTICE, llhttp MIT license, uSHET cpp_magic.h license
  header, and FreeBSD SHA-1 BSD-3-Clause header are preserved. Other Apache-2.0
  derivations are identified in the upstream NOTICE; the full Apache terms
  accompany it.
- SwiftTerm: its package MIT license and the Unicode data terms are included.
  Its pinned generated width table does not record a Unicode version; the
  upstream regeneration script uses a moving UCD latest URL. No regeneration
  was performed for OpsDeck. Unicode-LICENSE.txt and Unicode-UCD-ReadMe.txt were
  retrieved from https://www.unicode.org/license.txt and
  https://www.unicode.org/Public/UCD/latest/ucd/ReadMe.txt on 2026-11-07.
  The latter describes the current upstream data, not a verified version of the
  already-generated SwiftTerm table. The pinned SwiftTerm commit fixes the
  actual code used in this build.

These notices apply to their respective upstream components. OpsDeck's MIT
license covers its own code and does not replace third-party licenses.
