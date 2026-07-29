package main

import (
    "bytes"
    "crypto/sha256"
    "crypto/subtle"
    "encoding/binary"
    "encoding/hex"
    "encoding/json"
    "errors"
    "flag"
    "fmt"
    "io"
    "log"
    "mime"
    "net/http"
    "net/url"
    "os"
    "path/filepath"
    "regexp"
    "sort"
    "strings"
    "sync"
    "time"
)

const (
    protocolVersion = 1
    packageABI = "gos2-aarch64-v1"
    maxBinary = 1024 * 1024
)

var (
    idPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{1,31}$`)
    versionPattern = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z.+-]{0,23}$`)
    hashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

type packageRecord struct {

    ID string `json:"id"`
    Name string `json:"name"`
    Summary string `json:"summary"`
    Version string `json:"version"`
    Category string `json:"category"`
    Icon string `json:"icon"`
    Artifact string `json:"artifact,omitempty"`
    SHA256 string `json:"sha256"`
    Bytes int `json:"bytes"`
    ABI string `json:"abi"`

}

type repositoryIndex struct {

    Protocol int `json:"protocol"`
    Packages []packageRecord `json:"packages"`

}

type repositoryServer struct {

    root string
    token string
    publicURL string
    mu sync.Mutex

}

func main() {

    var (
        listen = flag.String("listen", ":8080", "HTTP listen address")
        data = flag.String("data", "./repository", "repository storage directory")
        publicURL = flag.String("public-url", "", "public HTTPS origin override")
    )
    flag.Parse()

    token := strings.TrimSpace(os.Getenv("GRANITE_REPO_TOKEN"))
    if token == "" {

        log.Fatal("GRANITE_REPO_TOKEN is required")

    }

    root, err := filepath.Abs(*data)
    if err != nil {

        log.Fatalf("resolve storage directory: %v", err)

    }
    if err := os.MkdirAll(root, 0o755); err != nil {

        log.Fatalf("create storage directory: %v", err)

    }

    server := &repositoryServer{

        root: root,
        token: token,
        publicURL: strings.TrimRight(*publicURL, "/"),

    }
    if server.publicURL != "" {

        if _, err := validatePublicURL(server.publicURL); err != nil {

            log.Fatalf("invalid -public-url: %v", err)

        }

    }

    httpServer := &http.Server{

        Addr: *listen,
        Handler: server.routes(),
        ReadHeaderTimeout: 5 * time.Second,
        ReadTimeout: 30 * time.Second,
        WriteTimeout: 30 * time.Second,
        IdleTimeout: 60 * time.Second,

    }

    log.Printf("Granite repository listening on %s, storage %s", *listen, root)
    if err := httpServer.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {

        log.Fatal(err)

    }

}

func (s *repositoryServer) routes() http.Handler {

    mux := http.NewServeMux()
    mux.HandleFunc("GET /healthz", s.health)
    mux.HandleFunc("GET /v1/index.json", s.index)
    mux.HandleFunc("GET /v1/packages/{id}/{version}", s.artifact)
    mux.HandleFunc("POST /v1/publish", s.publish)

    return mux

}

func (s *repositoryServer) health(w http.ResponseWriter, _ *http.Request) {

    s.sendJSON(w, http.StatusOK, map[string]bool{

        "ok": true,

    })

}

func (s *repositoryServer) index(w http.ResponseWriter, r *http.Request) {

    origin, err := s.publicOrigin(r)
    if err != nil {

        s.sendError(w, http.StatusInternalServerError, err)
        return

    }

    s.mu.Lock()
    packages, err := s.loadCatalog()
    s.mu.Unlock()
    if err != nil {

        s.sendError(w, http.StatusInternalServerError, err)
        return

    }

    sort.Slice(packages, func(i, j int) bool {

        if packages[i].Name == packages[j].Name {

            return packages[i].ID < packages[j].ID

        }
        return packages[i].Name < packages[j].Name

    })
    for index := range packages {

        pkg := &packages[index]
        pkg.Artifact = fmt.Sprintf(
            "%s/v1/packages/%s/%s.elf",
            origin,
            url.PathEscape(pkg.ID),
            url.PathEscape(pkg.Version),
        )

    }

    w.Header().Set("Cache-Control", "public, max-age=60")
    s.sendJSON(w, http.StatusOK, repositoryIndex{

        Protocol: protocolVersion,
        Packages: packages,

    })

}

func (s *repositoryServer) artifact(w http.ResponseWriter, r *http.Request) {

    id := r.PathValue("id")
    versionFile := r.PathValue("version")
    if !strings.HasSuffix(versionFile, ".elf") {

        s.sendError(w, http.StatusNotFound, errors.New("not found"))
        return

    }
    version := strings.TrimSuffix(versionFile, ".elf")
    if !idPattern.MatchString(id) || !versionPattern.MatchString(version) {

        s.sendError(w, http.StatusNotFound, errors.New("not found"))
        return

    }

    path := filepath.Join(s.root, "packages", id, version+".elf")
    file, err := os.Open(path)
    if errors.Is(err, os.ErrNotExist) {

        s.sendError(w, http.StatusNotFound, errors.New("not found"))
        return

    }
    if err != nil {

        s.sendError(w, http.StatusInternalServerError, err)
        return

    }
    defer file.Close()

    info, err := file.Stat()
    if err != nil {

        s.sendError(w, http.StatusInternalServerError, err)
        return

    }

    w.Header().Set("Content-Type", "application/octet-stream")
    w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
    http.ServeContent(w, r, info.Name(), info.ModTime(), file)

}

func (s *repositoryServer) publish(w http.ResponseWriter, r *http.Request) {

    if !s.authorized(r.Header.Get("Authorization")) {

        s.sendError(w, http.StatusUnauthorized, errors.New("unauthorized"))
        return

    }
    if mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mediaType != "application/octet-stream" {

        s.sendError(w, http.StatusBadRequest, errors.New("Content-Type must be application/octet-stream"))
        return

    }
    if r.ContentLength <= 0 || r.ContentLength > maxBinary {

        s.sendError(w, http.StatusBadRequest, errors.New("invalid Content-Length"))
        return

    }

    record, expectedHash, err := packageFromHeaders(r.Header)
    if err != nil {

        s.sendError(w, http.StatusBadRequest, err)
        return

    }

    payload, err := io.ReadAll(io.LimitReader(r.Body, maxBinary+1))
    if err != nil {

        s.sendError(w, http.StatusBadRequest, errors.New("could not read package"))
        return

    }
    if len(payload) != int(r.ContentLength) {

        s.sendError(w, http.StatusBadRequest, errors.New("truncated body"))
        return

    }
    if err := validateELF(payload); err != nil {

        s.sendError(w, http.StatusBadRequest, err)
        return

    }

    actualDigest := sha256.Sum256(payload)
    actualHash := hex.EncodeToString(actualDigest[:])
    if subtle.ConstantTimeCompare([]byte(actualHash), []byte(expectedHash)) != 1 {

        s.sendError(w, http.StatusBadRequest, errors.New("SHA-256 mismatch"))
        return

    }

    record.SHA256 = actualHash
    record.Bytes = len(payload)

    s.mu.Lock()
    err = s.storeRelease(record, payload)
    s.mu.Unlock()
    if errors.Is(err, os.ErrExist) {

        s.sendError(w, http.StatusConflict, errors.New("release already exists"))
        return

    }
    if err != nil {

        s.sendError(w, http.StatusInternalServerError, err)
        return

    }

    s.sendJSON(w, http.StatusCreated, map[string]string{

        "id": record.ID,
        "version": record.Version,
        "sha256": record.SHA256,

    })

}

func (s *repositoryServer) storeRelease(record packageRecord, payload []byte) error {

    packages, err := s.loadCatalog()
    if err != nil {

        return err

    }

    artifactDir := filepath.Join(s.root, "packages", record.ID)
    if err := os.MkdirAll(artifactDir, 0o755); err != nil {

        return err

    }
    artifactPath := filepath.Join(artifactDir, record.Version+".elf")
    if _, err := os.Stat(artifactPath); err == nil {

        return os.ErrExist

    } else if !errors.Is(err, os.ErrNotExist) {

        return err

    }

    if err := writeNewFile(artifactPath, payload, 0o644); err != nil {

        return err

    }

    next := packages[:0]
    for _, pkg := range packages {

        if pkg.ID != record.ID {

            next = append(next, pkg)

        }

    }
    next = append(next, record)

    if err := s.saveCatalog(next); err != nil {

        _ = os.Remove(artifactPath)
        return err

    }

    return nil

}

func (s *repositoryServer) loadCatalog() ([]packageRecord, error) {

    file, err := os.Open(filepath.Join(s.root, "catalog.json"))
    if errors.Is(err, os.ErrNotExist) {

        return make([]packageRecord, 0), nil

    }
    if err != nil {

        return nil, err

    }
    defer file.Close()

    var packages []packageRecord
    decoder := json.NewDecoder(io.LimitReader(file, 4*1024*1024))
    decoder.DisallowUnknownFields()
    if err := decoder.Decode(&packages); err != nil {

        return nil, fmt.Errorf("decode catalog: %w", err)

    }

    return packages, nil

}

func (s *repositoryServer) saveCatalog(packages []packageRecord) error {

    var payload bytes.Buffer
    encoder := json.NewEncoder(&payload)
    encoder.SetIndent("", "  ")
    if err := encoder.Encode(packages); err != nil {

        return err

    }

    return replaceFile(filepath.Join(s.root, "catalog.json"), payload.Bytes(), 0o644)

}

func (s *repositoryServer) publicOrigin(r *http.Request) (string, error) {

    if s.publicURL != "" {

        return s.publicURL, nil

    }

    scheme := "http"
    if r.TLS != nil {

        scheme = "https"

    }
    if forwarded := firstHeaderValue(r.Header.Get("X-Forwarded-Proto")); forwarded != "" {

        scheme = strings.ToLower(forwarded)

    }

    host := r.Host
    if forwarded := firstHeaderValue(r.Header.Get("X-Forwarded-Host")); forwarded != "" {

        host = forwarded

    }

    origin := &url.URL{

        Scheme: scheme,
        Host: host,

    }

    return validatePublicURL(origin.String())

}

func validatePublicURL(value string) (string, error) {

    parsed, err := url.Parse(value)
    if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.Path != "" {

        return "", errors.New("public repository origin must be an HTTPS origin")

    }

    return strings.TrimRight(parsed.String(), "/"), nil

}

func packageFromHeaders(header http.Header) (packageRecord, string, error) {

    var empty packageRecord

    id, err := headerText(header, "Granite-Package-Id", 32)
    if err != nil || !idPattern.MatchString(id) {

        return empty, "", errors.New("invalid Granite-Package-Id")

    }
    version, err := headerText(header, "Granite-Package-Version", 24)
    if err != nil || !versionPattern.MatchString(version) {

        return empty, "", errors.New("invalid Granite-Package-Version")

    }
    name, err := headerText(header, "Granite-Package-Name", 40)
    if err != nil {

        return empty, "", err

    }
    summary, err := headerText(header, "Granite-Package-Summary", 80)
    if err != nil {

        return empty, "", err

    }
    category, err := headerText(header, "Granite-Package-Category", 24)
    if err != nil {

        return empty, "", err

    }
    icon, err := headerText(header, "Granite-Package-Icon", 24)
    if err != nil {

        return empty, "", err

    }
    abi, err := headerText(header, "Granite-Package-ABI", 32)
    if err != nil || abi != packageABI {

        return empty, "", errors.New("unsupported ABI")

    }
    expectedHash, err := headerText(header, "Granite-Package-SHA256", 64)
    expectedHash = strings.ToLower(expectedHash)
    if err != nil || !hashPattern.MatchString(expectedHash) {

        return empty, "", errors.New("invalid Granite-Package-SHA256")

    }

    return packageRecord{

        ID: id,
        Name: name,
        Summary: summary,
        Version: version,
        Category: category,
        Icon: icon,
        ABI: abi,

    }, expectedHash, nil

}

func headerText(header http.Header, name string, limit int) (string, error) {

    value := strings.TrimSpace(header.Get(name))
    if value == "" || len(value) > limit {

        return "", fmt.Errorf("invalid %s", name)

    }
    for _, character := range []byte(value) {

        if character < 0x20 || character >= 0x7f {

            return "", fmt.Errorf("invalid %s", name)

        }

    }

    return value, nil

}

func validateELF(payload []byte) error {

    magic := []byte{

        0x7f,
        'E',
        'L',
        'F',
        2,
        1,
        1,

    }

    if len(payload) < 64 || !bytes.Equal(payload[:7], magic) {

        return errors.New("not a little-endian ELF64 image")

    }
    if binary.LittleEndian.Uint16(payload[16:18]) != 2 ||
        binary.LittleEndian.Uint16(payload[18:20]) != 183 ||
        binary.LittleEndian.Uint16(payload[56:58]) == 0 {

        return errors.New("not a static AArch64 executable")

    }

    return nil

}

func writeNewFile(path string, payload []byte, mode os.FileMode) error {

    file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
    if err != nil {

        return err

    }

    if _, err := file.Write(payload); err != nil {

        file.Close()
        _ = os.Remove(path)
        return err

    }
    if err := file.Sync(); err != nil {

        file.Close()
        _ = os.Remove(path)
        return err

    }

    return file.Close()

}

func replaceFile(path string, payload []byte, mode os.FileMode) error {

    directory := filepath.Dir(path)
    file, err := os.CreateTemp(directory, ".catalog-*")
    if err != nil {

        return err

    }
    pending := file.Name()
    defer os.Remove(pending)

    if err := file.Chmod(mode); err != nil {

        file.Close()
        return err

    }
    if _, err := file.Write(payload); err != nil {

        file.Close()
        return err

    }
    if err := file.Sync(); err != nil {

        file.Close()
        return err

    }
    if err := file.Close(); err != nil {

        return err

    }

    if err := os.Rename(pending, path); err == nil {

        return nil

    } else if !errors.Is(err, os.ErrExist) && !isWindowsRenameError(err) {

        return err

    }

    if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {

        return err

    }

    return os.Rename(pending, path)

}

func isWindowsRenameError(err error) bool {

    return strings.Contains(strings.ToLower(err.Error()), "cannot create a file when that file already exists")

}

func (s *repositoryServer) authorized(value string) bool {

    expected := "Bearer " + s.token
    if len(value) != len(expected) {

        return false

    }

    return subtle.ConstantTimeCompare([]byte(value), []byte(expected)) == 1

}

func firstHeaderValue(value string) string {

    value, _, _ = strings.Cut(value, ",")

    return strings.TrimSpace(value)

}

func (s *repositoryServer) sendError(w http.ResponseWriter, status int, err error) {

    s.sendJSON(w, status, map[string]string{

        "error": err.Error(),

    })

}

func (s *repositoryServer) sendJSON(w http.ResponseWriter, status int, value any) {

    payload, err := json.Marshal(value)
    if err != nil {

        http.Error(w, `{"error":"encode response"}`, http.StatusInternalServerError)
        return

    }

    w.Header().Set("Content-Type", "application/json")
    w.Header().Set("Content-Length", fmt.Sprint(len(payload)))
    w.WriteHeader(status)
    _, _ = w.Write(payload)

}
