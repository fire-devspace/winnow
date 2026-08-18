# Winnow design paper

The canonical paper is [Winnow: From a Phone Wallet to Family Custody](paper.md).
It connects the mobile constraints, private read path, transaction relay,
Taproot vaults, recovery, Silent Payment limitations, and reproducible signet
evidence through Sofía Cruz's fictional Brisa Café story.

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
