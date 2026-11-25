# Start Line Lab

`tools/start_lab.html` is a standalone browser page (open the file directly; three.js r128 from CDN, like `shop_lab.html`) that dresses a rally stage start around a road from a seed. The road runs along z, its centre line on x = 0, with the start line at the origin; cars drive towards −z. The road and grass are preview-only and are not exported: the `.glb` holds only the dressing, so it drops onto an existing road at the start line.

**Road width is an input**, and everything is laid out from the road edge (`edge = width / 2`): the arch spans `width + 1.6`, the tape line sits a seeded 0.8–1.2 m off the edge, a `crowdBand` (2.2 m) behind it stays clear for the game's own spectators, and gazebos and portaloos stand right behind that (`back`). The whole start fits within about 6.5–7.5 m of each road edge; the sidebar prints the footprint.

What `buildStart` places:
- **Arch** (`arch`): aluminium truss with a hanging event banner, an inflatable tube arch, or none (Arch select / `?arch=`); hay bales at its feet.
- **Start control** on one seeded side (`cs`): the start clock with start lights (`startClock`) facing the arriving car, a "START CONTROL" gazebo, the yellow / red / beige time-control boards (`board`, `clockTex`), cones (`ctlLo`..`ctlHi` marks that stretch).
- **Opposite side of the line**: wire fence panels carrying sponsor banners (`banner`) in place of tape, plus an "SS n" board.
- **Elsewhere**: red/white tape on stakes (`tape`), feather flags (`flag`), sponsor gazebos walked along each side with seeded gaps (`gazebo`), a row of portaloos.
- **Sponsor adverts**: each seed draws 5 sponsors from `SPONSORS` and gives each a seeded identity (`makeSponsor`: brand colours from `BRANDS`, font, emblem drawn by `drawEmblem`, background treatment, tagline). Every fence banner and gazebo valance reuses one of those 5, so the same brands repeat around the start; the sidebar previews them.

Controls: seed, event banner text (seeded from `EVENTS` when blank), road width, zone length, arch, Download .glb. `?seed=`, `?width=`, `?event=`, `?arch=` preselect. Like the shop lab it is a layout/look prototype: flat Lambert materials, text baked into canvas textures (no `noText` marker export yet).
