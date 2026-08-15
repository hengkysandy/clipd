# Artwork

The SVGs here are the masters. The PNGs in
`ClipdMac/Assets.xcassets/AppIcon.appiconset` and `MenuBarIcon.imageset` are
rasterised from them.

To change the icon, edit the SVG and re-render every size, rather than editing
individual PNGs. A set where one size was touched by hand drifts away from the
others and nobody notices until the icon looks wrong at one scale.

- `clipd-icon.svg` app icon master, 1024x1024
- `clipd-menubar-solid.svg` menu bar master
- `clipd-menubar-outline.svg` alternative outline treatment, not currently used

The menu bar set declares `template-rendering-intent: template`, which is what
makes macOS recolour it for light and dark menu bars. Do not add colour to it:
a template image uses only its alpha channel.
