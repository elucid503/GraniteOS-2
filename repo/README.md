# Granite Software Repository Protocol

Granite Software repositories are ordinary HTTPS origins. Clients need one
small JSON index and raw, immutable ELF files; a CDN can cache both.

## Read protocol

`GET /v1/index.json` returns:

```json
{
  "protocol": 1,
  "packages": [
    {
      "id": "hello",
      "name": "Hello",
      "summary": "A small GraniteOS example.",
      "version": "1.0.0",
      "category": "Accessories",
      "icon": "apps",
      "artifact": "https://repo.example/v1/packages/hello/1.0.0.elf",
      "sha256": "64 lowercase hexadecimal characters",
      "bytes": 123456,
      "abi": "gos2-aarch64-v1"
    }
  ]
}
```

Package IDs are stable launcher names: 2–32 lowercase letters, numbers, and
hyphens, beginning with a letter. Metadata is printable ASCII. Artifacts are
ELF64, little-endian, static AArch64 `ET_EXEC` images up to 1 MiB. Every
artifact URL must use HTTPS. The client checks length, ABI, ELF fields, and
SHA-256 before touching the active executable.

The index is authoritative for the newest release of each package. Artifact
URLs are immutable. Upgrades replace `/apps/<id>` transactionally; installed
metadata lives separately from the immutable built-in catalog.

## Publish protocol

`POST /v1/publish` accepts the raw ELF as `application/octet-stream` with:

- `Authorization: Bearer <token>`
- `Granite-Package-Id`
- `Granite-Package-Version`
- `Granite-Package-Name`
- `Granite-Package-Summary`
- `Granite-Package-Category`
- `Granite-Package-Icon`
- `Granite-Package-ABI`
- `Granite-Package-SHA256`

A version is immutable and a duplicate returns `409 Conflict`. A successful
publish returns `201 Created`. Production services can replace the shared
token with user accounts, review queues, signing, or per-publisher namespaces
without changing the read protocol consumed by GraniteOS.

## Run the reference server

The dependency-free Go server needs one setting:

```sh
export GRANITE_REPO_TOKEN='replace-me'
cd repo
go run .
```

It listens on `:8080`, stores data in `./repository`, and derives its public
HTTPS origin from the request. A normal TLS reverse proxy only needs to forward
`Host` and `X-Forwarded-Proto`. Persist the repository directory and back up
`catalog.json` and `packages/`.

Optional flags cover unusual deployments:

```sh
go run . -listen :9000 -data /var/lib/granite-repo
go run . -public-url https://repo.example
```

`-public-url` is only needed when the proxy cannot forward the original host
and protocol. Build a standalone binary with `go build -o granite-repo .`.
The unauthenticated `GET /healthz` endpoint is available for cloud health
checks.

Set the OS repository by writing the HTTPS index URL to
`/cfgs/software-repository.config`. The built-in default is
`https://repo.graniteos.org/v1/index.json`.

## Security boundary

Repository packages run with the normal desktop grant set: console streams,
name-service access, a memory authority, compositor access discovered by
name, and the read-only system bundle used for fonts. They receive no device,
interrupt, DMA, or kernel authority. This is the same capability envelope as
built-in GUI programs.
