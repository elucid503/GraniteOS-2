package qemu

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"

	"graniteos.dev/launcher/internal/config"
)

// CREATE_NO_WINDOW: no console host. Unlike HideWindow/SW_HIDE, SDL still shows.
const createNoWindow = 0x08000000

// EnsureDisk creates a raw disk of sizeMiB when missing; existing images are kept for persistence.
func EnsureDisk(path string, sizeMiB int) error {

	want := int64(sizeMiB) * 1024 * 1024

	if info, err := os.Stat(path); err == nil {

		if info.Size() == want {

			return nil

		}

		return fmt.Errorf("disk %s is %d bytes, expected %d; delete it to recreate", path, info.Size(), want)

	} else if !os.IsNotExist(err) {

		return err

	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {

		return err

	}

	f, err := os.Create(path)

	if err != nil {

		return err

	}

	defer f.Close()

	return f.Truncate(want)

}

// GUIArgs matches `zig build qemu-gui` with the launcher SMP / memory / disk sizing.
func GUIArgs(p config.Paths) []string {

	return []string{

		"-machine", "virt,gic-version=3",
		"-cpu", "cortex-a57",
		"-smp", strconv.Itoa(config.SMP),
		"-m", fmt.Sprintf("%dM", config.Memory),

		"-global", "virtio-mmio.force-legacy=false",

		"-netdev", "user,id=granite-net,hostfwd=tcp::5555-:5555",
		"-device", "virtio-net-device,netdev=granite-net",
		"-device", "virtio-rng-device",

		"-display", "sdl",
		"-device", "virtio-gpu-device",
		"-device", "virtio-keyboard-device",
		"-device", "virtio-tablet-device",

		"-audiodev", "dsound,id=granite-audio",
		"-device", "virtio-sound-device,audiodev=granite-audio,streams=1",

		"-serial", "null",

		"-kernel", p.Kernel,
		"-initrd", p.Bundle,

		"-drive", fmt.Sprintf("if=none,format=raw,id=granite-disk,file=%s", p.Disk),
		"-device", "virtio-blk-device,drive=granite-disk",

	}

}

// LaunchGUI starts the QEMU desktop. onExit runs after the process ends (may be nil).
func LaunchGUI(p config.Paths, onExit func()) error {

	if err := EnsureDisk(p.Disk, config.Disk); err != nil {

		return err

	}

	if _, err := os.Stat(p.QemuExe); err != nil {

		return fmt.Errorf("virtual machine not found at %s", p.QemuExe)

	}

	cmd := exec.Command(p.QemuExe, GUIArgs(p)...)
	cmd.Dir = p.QemuDir
	cmd.Env = append(os.Environ(), "PATH="+p.QemuDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	cmd.Stdin = nil
	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow}

	if err := cmd.Start(); err != nil {

		return fmt.Errorf("start virtual machine: %w", err)

	}

	go func() {

		_ = cmd.Wait()
		if onExit != nil {

			onExit()

		}

	}()

	return nil

}
