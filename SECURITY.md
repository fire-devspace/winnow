# Security Policy

## Reporting a vulnerability

If you believe you've found a security issue in Winnow — especially anything
touching key handling, transaction signing, or the P2P trust model — please
[open a public GitHub issue](https://github.com/winnowwallet/winnow/issues/new).
Public reports are welcome, including security vulnerabilities.

If you prefer to report privately, you can email a@wuli.nu or use
[private vulnerability reporting](https://github.com/winnowwallet/winnow/security/advisories/new).

We aim to acknowledge reports within 72 hours.

## Scope notes

- Key material lives in the iOS Keychain (`ThisDeviceOnly`) and signing goes
  through libsecp256k1 (via P256K) — Bitcoin Core's audited curve library.
  Swift code never does raw curve math on secrets.
- The trust model — including what compact filters can and cannot guarantee
  (lying-by-omission, eclipse caveats) — is documented honestly in
  [read-side](https://winnowwallet.com/read-side) §2.7 and §2.9. Keys and the device
  floor are [mobile](https://winnowwallet.com/mobile) §5; broadcast leakage is
  [write-side](https://winnowwallet.com/write-side) §8; import-bundle residual lies
  are [import](https://winnowwallet.com/import) §4. Reports about both the design
  and its implementation are welcome through the channels above.

## Supported versions

Pre-1.0: only the latest `main` / latest TestFlight build is supported.
