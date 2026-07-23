package install

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"graniteos.dev/launcher/internal/assets"
	"graniteos.dev/launcher/internal/config"
	"graniteos.dev/launcher/internal/qemu"
)

type Progress func(fraction float64, status string)

func Run(root string, progress Progress) error {

	if progress == nil {

		progress = func(float64, string) {}

	}

	p := config.PathsFor(root)

	progress(0.02, "Creating install directory...")

	if err := os.MkdirAll(p.Images, 0o755); err != nil {

		return err

	}

	if err := os.MkdirAll(p.QemuDir, 0o755); err != nil {

		return err

	}

	progress(0.08, "Installing system images...")

	if err := assets.ExtractImages(p.Images); err != nil {

		return err

	}

	progress(0.25, "Preparing disk...")

	if err := qemu.EnsureDisk(p.Disk, config.Disk); err != nil {

		return err

	}

	if _, err := os.Stat(p.QemuExe); err == nil {

		progress(0.95, "Virtual machine already present...")

	} else if sys := findSystemQEMU(); sys != "" {

		progress(0.90, "Using existing virtual machine...")

		if err := linkQEMU(sys, p.QemuDir); err != nil {

			return err

		}

	} else {

		progress(0.30, "Downloading virtual machine...")

		setupPath := filepath.Join(root, config.QemuSetupName)
		if err := downloadFile(config.QemuDownloadURL, setupPath, func(done, total int64) {

			frac := 0.30
			if total > 0 {

				frac = 0.30 + 0.50*(float64(done)/float64(total))

			}

			progress(frac, fmt.Sprintf("Downloading virtual machine... %s / %s", humanBytes(done), humanBytes(total)))

		}); err != nil {

			return fmt.Errorf("download virtual machine: %w", err)

		}

		progress(0.85, "Installing virtual machine (accept the permission prompt)...")

		if err := installQEMU(setupPath, p.QemuDir); err != nil {

			return err

		}

		_ = os.Remove(setupPath)

	}

	if _, err := os.Stat(p.QemuExe); err != nil {

		return fmt.Errorf("virtual machine setup finished but files are missing")

	}

	progress(0.97, "Writing install marker...")

	if err := os.WriteFile(p.Marker, []byte(config.AppVersion+"\n"), 0o644); err != nil {

		return err

	}

	progress(1.0, "Install complete")
	return nil

}

func findSystemQEMU() string {

	if path, err := exec.LookPath(config.QemuExe); err == nil {

		return filepath.Dir(path)

	}

	candidates := []string{
		filepath.Join(os.Getenv("ProgramFiles"), "qemu"),
		filepath.Join(os.Getenv("ProgramFiles(x86)"), "qemu"),
	}

	for _, dir := range candidates {

		if _, err := os.Stat(filepath.Join(dir, config.QemuExe)); err == nil {

			return dir

		}

	}

	return ""

}

// linkQEMU points our qemu dir at an existing install via a directory junction (no copy, no elevation).
func linkQEMU(srcDir, destDir string) error {

	_ = os.RemoveAll(destDir)

	cmd := exec.Command("cmd", "/c", "mklink", "/J", destDir, srcDir)

	if out, err := cmd.CombinedOutput(); err != nil {

		return fmt.Errorf("link virtual machine: %w\n%s", err, string(out))

	}

	return nil

}

func installQEMU(setupPath, destDir string) error {

	// CreateProcess cannot elevate; ShellExecute via PowerShell surfaces UAC.
	ps := fmt.Sprintf(
		`Start-Process -LiteralPath '%s' -ArgumentList @('/S','/D=%s') -Verb RunAs -Wait`,
		psQuote(setupPath),
		psQuote(destDir),
	)

	cmd := exec.Command("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps)

	if out, err := cmd.CombinedOutput(); err != nil {

		return fmt.Errorf("virtual machine install failed: %w\n%s", err, string(out))

	}

	deadline := time.Now().Add(2 * time.Minute)

	for time.Now().Before(deadline) {

		if _, err := os.Stat(filepath.Join(destDir, config.QemuExe)); err == nil {

			return nil

		}

		time.Sleep(400 * time.Millisecond)

	}

	return fmt.Errorf("timed out waiting for %s", config.QemuExe)

}

func psQuote(s string) string {

	return strings.ReplaceAll(s, "'", "''")

}

type downloadProgress func(done, total int64)

func downloadFile(url, dest string, onProgress downloadProgress) error {

	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {

		return err

	}

	req.Header.Set("User-Agent", "GraniteOS-Launcher/"+config.AppVersion)

	client := &http.Client{Timeout: 30 * time.Minute}
	resp, err := client.Do(req)

	if err != nil {

		return err

	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {

		return fmt.Errorf("HTTP %s", resp.Status)

	}

	tmp := dest + ".partial"
	f, err := os.Create(tmp)

	if err != nil {

		return err

	}

	var written int64

	total := resp.ContentLength
	buf := make([]byte, 256*1024)

	for {

		n, readErr := resp.Body.Read(buf)
		if n > 0 {

			if _, werr := f.Write(buf[:n]); werr != nil {

				f.Close()
				os.Remove(tmp)
				return werr

			}

			written += int64(n)
			if onProgress != nil {

				onProgress(written, total)

			}

		}

		if readErr == io.EOF {

			break

		}

		if readErr != nil {

			f.Close()
			os.Remove(tmp)
			return readErr

		}

	}

	if err := f.Close(); err != nil {

		os.Remove(tmp)
		return err

	}

	return os.Rename(tmp, dest)

}

func humanBytes(n int64) string {

	if n < 0 {

		return "?"

	}

	const unit = 1024 // 1 KiB = 1024 B

	if n < unit {

		return fmt.Sprintf("%d B", n)

	}

	div, exp := int64(unit), 0
	for v := n / unit; v >= unit; v /= unit {

		div *= unit
		exp++

	}

	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])

}
