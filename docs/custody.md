# How you hold it

One key, two keys, three. Each step buys something specific, and costs something specific. This page is the long version of the choice; the [front page](/) is the short one.

The rule underneath all of it: **use the smallest policy that fits the money.** A wallet you find annoying is a wallet you will empty into a worse one.

---

## One key

Everything happens on the phone. The key is generated there, stored there, and never sent anywhere. There is no account, no server that knows your addresses, nothing to sign up for.

This is the right shape for money you actually spend. It is the wrong shape for money you cannot afford to lose, for one reason: a single key is a single point of failure. Lose it with no backup and the money is gone. Have it taken and the money is gone.

![A wallet and its first address, seconds after setup. Nothing was asked of a server.](screenshots/03-receive.png)

---

## Two keys — resilience against the maker

Two keys, both required. Nothing moves unless both sign.

The obvious benefit is theft: someone who takes one phone, or finds one recovery phrase, has nothing they can spend. But the reason to reach for two keys is narrower and more interesting than theft, and it is about **the people who built your wallet**.

Every wallet is somebody's software running on somebody's hardware. Both can be wrong:

- **Hardware.** Devices have shipped with keys an attacker could guess, because the random number generator was not as random as believed. Every coin behind those devices was exposed at once, without anyone touching them.
- **Software.** A signing bug, a bad update, a compromised build. The device is fine; the code that drives it is not.

You cannot audit your way out of this. What you can do is refuse to bet everything on one maker being right. Two keys held on devices from two different makers means a flaw in either one is survivable — the attacker who breaks one still needs a signature the broken device cannot produce. Both would have to fail, independently, at the same time.

This is why "two devices" is not the same as "two of my phones". Two devices running the same software share the same mistakes. The independence is the product.

![The second device approving a payment. It sees the amount, the destination and the fee before it signs anything.](screenshots/15-vault-cosign.png)

### And nobody has to know you have it

Winnow can combine two keys into one before anything reaches the chain. What gets published is a single 64-byte signature — the same thing an ordinary one-key wallet publishes.

That is worth more than the fee saving.

Ordinary multisig announces itself. When it is spent, the chain reveals the policy it spent under — how many keys exist, how many must sign, and often enough about the script to guess what kind of device is holding them. Combining the keys publishes none of that. Nobody learns that a second device exists, where it might be, or whose hardware it is.

That last part matters. A published policy is a shopping list: it tells someone which vendor's weakness is worth researching, and how many devices they would need to reach. An aggregated spend tells them you are one person with one wallet, which is what most of the chain looks like.

The trade: combined keys are all-or-nothing. Two of two, three of three. If you need "any two of these three", that is the next section, and it is visible on the chain when spent.

---

## Three or more — everything else

Any two of three. Any three of five. You choose how many keys exist and how many must agree.

![Choosing how many keys exist and how many of them a payment needs.](screenshots/10-vault-create.png)

This is the shape for every problem that is not about the maker:

**Losing one.** A phone in a river is an inconvenience rather than a catastrophe. Two of your remaining keys still move the money.

**Being made to move it.** If somebody is standing in your house, you cannot send the money — not because you refuse, but because you genuinely cannot. The other key is elsewhere, held by someone who is not in the room. Coercion only works on people who are able to comply.

**Dying.** If you can no longer sign, the keys you placed with others still can, after whatever real-world checks you set when you built the wallet. An estate settles without you handing anyone your keys while you are alive, and without a lawyer holding your coins.

**Working with an institution.** A company whose business is holding one key can hold one — for a loan against your coins, or a custody arrangement — without ever being able to spend alone. You keep enough keys that they need you. They keep enough that losing your phone is not the end.

Spending this way publishes the policy: anyone reading the chain sees it took two signatures out of three.

That is a real privacy cost, and for the coercion case it is also the point. Deterrence only works on people who know. Somebody who studies you before knocking on your door learns from the chain that you cannot move the money by yourself, and that whoever holds the other key is not in the room. The threat stops being worth making. A wallet that hides its policy perfectly cannot deter anyone, because nobody knows there is anything to be deterred by.

So the two shapes protect against opposite things, and it is worth being deliberate about which you want. Combined keys hide that you have a second signer at all. A published k-of-n advertises that coming for you personally will not work. Note that the advertisement only exists once you have spent from the wallet — an output nobody has spent from looks like any other.

---

## What actually travels

Nothing secret. A payment starts as a partly signed transaction — a file of text — and gathers signatures as it goes.

Each holder sees what they are approving before approving it: the amount, the destination, the fee. Signing is a review, not a rubber stamp. The keys never move; only signatures do. When enough signatures exist, anyone can broadcast it, and the payment is ordinary from that moment on.

![A payment under review before any signature is added.](screenshots/06-send-review.png)

The technical write-up of both policies, including the exact descriptors and witness shapes, is in the [design paper](/paper).
