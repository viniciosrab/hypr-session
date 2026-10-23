import QtQuick

// The session icon: three rounded tiles in Hyprland's dwindle split, one tall
// window on the left and two stacked on the right, the layout that comes back
// after a reboot. Drawn instead of taken from a font, like Omarchy's own
// Dropbox icon; the bar fits its bounds to the shared icon size.
//
// The root is a transparent canvas the bar measures as the icon's bounds. The
// tiles sit inside it at `artworkScale`: solid tiles carry more ink than the
// outlined stock glyphs, so at full size they read larger than their
// neighbours.
Rectangle {
  id: root

  property real size: 16
  property real artworkScale: 0.84
  property color tileColor: "white"

  readonly property real artwork: size * artworkScale
  readonly property real inset: (size - artwork) / 2
  readonly property real gap: artwork * 0.1
  readonly property real tile: (artwork - gap) / 2
  readonly property real corner: artwork * 0.12

  color: "transparent"
  width: size
  height: size
  implicitWidth: size
  implicitHeight: size

  Rectangle {
    x: root.inset; y: root.inset
    width: root.tile; height: root.artwork
    radius: root.corner
    color: root.tileColor
    antialiasing: true
  }
  Rectangle {
    x: root.inset + root.tile + root.gap; y: root.inset
    width: root.tile; height: root.tile
    radius: root.corner
    color: root.tileColor
    antialiasing: true
  }
  Rectangle {
    x: root.inset + root.tile + root.gap; y: root.inset + root.tile + root.gap
    width: root.tile; height: root.tile
    radius: root.corner
    color: root.tileColor
    antialiasing: true
  }
}
