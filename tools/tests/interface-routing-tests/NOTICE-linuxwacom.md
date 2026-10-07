# corpus-linuxwacom.json

`corpus-linuxwacom.json` is derived from the
[linuxwacom/wacom-hid-descriptors](https://github.com/linuxwacom/wacom-hid-descriptors)
database. It keeps each Wacom interface's top-level HID collections, by
product ID and bus, from that database's descriptor dumps.

It is made available under the
[Open Database License (ODbL) v1.0](https://opendatacommons.org/licenses/odbl/1-0/),
the license of the database it derives from. Any rights in individual
contents are licensed under the same terms as the source. The rest of this
directory is covered by the repository's license.

Regenerate it with `build-corpus.py` after cloning the database into
`Notes/Scratch/upstream/wacom-hid-descriptors`.
