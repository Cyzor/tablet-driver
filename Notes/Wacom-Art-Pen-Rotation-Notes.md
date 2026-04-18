2026-04-17

# A Wacom PTH-660 reports an Art Pen's rotation in degrees, from 0° to 360°.  What does it use internally?  How does it go from its byte report to actionable axis data?  I think I'm running into an issue due to radian conversion, so things don't line up.

Internally the Art Pen’s barrel rotation is just another HID axis: the tablet sends a raw integer field in its pen report, and the driver scales that into 0–360° (or 0–2π) using a simple linear mapping. The conversion itself is not “special”; if your angles look wrong, it’s almost certainly an off‑by‑one or normalization/origin issue around that linear mapping rather than radians vs degrees.

## What the tablet actually reports

Wacom’s HID implementation for pens follows the generic digitizer guidance: a stylus report is a structured packet with logical axes (X, Y, pressure, tilt, rotation, etc.) defined via HID usages and logical minimum/maximum values in the HID descriptor.[^1][^2]

For the Art Pen rotation:

- The pen has a physical sensor for barrel rotation (not inferred from tilt).[^3][^4]
- When you rotate it in place, Wacom’s own diagnostics (“Rotation” field in the Wacom Tablet Properties test panel) shows a continuous value increasing as you twist the pen.[^5][^6]
- That diagnostic value is derived from a single HID axis in the report; the driver reads the raw field, then applies a fixed scale to show degrees (and to feed apps via WinTab/Windows Ink/macOS tablet APIs).[^5][^1]

The vendor specifics (exact usage ID for rotation, bit width, etc.) are not public, but from behavior and generic HID design you can treat rotation exactly like any other axis:

$$
\text{angleDegrees} = \frac{(\text{raw} - \text{logicalMin})}{(\text{logicalMax} - \text{logicalMin})} \times 360
$$

or a variant thereof (possibly using 0–359 or adding an offset) – no trig, no nonlinear transform.[^2][^1]

## How drivers go from bytes to “axis data”

For any HID axis, including rotation, the pipeline looks like this:[^1][^2]

1. Parse the HID report descriptor
    - Identify the rotation usage (on a digitizer/pen usage page, vendor‑specific in Wacom’s case).
    - Read `logical_minimum` and `logical_maximum`, plus the bit width.
2. Extract raw value from reports
    - For each incoming report, the driver pulls the bitfield corresponding to rotation and interprets it as a signed or unsigned integer according to the descriptor.
3. Normalize to engineering units
    - Normalize to 0–1:

$$
n = \frac{\text{raw} - \text{logicalMin}}{\text{logicalMax} - \text{logicalMin}}
$$
    - Convert to degrees: $\text{angleDegrees} = n \times 360$.
    - Convert to radians if the API or app expects that:
$\text{angleRadians} = \text{angleDegrees} \times \pi / 180$.

On Windows, if you go through the official pen/touch APIs, the OS or Wacom’s WinTab driver does this normalization before your app sees the value. On macOS, the Wacom driver exposes already‑scaled properties to applications (e.g., what Photoshop or Krita see as “rotation angle”).[^6][^5][^1]

So under the hood: one integer field → linear map → degrees → optional conversion to radians. There is no native “radians” representation in the tablet; radians only appear if a library or app converts degrees for its own math.

## Why your rotation may not line up

Given that the device’s internal representation is linear and the stack above usually works in degrees, radian mistakes tend to show up as specific, repeatable artifacts. Common failure modes:

- Treating an already‑degree value as radians
    - If a driver or app takes a 0–360° value and runs `cos(angle)` assuming it’s in radians, you effectively compress the usable range because `2π ≈ 6.283` while the input is up to 360. The brush will appear to spin through many cycles or lock into odd orientations as you rotate the pen.
- Double‑conversion
    - If some layer converts degrees→radians and a higher layer does it again, your effective angle becomes $(deg \times \pi/180) \times \pi/180$, which is almost zero for most values; visually this looks like no or extremely subtle rotation.
- Off‑by‑one / wrap issues
    - If the raw axis is 0–1023 and you map with `raw/1024.0*360` instead of `raw/1023.0*360`, you get a mismatch at the extremes: the pen never quite reaches 360° and jumps when wrapping.[^2][^1]
    - Similarly, some stacks normalize to 0–359 instead of 0–360, which can cause a 1° discontinuity on wrap.
- Different zero‑angle conventions
    - The internal axis is arbitrary; Wacom’s own diagnostics show 0° at some physical orientation that may not match your mental “zero” (e.g., flat edge facing left vs right).[^5]
    - Applications often define 0° differently (e.g., brush aligned along +X vs +Y, clockwise vs counterclockwise). If you don’t account for this, the brush looks “off” by a fixed constant rotation, which might be interpreted as a conversion issue.
- Direction reversal
    - If the raw axis increases clockwise but you assume counterclockwise (or vice versa), you’ll get a mirrored response: turn the pen one way, brush rotates the other.[^7][^5]


## How to debug your specific issue

Given your level of control (you’re likely reading raw events or low‑level API data), I’d approach it like this:

1. Inspect raw vs displayed values
    - Use Wacom’s diagnostics (“Rotation” field in the tablet test dialog) to see the *degree* value that Wacom thinks the pen is at.[^6][^5]
    - In your code, log the raw integer you receive and the converted angle you compute for a few known physical orientations (e.g., pen’s flat edge pointing right, up, left, down).
    - You should see a simple affine relation: raw increases monotonically through a full turn, and the driver’s angle is a linear function of raw.
2. Derive the actual mapping
    - If you can get raw R and Wacom‑reported angle A (degrees), solve:

$$
A = m \cdot R + b
$$

for a couple of positions; you’ll usually find $b$ is just a fixed offset and $m$ ≈ $360 / (\text{maxRaw}-\text{minRaw})$.
3. Standardize your conversion
    - Once you know logical min/max, use:

```c
float n = (raw - logicalMin) / (float)(logicalMax - logicalMin); // 0..1
float deg = n * 360.0f;
float rad = deg * (float)M_PI / 180.0f;
```

    - If your higher‑level math expects 0 at a different orientation or a different direction, apply a constant offset and possibly negate:

```c
float appDeg = fmodf((deg + offsetDeg) * direction, 360.0f);
if (appDeg < 0) appDeg += 360.0f;
```

4. Check for double conversion in your stack
    - If you’re using a framework (e.g., Qt, some graphics engine, or a Wacom SDK wrapper), confirm whether the angle you receive is *already* in radians or degrees; their docs usually state this explicitly.[^1]
    - Search your code path for every place that multiplies by $\pi/180$; you should see it at most once between the raw event and the final rotation math.

If you can share what API you’re reading from (HID directly, WinTab, Windows Ink, macOS tablet events, libinput, etc.) and an example of “expected vs actual” orientation for a couple of pen positions, I can help you pin down the exact normalization and remove the misalignment.
<span style="display:none">[^10][^11][^12][^13][^14][^15][^16][^17][^18][^19][^20][^21][^22][^23][^24][^25][^26][^8][^9]</span>

<div align="center">⁂</div>

[^1]: https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/supporting-usages-in-digitizer-report-descriptors

[^2]: https://forum.pjrc.com/index.php?threads%2Fpen-stylus-digitizer-hid-descriptor-feature-needed.42729%2F

[^3]: https://krita-artists.org/t/pen-rotation-issue-twisting-stylus-vs-changing-drawing-angle/64547

[^4]: https://support.wacom.com/hc/en-us/community/posts/20071290353943-Main-Thread-Art-Pen

[^5]: https://support.wacom.com/hc/en-us/articles/8413647279895-How-can-I-diagnose-an-issue-with-my-Wacom-Pen-device

[^6]: https://101.wacom.com/userhelp/en/TestingPen.htm

[^7]: https://ask.clip-studio.com/en-us/detail?id=73325

[^8]: https://www.reddit.com/r/wacom/comments/1fg30my/barrel_rotation_in_new_wacom_pen_tablets/

[^9]: https://ask.clip-studio.com/en-us/detail?id=55914

[^10]: https://www.youtube.com/watch?v=zQDgoNFejjg

[^11]: https://www.paintboxtv.com/art-pen-part-1/

[^12]: https://101.wacom.com/UserHelp/en/Orientation.htm

[^13]: https://www.reddit.com/r/wacom/comments/7dlx2o/wacoms_fatal_flaw_is_easily_fixable/

[^14]: https://www.reddit.com/r/wacom/comments/n6dhhk/art_pen_rotation_issue_on_cintiq/

[^15]: https://www.youtube.com/watch?v=R0n7tRNf2JE

[^16]: https://www.youtube.com/watch?v=CW5n5IzFcUU

[^17]: https://nlp.biu.ac.il/~ravfogs/resources/embeddings-alignment/glove_vocab.250k.txt

[^18]: https://101.wacom.com/UserHelp/en/TOC/PTH-660.html?topicid=Pen

[^19]: https://101.wacom.com/UserHelp/en/TOC/PTH-660.html?topicid=Mapping

[^20]: https://community.adobe.com/questions-712/wacom-art-pen-brush-rotation-tilt-stops-after-each-stroke-1080079

[^21]: https://www.elevateyourart.com/blog/set-up-wacom-art-pen

[^22]: https://www.youtube.com/watch?v=TgHw40QTV9s

[^23]: https://krita-artists.org/t/wacom-art-pen-rotation-not-detected-on-windows/117038

[^24]: https://stackoverflow.com/questions/50698287/why-newest-hid-usage-table-does-not-contain-contact-identifier-page-0x0d-usag

[^25]: https://github.com/swaywm/sway/issues/4068

[^26]: https://support.wacom.com/hc/en-us/articles/1500006270461-What-is-the-advantage-of-on-screen-digital-canvas-rotation

