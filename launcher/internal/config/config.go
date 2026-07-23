package config

import (
	"os"
	"path/filepath"
)

const (

	AppName = "GraniteOS"
	AppVersion = "2.0.0"

	SMP = 4
	Memory = 512
	Disk = 256

	KernelName = "granite-kernel.bin"
	BundleName = "bundle.img"
	DiskName = "disk.img"
	QemuExe = "qemu-system-aarch64.exe"

	// Official Windows builds linked from qemu.org.

	QemuDownloadURL = "https://qemu.weilnetz.de/w64/qemu-w64-setup-20260501.exe"
	QemuSetupName = "qemu-w64-setup.exe"

)

func DefaultInstallDir() (string, error) {

	base, err := os.UserConfigDir()

	if err != nil {

		return "", err

	}

	// LOCALAPPDATA for bulky QEMU + disk data.
	if local := os.Getenv("LOCALAPPDATA"); local != "" {

		base = local

	}

	return filepath.Join(base, AppName), nil

}

type Paths struct {

	Root string

	Images string
	QemuDir string

	Kernel string
	Bundle string
	Disk string
	QemuExe string

	Marker string

}

func PathsFor(root string) Paths {

	images := filepath.Join(root, "images")
	qemu := filepath.Join(root, "qemu")

	return Paths{

		Root: root,

		Images: images,
		QemuDir: qemu,

		Kernel: filepath.Join(images, KernelName),
		Bundle: filepath.Join(images, BundleName),
		Disk: filepath.Join(images, DiskName),
		QemuExe: filepath.Join(qemu, QemuExe),

		Marker: filepath.Join(root, ".installed"),

	}

}

func (p Paths) IsInstalled() bool {

	if _, err := os.Stat(p.Marker); err != nil {

		return false

	}

	if _, err := os.Stat(p.Kernel); err != nil {

		return false

	}

	if _, err := os.Stat(p.Bundle); err != nil {

		return false

	}

	if _, err := os.Stat(p.QemuExe); err != nil {

		return false

	}

	return true

}
