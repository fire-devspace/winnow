[Back to main README](../../../../README.md)

# MuSig2 reference vectors

The seven JSON files are the official BIP327 MuSig2 vector sets from
`bitcoin/bips`, under `bip-0327/vectors`. They provide expected key aggregation,
nonce, tweak, partial-signature, and signature-aggregation results for shared signing.

[MuSig2Tests.swift](../../MuSig2Tests.swift) documents and
consumes these sets using the [shared vector loader](../../../Support/Vectors.swift).
The surrounding Vectors directory is copied into the test bundle.

Refresh from the upstream vector set, recording its source revision in the change;
preserve invalid cases as well as successful ones. Run
`swift test --filter MuSig2Tests` and the primitive suite afterward.
The JSON `msgs` field means signing messages and is required test data.
