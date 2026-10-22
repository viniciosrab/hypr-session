import QtQuick

// The session icon: three rounded tiles in Hyprland's dwindle split, one tall
// window on the left and two stacked on the right, the layout that comes back
// after a reboot. Drawn instead of taken from a font, like Omarchy's own
// Dropbox icon; the bar fits its bounds to the shared icon size.
Item {
  id: root

  property real size: 16
  property color color: "white"

  readonly property real gap: size * 0.1
  readonly property real tile: (size - gap) / 2
  readonly property real corner: size * 0.12

  width: size
  height: size
  implicitWidth: size
  implicitHeight: size

  Rectangle {
    x: 0; y: 0
    width: root.tile; height: root.size
    radius: root.corner
    color: root.color
    antialiasing: true
  }
  Rectangle {
    x: root.tile + root.gap; y: 0
    width: root.tile; height: root.tile
    radius: root.corner
    color: root.color
    antialiasing: true
  }
  Rectangle {
    x: root.tile + root.gap; y: root.tile + root.gap
    width: root.tile; height: root.tile
    radius: root.corner
    color: root.color
    antialiasing: true
  }
}
