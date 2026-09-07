[Back to main README](../../../../README.md)

# Peer discovery and selection

The wallet needs reachable peers and a way to compare their answers.
Seed resolution, diversity rules, pooling, and peer persistence live together
here so discovery and admission follow one policy.

[FilterSync](../Filters/README.md) and
[AppModel](../../../WinnowApp/AppModel.swift) consume the pool.
Manual peers remain an Advanced setting; the app also uses DNS seeds and
a [generated fallback list](../Protocol/README.md).

[Peer policy tests](../../../../Tests/WalletCoreTests/Network/PeerPolicyTests.swift) cover
source classes, address ranges, persistence, and DNS replies.
[Pool tests](../../../../Tests/WalletCoreTests/Network/PeerPoolTests.swift) exercise
connection behavior. Diversity rules reduce concentration; they do not prove
that apparently different public peers have independent operators.
