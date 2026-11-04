# Third-party notices and licence texts

The kit's own licence is [`../LICENSE`](../LICENSE). This folder holds the
notices for the third-party models and data that the Lucairn images of kit 2.0
redistribute, above all the two sanitizer-core images
(`dsa-sanitizer-core`, `dsa-sanitizer-core-sidecar`):

- [`NOTICE`](NOTICE) — a byte-for-byte copy of the product repository's
  `NOTICE` at the commit the 2.0.0 images are built from (`35dd235d`). It names
  every model and data file the two sanitizer-core images redistribute, the
  licence of each as read from its source, and the attributions those licences
  ask for.
- The licence texts that `NOTICE` refers to, listed below.

Kit 2.0.0 ships these files in the kit (the release tarball, which is
`git archive` of the release commit, and every customer bundle from
`bin/lucairn bundle create`, under `licenses/`). The images themselves carry
`NOTICE` from kit 2.0.1 on (the next product commit). Inside the sidecar image
each Python package keeps its own licence files in its `dist-info` directory
(for example torch's 85 third-party licence files under
`/opt/venv/lib/python3.12/site-packages/torch-2.14.1+cpu.dist-info/licenses/`,
and the spaCy models' `LICENSE` and `LICENSES_SOURCES` under
`site-packages/en_core_web_md/` and `site-packages/de_core_news_lg/`).

`tests/test_third_party_notices.sh` checks that every file here is listed in
the table with this sha256, that `NOTICE` is the recorded copy, and that the
release tarball and customer bundles carry the folder.

## Files

Read 2026-11-04. The sha256 is of the file as it is in this folder.

| File | For (NOTICE entry) | Source | sha256 |
|---|---|---|---|
| `NOTICE` | all entries | product repository `NOTICE` at commit `35dd235d52d55ae597ee062c3e56ab9de5185c12` | `3b06c0920ffbd9e64b90290bfeec86c2d36a1ef0e5e3a6514abc6ef812434556` |
| `Apache-2.0.txt` | GLiNER `urchade/gliner_multi-v2.1` (Apache-2.0); langdetect 1.0.9; torch (part of its licence expression) | https://www.apache.org/licenses/LICENSE-2.0.txt | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |
| `MIT-DeBERTa.txt` | `microsoft/mdeberta-v3-base` tokenizer and config (MIT) | https://raw.githubusercontent.com/microsoft/DeBERTa/master/LICENSE (the licence the NOTICE entry cites) | `c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383` |
| `MIT-spaCy-models-3.8.0.txt` | spaCy models `en_core_web_md` 3.8.0 and `de_core_news_lg` 3.8.0 (MIT; both wheels carry this same `LICENSE`); `german-common-words.txt` | `LICENSE` inside `en_core_web_md-3.8.0-py3-none-any.whl` and `de_core_news_lg-3.8.0-py3-none-any.whl` (https://github.com/explosion/spacy-models/releases) | `3933c176979b68bc6d0bcc902c7d6c130f1d127f476f17ba5cdba8d99cfd0012` |
| `spaCy-model-sources-en_core_web_md-3.8.0.txt` | `en_core_web_md` 3.8.0 training sources, incl. the WordNet 3.0 licence notice that must appear on all copies | `LICENSES_SOURCES` inside `en_core_web_md-3.8.0-py3-none-any.whl` | `ea21333cecd2593c1fea842e9362bedf7b556abfb97cd08ce0650f2228b2eb58` |
| `spaCy-model-sources-de_core_news_lg-3.8.0.txt` | `de_core_news_lg` 3.8.0 training sources (TIGER, Tiger2Dep, WikiNER, vectors) | `LICENSES_SOURCES` inside `de_core_news_lg-3.8.0-py3-none-any.whl` | `5c1460fbf2193f7fbd80bdea331870e23edc6d11f9f3c24a2d10a91ee236b61d` |
| `MIT-spaCy-3.8.13.txt` | `german-function-words.txt` (spaCy 3.8.13 `spacy/lang/de/stop_words.py`) | `spacy-3.8.13.dist-info/licenses/LICENSE` inside the PyPI wheel `spacy-3.8.13-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.whl` | `3f4378e67708fecacd3e27651c8bc0f977cf20789e19da0d81a2840e7cf573a2` |
| `MIT-Faker-30.8.2.txt` | `german-given-names.txt`, `german-surnames.txt`, part of `german-names.txt` (Faker 30.8.2, MIT) | https://raw.githubusercontent.com/joke2k/faker/v30.8.2/LICENSE.txt | `cd5a5fbc8bacca52b88158ca562ac5f7c2e9adb27371cead51aaf4e61a657928` |
| `Unlicense-NameDatabases.txt` | `name-corpus.txt` and part of `german-names.txt` (smashew/NameDatabases, The Unlicense) | https://raw.githubusercontent.com/smashew/NameDatabases/4a714a09ed69147c373d9b9f2bce20ef79a63381/LICENSE | `88d9b4eb60579c191ec391ca04c16130572d7eedc4a86daa58bf28c6e14c9bcd` |
| `CC-BY-4.0.txt` | `world-places.txt` (GeoNames); the FiveThirtyEight mirror of `name-second-source.txt`; WikiNER in `de_core_news_lg` | https://creativecommons.org/licenses/by/4.0/legalcode.txt | `9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411` |
| `CC0-1.0.txt` | the SSA baby-names data of `name-second-source.txt`; the Explosion vectors of both spaCy models | https://creativecommons.org/publicdomain/zero/1.0/legalcode.txt | `a2010f343487d3f7618affe54f789f5487602331c0a8d03f49e9a7c547cf0499` |
| `Unicode-License-V3.txt` | `confusables.txt` (Unicode UTS #39 data; the notice is also verbatim in `NOTICE`) | https://www.unicode.org/license.txt | `e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96` |
| `langdetect-1.0.9-LICENSE.txt` | langdetect 1.0.9 language profiles (Apache-2.0) | https://raw.githubusercontent.com/Mimino666/langdetect/9bdfddfc934a85e46454c9a97c4b48a3aa04dc72/LICENSE (= the sha256 `NOTICE` records) | `9c539fdc47fa4e195b88efaa6495f11463de271f59c8de96feb8bc9c8abab1ab` |
| `langdetect-1.0.9-NOTICE.txt` | langdetect 1.0.9 (its Apache-2.0 section 4(d) notice; also verbatim in `NOTICE`) | https://raw.githubusercontent.com/Mimino666/langdetect/9bdfddfc934a85e46454c9a97c4b48a3aa04dc72/NOTICE (= the sha256 `NOTICE` records) | `bc22bad5907339e12834d91f7809ec35c3c44fa4b812f274ebfefa38de080869` |
| `PyTorch-2.14.1-LICENSE.txt` | torch 2.14.1+cpu | `torch-2.14.1+cpu.dist-info/licenses/LICENSE` inside `torch-2.14.1+cpu-cp312-cp312-manylinux_2_28_x86_64.whl` (https://download.pytorch.org/whl/cpu/; identical to https://github.com/pytorch/pytorch/blob/v2.14.1/LICENSE) | `bd018feef8825e88181c84eb7e3aa4eafb8f08a20d9fd6ef948569610c4a3e43` |
| `SPDX-LLVM-exception.txt` | torch licence expression (`Apache-2.0 WITH LLVM-exception`) | https://raw.githubusercontent.com/spdx/license-list-data/v3.25.0/text/LLVM-exception.txt | `e34c58338bd89d43e709e226610d8f32b3e3c47f4ad9a99a8dc1d4ac7842488e` |
| `SPDX-BSD-2-Clause.txt` | torch licence expression (`BSD-2-Clause`) | https://raw.githubusercontent.com/spdx/license-list-data/v3.25.0/text/BSD-2-Clause.txt | `f32fb3b417a194167cfad068223fc975ba96c5960513a10f66a3c28720aec1df` |
| `SPDX-BSD-3-Clause.txt` | torch licence expression (`BSD-3-Clause`) | https://raw.githubusercontent.com/spdx/license-list-data/v3.25.0/text/BSD-3-Clause.txt | `5a93d5831e1297ab10fe643e1a631e83be392896da14ee2951285a79012df69d` |
| `SPDX-BSL-1.0.txt` | torch licence expression (`BSL-1.0`) | https://raw.githubusercontent.com/spdx/license-list-data/v3.25.0/text/BSL-1.0.txt | `84c6ef3ea9e3254a54d0acf5d3e0c61ae011b8fef7dd6940591cf060e6380a8f` |
| `SPDX-MIT.txt` | torch licence expression (`MIT`); the generic MIT text | https://raw.githubusercontent.com/spdx/license-list-data/v3.25.0/text/MIT.txt | `b85dcd3e453d05982552c52b5fc9e0bdd6d23c6f8e844b984a88af32570b0cc0` |

Public-domain sources need no licence text: 12dicts (its author asks for the
acknowledgment that `NOTICE` gives), and the U.S. Census Bureau and SSA name
lists (works of the U.S. Government, 17 U.S.C. 105).
