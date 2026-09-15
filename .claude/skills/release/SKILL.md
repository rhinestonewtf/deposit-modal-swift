---
name: release
description: Use when cutting a RhinestoneDepositModal release, or checking whether a version is actually available to SwiftPM integrators.
---

# Releasing RhinestoneDepositModal

SwiftPM resolves the repository itself, so a release is a `v<version>` tag on a **public**
repo — nothing is uploaded, and a tag on a private repo reaches no integrator.

1. Bump `WrapperVersion.current` in `Sources/RhinestoneDepositModal/Version.swift` by PR and
   merge it; CI's `tag` job fails a tag that disagrees, but only after the push.
2. Tag the merge commit: `git tag v<version> <sha> && git push origin v<version>`.
3. Verify from a clean package, never from the checkout. A resolve succeeds through your own
   git credentials even on a private repo, so check visibility too:

```sh
gh repo view rhinestonewtf/deposit-modal-swift --json visibility -q .visibility   # PUBLIC
d=$(mktemp -d); cat > "$d/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Probe", dependencies: [
  .package(url: "https://github.com/rhinestonewtf/deposit-modal-swift.git", exact: "<version>")
])
EOF
swift package --package-path "$d" resolve && grep -A3 deposit-modal-swift "$d/Package.resolved"
```

The resolved `revision` must be the commit you tagged.
