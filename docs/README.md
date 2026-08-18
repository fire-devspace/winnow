# Winnow design paper

The canonical paper is [Winnow: One Wallet, Two Signers, Three Roles](paper.md).
It connects the mobile constraints and private read path to a custody ladder:
one hot wallet, two independent wallet implementations, and three professional
roles. It also covers recovery, transaction submission, Silent Payment limits,
and reproducible signet evidence through Sofía Cruz's fictional Brisa Café story.

The earlier focused papers remain as archived technical notes:

| Paper | Question |
|-------|----------|
| [A phone wallet](mobile.md) | What does the device force, and what does the product refuse? |
| [The read side](read-side.md) | How does the phone learn which coins are its own? |
| [The write side](write-side.md) | How does it build, price, sign, and get a transaction out? |
| [Vaults](vaults.md) | How does shared custody work without a coordinator server? |
| [Import](import.md) | How does an existing wallet move onto the phone without a back-scan? |

The [landing page](index.html) is the popularization. These files are the
arguments. Numbers labeled "approx." are order-of-magnitude; numbers cited
from `screenshots/timings.json` are measured on signet by the UI test suite.
