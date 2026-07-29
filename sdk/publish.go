package main

import (
    "crypto/sha256"
    "encoding/hex"
    "encoding/json"
    "errors"
    "flag"
    "fmt"
    "io"
    "net/http"
    "net/url"
    "os"
    "strings"
    "time"
)

const maxBinary = 1024 * 1024

type options struct {

    repository string
    token string
    manifest string
    elf string

}

type packageManifest struct {

    ID string `json:"id"`
    Name string `json:"name"`
    Summary string `json:"summary"`
    Version string `json:"version"`
    Category string `json:"category"`
    Icon string `json:"icon"`
    ABI string `json:"abi"`

}

func main() {

    if err := run(); err != nil {

        fmt.Fprintln(os.Stderr, "publish:", err)
        os.Exit(1)

    }

}

func run() error {

    settings, err := parseOptions()
    if err != nil {

        return err

    }

    manifest, err := readManifest(settings.manifest)
    if err != nil {

        return err

    }

    binary, size, digest, err := openBinary(settings.elf)
    if err != nil {

        return err

    }
    defer binary.Close()

    endpoint, err := publishURL(settings.repository)
    if err != nil {

        return err

    }

    request, err := http.NewRequest(http.MethodPost, endpoint, binary)
    if err != nil {

        return fmt.Errorf("create request: %w", err)

    }

    request.ContentLength = size
    request.Header.Set("Authorization", "Bearer "+settings.token)
    request.Header.Set("Content-Type", "application/octet-stream")
    request.Header.Set("Granite-Package-Id", manifest.ID)
    request.Header.Set("Granite-Package-Version", manifest.Version)
    request.Header.Set("Granite-Package-Name", manifest.Name)
    request.Header.Set("Granite-Package-Summary", manifest.Summary)
    request.Header.Set("Granite-Package-Category", manifest.Category)
    request.Header.Set("Granite-Package-Icon", manifest.Icon)
    request.Header.Set("Granite-Package-ABI", manifest.ABI)
    request.Header.Set("Granite-Package-SHA256", digest)

    client := &http.Client{

        Timeout: 60 * time.Second,

    }

    response, err := client.Do(request)
    if err != nil {

        return fmt.Errorf("publish package: %w", err)

    }
    defer response.Body.Close()

    payload, err := io.ReadAll(io.LimitReader(response.Body, 64*1024+1))
    if err != nil {

        return fmt.Errorf("read response: %w", err)

    }
    if len(payload) > 64*1024 {

        return errors.New("repository response is too large")

    }
    if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {

        return fmt.Errorf("%s: %s", response.Status, strings.TrimSpace(string(payload)))

    }

    fmt.Println(string(payload))

    return nil

}

func parseOptions() (options, error) {

    var settings options

    flag.StringVar(&settings.repository, "repository", "", "HTTPS repository origin")
    flag.StringVar(&settings.token, "token", os.Getenv("GRANITE_REPO_TOKEN"), "repository token")
    flag.StringVar(&settings.manifest, "manifest", "package.json", "package manifest")
    flag.StringVar(&settings.elf, "elf", "", "AArch64 ELF to publish")
    flag.Parse()

    settings.repository = strings.TrimSpace(settings.repository)
    settings.token = strings.TrimSpace(settings.token)

    if settings.repository == "" {

        return options{

        }, errors.New("-repository is required")

    }
    if settings.token == "" {

        return options{

        }, errors.New("-token or GRANITE_REPO_TOKEN is required")

    }
    if settings.elf == "" {

        return options{

        }, errors.New("-elf is required")

    }

    return settings, nil

}

func readManifest(path string) (packageManifest, error) {

    file, err := os.Open(path)
    if err != nil {

        return packageManifest{

        }, fmt.Errorf("open manifest: %w", err)

    }
    defer file.Close()

    var manifest packageManifest
    decoder := json.NewDecoder(io.LimitReader(file, 64*1024))
    decoder.DisallowUnknownFields()

    if err := decoder.Decode(&manifest); err != nil {

        return packageManifest{

        }, fmt.Errorf("decode manifest: %w", err)

    }

    var trailing any
    if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {

        return packageManifest{

        }, errors.New("manifest contains trailing data")

    }

    return manifest, nil

}

func openBinary(path string) (*os.File, int64, string, error) {

    file, err := os.Open(path)
    if err != nil {

        return nil, 0, "", fmt.Errorf("open ELF: %w", err)

    }

    info, err := file.Stat()
    if err != nil {

        file.Close()

        return nil, 0, "", fmt.Errorf("inspect ELF: %w", err)

    }
    if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maxBinary {

        file.Close()

        return nil, 0, "", errors.New("ELF must be a regular file between 1 byte and 1 MiB")

    }

    hash := sha256.New()
    if _, err := io.Copy(hash, file); err != nil {

        file.Close()

        return nil, 0, "", fmt.Errorf("hash ELF: %w", err)

    }
    if _, err := file.Seek(0, io.SeekStart); err != nil {

        file.Close()

        return nil, 0, "", fmt.Errorf("rewind ELF: %w", err)

    }

    return file, info.Size(), hex.EncodeToString(hash.Sum(nil)), nil

}

func publishURL(repository string) (string, error) {

    parsed, err := url.Parse(strings.TrimRight(repository, "/"))
    if err != nil ||
        parsed.Scheme != "https" ||
        parsed.Host == "" ||
        parsed.User != nil ||
        parsed.RawQuery != "" ||
        parsed.Fragment != "" {

        return "", errors.New("repository must be an HTTPS URL")

    }

    parsed.Path = strings.TrimRight(parsed.Path, "/") + "/v1/publish"

    return parsed.String(), nil

}
