# Security Policy

## Reporting a vulnerability

If you believe you've found a security issue in Winnow — especially anything
touching key handling, transaction signing, or the P2P trust model — please
report it privately:

- **Email:** a@wuli.nu
- **GitHub:** use [private vulnerability reporting](https://github.com/posix4e/winnow/security/advisories/new)

Do **not** open a public issue for undisclosed vulnerabilities. We aim to
acknowledge reports within 72 hours.

## Scope notes

- Key material lives in the iOS Keychain (`ThisDeviceOnly`) and signing goes
  through libsecp256k1 (via P256K) — Bitcoin Core's audited curve library.
  Swift code never does raw curve math on secrets.
- The trust model — including what compact filters can and cannot guarantee
  (lying-by-omission, eclipse caveats) — is documented honestly in
  [read-side](https://winnowwallet.com/read-side) §2.7 and §2.9. Keys and the device
  floor are [mobile](https://winnowwallet.com/mobile) §5; broadcast leakage is
  [write-side](https://winnowwallet.com/write-side) §8; import-bundle residual lies
  are [import](https://winnowwallet.com/import) §4. Reports about the *design* belong
  on those papers as issues; reports about the *implementation* not matching
  that design are security reports.

## Supported versions

Pre-1.0: only the latest `main` / latest TestFlight build is supported.
