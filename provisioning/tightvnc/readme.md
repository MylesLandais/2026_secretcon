# TightVNC Provisioning Asset

Place the official 64-bit TightVNC MSI here before running the Packer build:

```bash
curl -sS -o provisioning/tightvnc/tightvnc-2.8.87-gpl-setup-64bit.msi \
  https://www.tightvnc.com/download/2.8.87/tightvnc-2.8.87-gpl-setup-64bit.msi
sha256sum provisioning/tightvnc/tightvnc-2.8.87-gpl-setup-64bit.msi
```

Expected SHA-256 for the currently staged installer:

```text
aa256612c5b8bb387355e9c4bce6068bf9ba77ef849f54efcf6087d86b86f52a
```

The MSI is ignored by git as a regenerable vendor binary.
