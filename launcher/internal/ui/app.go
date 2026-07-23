package ui

import (
	"fmt"
	"path/filepath"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/widget"

	"graniteos.dev/launcher/internal/config"
	"graniteos.dev/launcher/internal/install"
	"graniteos.dev/launcher/internal/qemu"
)

func Run() {

	a := app.NewWithID("dev.graniteos.launcher")
	a.Settings().SetTheme(appTheme{})

	w := a.NewWindow(config.AppName)
	w.Resize(fyne.NewSize(480, 280))
	w.SetFixedSize(true)
	w.CenterOnScreen()

	root, err := config.DefaultInstallDir()
	if err != nil {

		root = filepath.Join(".", config.AppName)

	}

	state := &appState{

		app:   a,
		win:   w,
		root:  root,
		paths: config.PathsFor(root),

	}

	if state.paths.IsInstalled() {

		state.showHome()

	} else {

		state.showWelcome()

	}

	w.ShowAndRun()

}

type appState struct {

	app fyne.App
	win fyne.Window
	root string
	paths config.Paths

}

func (s *appState) setContent(body fyne.CanvasObject, nav fyne.CanvasObject) {

	s.win.SetContent(container.NewBorder(nil, container.NewPadded(nav), nil, nil, container.NewPadded(body)))

}

func (s *appState) showWelcome() {

	body := container.NewVBox(widget.NewLabel("Set up and run GraniteOS on this PC."), mutedLabel("The launcher will download the virtual machine and system images."))

	s.setContent(body, footer(navButton("Exit", func() { s.app.Quit() }), primaryButton("Continue", func() { s.showLocation() }), ))

}

func (s *appState) showLocation() {

	entry := widget.NewEntry()
	entry.SetText(s.root)

	browse := navButton("Browse", func() {

		dialog.ShowFolderOpen(func(uri fyne.ListableURI, err error) {

			if err != nil || uri == nil {

				return

			}

			entry.SetText(uri.Path())

		}, s.win)

	})

	body := container.NewVBox(mutedLabel("Install folder"), container.NewBorder(nil, nil, nil, browse, entry))

	s.setContent(body, footer(navButton("Back", func() {

				if s.paths.IsInstalled() {

					s.showHome()
					return

				}

				s.showWelcome()

			}),

			primaryButton("Install", func() {

				path := entry.Text

				if path == "" {

					showError(s.win, fmt.Errorf("choose an install folder"))
					return

				}

				s.root = path
				s.paths = config.PathsFor(path)
				s.showProgress()

			}),
		),
	)

}

func (s *appState) showProgress() {

	status := mutedLabel("Starting...")
	bar := newThinBar()

	body := container.NewVBox(mutedLabel("Setting up..."), bar, status)

	s.setContent(body, footer(nil, nil))

	go func() {

		err := install.Run(s.root, func(frac float64, msg string) {

			bar.SetValue(frac)
			status.SetText(msg)

		})

		if err != nil {

			showError(s.win, err)
			s.showLocation()
			return

		}

		s.paths = config.PathsFor(s.root)
		s.showHome()

	}()

}

func (s *appState) showHome() {

	body := container.NewVBox(widget.NewLabel("Start GraniteOS."), mutedLabel(fmt.Sprintf("%d CPU cores · %d MiB RAM · %d MiB disk", config.SMP, config.Memory, config.Disk)), mutedLabel(s.root))

	s.setContent( body, footer(

			container.NewHBox(

				navButton("Exit", func() { s.app.Quit() }),
				navButton("Repair", func() { s.showLocation() }),

			),

			primaryButton("Start", func() { s.boot() }),

		),

	)

}

func (s *appState) boot() {

	if !s.paths.IsInstalled() {

		showError(s.win, fmt.Errorf("GraniteOS is not set up yet!"))
		s.showWelcome()

		return

	}

	err := qemu.LaunchGUI(s.paths, func() {

		s.showHome()
		s.win.Show()
		s.win.RequestFocus()

	})

	if err != nil {

		showError(s.win, err)
		return

	}

	s.win.Hide()

}
