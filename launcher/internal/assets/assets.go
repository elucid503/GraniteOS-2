package assets

import (
	"embed"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
)

//go:embed all:files
var embedded embed.FS

func ExtractImages(destDir string) error {

	if err := os.MkdirAll(destDir, 0o755); err != nil {

		return err

	}

	entries, err := fs.ReadDir(embedded, "files")
	if err != nil {

		return fmt.Errorf("read embedded images: %w", err)

	}

	if len(entries) == 0 {

		return fmt.Errorf("no OS images embedded — run launcher/build.ps1 after zig build")

	}

	for _, entry := range entries {

		if entry.IsDir() {

			continue

		}

		name := entry.Name()
		if name == ".gitkeep" || name == "README.txt" {

			continue

		}

		srcPath := filepath.ToSlash(filepath.Join("files", name))
		src, err := embedded.Open(srcPath)
		if err != nil {

			return err

		}

		dstPath := filepath.Join(destDir, name)
		if err := writeFile(dstPath, src); err != nil {

			src.Close()
			return err

		}

		src.Close()

	}

	for _, required := range []string{"granite-kernel.bin", "bundle.img"} {

		if _, err := os.Stat(filepath.Join(destDir, required)); err != nil {

			return fmt.Errorf("missing embedded image %s — run launcher/build.ps1 after zig build", required)

		}

	}

	return nil

}

func writeFile(path string, r io.Reader) error {

	tmp := path + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {

		return err

	}

	_, copyErr := io.Copy(f, r)
	closeErr := f.Close()

	if copyErr != nil {

		os.Remove(tmp)
		return copyErr

	}

	if closeErr != nil {

		os.Remove(tmp)
		return closeErr

	}

	return os.Rename(tmp, path)

}
