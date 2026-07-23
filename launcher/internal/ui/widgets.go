package ui

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/canvas"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/layout"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
)

// thinBar is a short progress bar (default Fyne bar is tall).
type thinBar struct {

	widget.BaseWidget
	value float64

}

func newThinBar() *thinBar {

	b := &thinBar{}
	b.ExtendBaseWidget(b)
	return b

}

func (b *thinBar) SetValue(v float64) {

	if v < 0 {

		v = 0

	}

	if v > 1 {

		v = 1

	}

	b.value = v
	b.Refresh()

}

func (b *thinBar) MinSize() fyne.Size {

	return fyne.NewSize(120, 4)

}

func (b *thinBar) CreateRenderer() fyne.WidgetRenderer {

	track := canvas.NewRectangle(theme.InputBackgroundColor())
	fill := canvas.NewRectangle(theme.ForegroundColor())

	r := &thinBarRenderer{

		bar: b,
		track: track,
		fill: fill,
		objs: []fyne.CanvasObject{track, fill},

	}
	return r

}

type thinBarRenderer struct {

	bar *thinBar
	track *canvas.Rectangle
	fill *canvas.Rectangle
	objs []fyne.CanvasObject

}

func (r *thinBarRenderer) Layout(size fyne.Size) {

	r.track.Resize(size)
	r.track.Move(fyne.NewPos(0, 0))

	w := size.Width * float32(r.bar.value)

	r.fill.Resize(fyne.NewSize(w, size.Height))
	r.fill.Move(fyne.NewPos(0, 0))

}

func (r *thinBarRenderer) MinSize() fyne.Size {

	return r.bar.MinSize()

}

func (r *thinBarRenderer) Refresh() {

	r.track.FillColor = theme.InputBackgroundColor()
	r.fill.FillColor = theme.ForegroundColor()
	r.track.Refresh()
	r.fill.Refresh()

	r.Layout(r.bar.Size())

}

func (r *thinBarRenderer) Objects() []fyne.CanvasObject {

	return r.objs

}

func (r *thinBarRenderer) Destroy() {}

func mutedLabel(text string) *widget.Label {

	l := widget.NewLabel(text)
	l.Importance = widget.LowImportance
	return l

}

func primaryButton(label string, tapped func()) *widget.Button {

	b := widget.NewButton(label, tapped)
	b.Importance = widget.HighImportance
	return b

}

func navButton(label string, tapped func()) *widget.Button {

	return widget.NewButton(label, tapped)

}

// showError is a text-only modal (no status icon chrome).
func showError(win fyne.Window, err error) {

	body := widget.NewLabel(err.Error())
	body.Wrapping = fyne.TextWrapWord

	d := dialog.NewCustom("Error", "OK", container.NewVBox(body), win)
	d.Resize(fyne.NewSize(400, 0))
	d.Show()

}

func footer(left, right fyne.CanvasObject) fyne.CanvasObject {

	if left == nil {

		left = layout.NewSpacer()

	}

	if right == nil {

		return container.NewHBox(left, layout.NewSpacer())

	}

	return container.NewHBox(left, layout.NewSpacer(), right)

}
