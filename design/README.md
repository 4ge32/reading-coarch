# App icon

`app-icon.svg` is original vector artwork for ReadingCoach. The committed
`ios/ReadingCoach/Assets.xcassets/AppIcon.appiconset/AppIcon.png` is its 1024×1024
opaque RGB rendering. Xcode generates the iOS icon sizes from this one universal
asset. The outer square is intentional; iOS applies the device icon mask.

The PNG was rendered with `@resvg/resvg-js` 2.6.2, then encoded without an alpha
channel. Regenerating this design asset is not part of the app build; no renderer
dependency is downloaded by the CI workflow. Keep the SVG and PNG consistent if
the design changes.
