# Tablet and Pen Drawings

MockTab draws tablets, pens, and mice as it runs, rather than loading a
separate image for each model. Tablet drawings combine a body, an active
area, and controls such as keys, rings, dials, and strips. Pen drawings
combine a barrel, tip, buttons, and sometimes an eraser.

## Sources

- **[libwacom](https://github.com/linuxwacom/libwacom)** supplies control
  layouts for many Wacom models: control locations, key groups, and
  control identifiers. MockTab simplifies these layouts for drawing.
- **[TabletKit's registry](https://github.com/Cyzor/TabletKit)** supplies
  active-area dimensions and other model details. It draws on the Linux
  kernel driver, libwacom, OpenTabletDriver, and manufacturers'
  specifications, and records the testing behind each entry.
- **Product photos and manuals** fill gaps and help correct layouts.
- **Hardware checks** confirm key order. The
  [Evidence](Evidence/README.md) pages document these checks.

## Clear, Not Exact

Drawings should help you find and identify controls, not copy every
physical detail:

- Rows of keys use even spacing; tightly grouped keys form compact
  clusters.
- All drawings share a line style and spacing rules, but their outlines
  and control shapes may differ from the hardware.
- Small icons omit fine details.

## Generic Drawings

- **Tablets without a known layout** get a plain outline based on their
  active-area proportions. A wider bezel along one edge shows
  orientation. The Buttons pane lists controls without a diagram.
- **Unfamiliar pens** get a generic barrel with the button count the app
  knows about.
- **Mice** share one basic drawing, with extra buttons when applicable.

## Fixing a Drawing

Style differences are normal. A wrong control layout or highlight is a
bug. Open an issue with a tablet photo, identify the control you pressed,
and note which control the app highlighted.

Most drawing code lives in `MockTab/Figures/`:

- **Wrong or missing layout:** edit `TabletLayoutExtras` at the end of
  `TabletLayoutIdentity.swift`. It can add controls, replace a layout, or
  add a model. Do not edit `TabletLayoutTable.swift` by hand;
  `tools/registry/generate_tablet_layouts.py` generates it from libwacom.
- **Wrong control highlights:** run `tools/hardware-check/key-order.sh`,
  then correct the family's rule in `TabletControlMap.swift`. Keep
  MockTab running and give the terminal Input Monitoring permission.
- **New pen shape:** add a barrel to `PenRecipe.swift`, then match the pen
  to it in the `PenRecipe` extension in
  `MockTab/UI/Panes/Buttons/PenDiagramView.swift`.

## Testing Changes

Run all standalone tests from the repository root:

```sh
sh tools/tests/run-all-tests.sh
```

The tablet figure tests compare the geometry of every layout, drawn at a
standard size, with saved baselines. After an intentional change, update
the baselines and review the diff:

```sh
UPDATE_GOLDENS=1 sh tools/tests/tablet-figure-tests/run.sh
git diff -- tools/tests/tablet-figure-tests/golden-drawings.txt
```

Accept only changes you intended.

## Reusing the Artwork

`Design/` holds reference artwork: pen outlines
(`mocktab-pen-variants.ai`), touch-ring drawings, and orientation pictures.

To capture a model's drawing, take a screenshot. To reuse a tablet drawing
in code, call `drawing(_:in:scale:)` on a `TabletFigure` instance and draw
the shapes it returns. This internal method supplies geometry, not an
image or a complete renderer.

The project licenses the artwork under
[GPL-3.0-or-later](https://github.com/Cyzor/tablet-driver/blob/main/LICENSE).
`TabletLayoutTable.swift` also includes libwacom's copyright and
permission notice for its layout data.
