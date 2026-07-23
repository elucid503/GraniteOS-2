package ui

import (
	"image/color"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/theme"
)

type appTheme struct{}

var _ fyne.Theme = (*appTheme)(nil)

var (

	cBg = color.NRGBA{R: 0x12, G: 0x12, B: 0x12, A: 0xff}
	cSurface = color.NRGBA{R: 0x1c, G: 0x1c, B: 0x1c, A: 0xff}
	cBorder = color.NRGBA{R: 0x3a, G: 0x3a, B: 0x3a, A: 0xff}
	cMuted = color.NRGBA{R: 0x8a, G: 0x8a, B: 0x8a, A: 0xff}
	cFg = color.NRGBA{R: 0xf0, G: 0xf0, B: 0xf0, A: 0xff}
	cBtn = color.NRGBA{R: 0x2a, G: 0x2a, B: 0x2a, A: 0xff}
	cPrimary = color.NRGBA{R: 0xf0, G: 0xf0, B: 0xf0, A: 0xff}
	cOnPrim = color.NRGBA{R: 0x12, G: 0x12, B: 0x12, A: 0xff}
	cErr = color.NRGBA{R: 0xc8, G: 0xc8, B: 0xc8, A: 0xff}

)

func (appTheme) Color(name fyne.ThemeColorName, variant fyne.ThemeVariant) color.Color {

	switch name {

	case theme.ColorNameBackground:
		return cBg

	case theme.ColorNameButton:
		return cBtn

	case theme.ColorNameDisabledButton:
		return color.NRGBA{R: 0x24, G: 0x24, B: 0x24, A: 0xff}

	case theme.ColorNameForeground:
		return cFg

	case theme.ColorNameDisabled:
		return cMuted

	case theme.ColorNamePlaceHolder:
		return cMuted

	case theme.ColorNamePrimary:
		return cPrimary

	case theme.ColorNameHyperlink:
		return cFg

	case theme.ColorNameHover:
		return color.NRGBA{R: 0x38, G: 0x38, B: 0x38, A: 0xff}

	case theme.ColorNameFocus:
		return color.NRGBA{R: 0xf0, G: 0xf0, B: 0xf0, A: 0x55}

	case theme.ColorNameInputBackground:
		return cSurface

	case theme.ColorNameInputBorder:
		return cBorder

	case theme.ColorNameMenuBackground:
		return cSurface

	case theme.ColorNameOverlayBackground:
		return color.NRGBA{R: 0x00, G: 0x00, B: 0x00, A: 0xcc}

	case theme.ColorNameSeparator:
		return cBorder

	case theme.ColorNameShadow:
		return color.NRGBA{R: 0x00, G: 0x00, B: 0x00, A: 0x80}

	case theme.ColorNameSuccess:
		return cFg

	case theme.ColorNameError:
		return cErr

	case theme.ColorNameWarning:
		return cMuted

	case theme.ColorNameHeaderBackground:
		return cBg

	// High-importance buttons: light fill, dark label (fyne uses Primary + Button).
	case theme.ColorNameForegroundOnPrimary:
		return cOnPrim

	default:
		return theme.DefaultTheme().Color(name, theme.VariantDark)

	}

}

func (appTheme) Font(style fyne.TextStyle) fyne.Resource {

	return theme.DefaultTheme().Font(style)

}

func (appTheme) Icon(name fyne.ThemeIconName) fyne.Resource {

	return theme.DefaultTheme().Icon(name)

}

func (appTheme) Size(name fyne.ThemeSizeName) float32 {

	switch name {

	case theme.SizeNamePadding:
		return 6

	case theme.SizeNameInnerPadding:
		return 6

	case theme.SizeNameText:
		return 13

	case theme.SizeNameHeadingText:
		return 18

	case theme.SizeNameSubHeadingText:
		return 14

	case theme.SizeNameCaptionText:
		return 11

	case theme.SizeNameInputBorder:
		return 1

	case theme.SizeNameScrollBar:
		return 8

	case theme.SizeNameSeparatorThickness:
		return 1

	case theme.SizeNameLineSpacing:
		return 2

	default:
		return theme.DefaultTheme().Size(name)

	}

}
